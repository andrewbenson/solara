#import "SolaraCoreInternal.h"
#import "SolaraCore-Swift.h"

namespace {

constexpr int kFaviconSize = 32;
constexpr NSUInteger kMaxBytes = 2 * 1024 * 1024;

NSCache<NSString *, NSImage *> *OrdinarySeen() {
  static NSCache *cache = [] {
    NSCache *c = [NSCache new];
    c.countLimit = 512;
    return c;
  }();
  return cache;
}

NSString *SeenKey(NSString *profile, NSString *url) {
  return [NSString stringWithFormat:@"%@\n%@", profile ?: @"", url];
}

NSString *FaviconDirectory(NSString *profile) {
  NSString *dir = profile.length ? [@"Profile " stringByAppendingString:profile] : @"Default";
  return [[SolaraCoreHost.dataDirectory stringByAppendingPathComponent:dir] stringByAppendingPathComponent:@"Solara Favicons"];
}

bool SafeName(NSString *name) {
  static NSRegularExpression *re = [NSRegularExpression regularExpressionWithPattern:@"^[A-Za-z0-9_-]{1,80}$" options:0 error:nil];
  return name.length && [re firstMatchInString:name options:0 range:NSMakeRange(0, name.length)];
}

NSDictionary *Store(NSData *png, int width, int height, NSString *profile, NSString *name) {
  if (!png.length) return nil;
  if (!SolaraCoreHost.safeMode && profile && !solaracore_host::IsIncognito(profile) && SafeName(name)) {
    NSString *dir = FaviconDirectory(profile);
    [NSFileManager.defaultManager createDirectoryAtPath:dir withIntermediateDirectories:YES attributes:nil error:nil];
    NSString *path = [dir stringByAppendingPathComponent:[name stringByAppendingPathExtension:@"png"]];
    if (![png writeToFile:path atomically:YES]) return nil;
    NSString *uri = [NSString stringWithFormat:@"%@?v=%lld", [NSURL fileURLWithPath:path].absoluteString,
                                               (long long)(NSDate.date.timeIntervalSince1970 * 1000)];
    return @{@"uri" : uri, @"width" : @(width), @"height" : @(height)};
  }
  NSString *uri = [@"data:image/png;base64," stringByAppendingString:[png base64EncodedStringWithOptions:0]];
  return @{@"uri" : uri, @"width" : @(width), @"height" : @(height)};
}

NSData *PNG(NSImage *image, int pixels, int *width, int *height) {
  if (!image || image.size.width <= 0 || image.size.height <= 0) return nil;
  NSImageRep *best = nil;
  NSInteger bestSize = 0;
  for (NSImageRep *rep in image.representations) {
    NSInteger size = MAX(rep.pixelsWide, rep.pixelsHigh);
    if (size <= 0) size = NSIntegerMax;
    const bool better = !best || (bestSize < pixels ? size > bestSize : (size >= pixels && size < bestSize));
    if (better) best = rep, bestSize = size;
  }
  if (!best) return nil;
  const int side = (int)MIN((NSInteger)pixels, bestSize);
  NSBitmapImageRep *bitmap = [[NSBitmapImageRep alloc] initWithBitmapDataPlanes:NULL pixelsWide:side pixelsHigh:side bitsPerSample:8
                                                                samplesPerPixel:4 hasAlpha:YES isPlanar:NO
                                                                 colorSpaceName:NSDeviceRGBColorSpace bytesPerRow:0 bitsPerPixel:0];
  NSGraphicsContext *context = [NSGraphicsContext graphicsContextWithBitmapImageRep:bitmap];
  if (!context) return nil;
  [NSGraphicsContext saveGraphicsState];
  NSGraphicsContext.currentContext = context;
  context.imageInterpolation = NSImageInterpolationHigh;
  NSSize size = best.size.width > 0 && best.size.height > 0 ? best.size : image.size;
  CGFloat scale = side / MAX(size.width, size.height);
  NSRect rect = NSMakeRect((side - size.width * scale) / 2, (side - size.height * scale) / 2, size.width * scale, size.height * scale);
  [best drawInRect:rect fromRect:NSZeroRect operation:NSCompositingOperationCopy fraction:1 respectFlipped:YES hints:nil];
  [NSGraphicsContext restoreGraphicsState];
  *width = side;
  *height = side;
  return [bitmap representationUsingType:NSBitmapImageFileTypePNG properties:@{}];
}

void Download(NSString *url, NSString *profileName, void (^done)(NSData *_Nullable data)) {
  void (^fetch)(SolaraCoreProfile *) = ^(SolaraCoreProfile *profile) {
    if (!profile || profile.destroyed || ![profile respondsToSelector:@selector(fetchIcon:maxBytes:completion:)]) return done(nil);
    [profile fetchIcon:url maxBytes:kMaxBytes completion:done];
  };
  if (solaracore_host::IsIncognito(profileName)) return fetch(solaracore_host::LoadedProfile(profileName));
  solaracore_host::WithProfile(profileName, fetch);
}

}

@implementation SolaraCoreFavicons

+ (void)noteImage:(NSImage *)image forURL:(NSString *)url profile:(NSString *)profile {
  if (!image || !url.length) return;
  if (solaracore_host::IsIncognito(profile)) [NativePrivateFaviconCache.shared noteImage:image url:url profile:profile];
  else [OrdinarySeen() setObject:image forKey:SeenKey(profile, url)];
}

+ (void)forgetPrivateProfiles:(NSArray<NSString *> *)profiles {
  [NativePrivateFaviconCache.shared forgetProfiles:profiles];
}

+ (void)fetch:(NSString *)url
       profile:(NSString *)profile
          name:(NSString *)name
    completion:(void (^)(NSDictionary<NSString *, id> *))completion {
  NativePrivateFaviconCache *privateCache = NativePrivateFaviconCache.shared;
  const NSInteger generation = [privateCache generation:profile];
  if (![privateCache isCurrent:profile generation:generation]) return completion(nil);
  int width = 0, height = 0;
  NSImage *seen = solaracore_host::IsIncognito(profile) ? [privateCache image:url profile:profile] : [OrdinarySeen() objectForKey:SeenKey(profile, url)];
  if (seen) {
    return completion(Store(PNG(seen, kFaviconSize * 2, &width, &height), width, height, profile, name));
  }
  if ([url hasPrefix:@"data:image/"]) {
    NSData *data = [NSData dataWithContentsOfURL:[NSURL URLWithString:url]];
    NSImage *image = data ? [[NSImage alloc] initWithData:data] : nil;
    return completion(Store(PNG(image, kFaviconSize * 2, &width, &height), width, height, profile, name));
  }
  NSString *scheme = [NSURL URLWithString:url].scheme.lowercaseString;
  if (!([scheme isEqualToString:@"https"] || [scheme isEqualToString:@"http"])) return completion(nil);
  Download(url, profile, ^(NSData *body) {
    if (![privateCache isCurrent:profile generation:generation]) return completion(nil);
    int w = 0, h = 0;
    NSImage *image = body ? [[NSImage alloc] initWithData:body] : nil;
    completion(image ? Store(PNG(image, kFaviconSize * 2, &w, &h), w, h, profile, name) : nil);
  });
}

@end
