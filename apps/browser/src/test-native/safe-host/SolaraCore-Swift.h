#pragma once
#import <Foundation/Foundation.h>

@interface NativePrivateDownloadRoutes : NSObject
@property(class, readonly) NativePrivateDownloadRoutes *shared;
- (NSString *)profile:(NSString *)downloadId;
- (NSDictionary *)forwardedDownload:(NSDictionary *)download profile:(NSString *)profile epoch:(NSInteger)epoch privateDownloadsSupported:(BOOL)supported;
- (NSNumber *)privateEventEpoch:(NSString *)topic payload:(NSDictionary *)payload;
- (BOOL)isCurrentPrivateEvent:(NSString *)profile epoch:(NSInteger)epoch privateDownloadsSupported:(BOOL)supported;
@end

@implementation NativePrivateDownloadRoutes {
  NSMutableDictionary<NSString *, NSString *> *_profiles;
}
+ (NativePrivateDownloadRoutes *)shared {
  static NativePrivateDownloadRoutes *shared = [NativePrivateDownloadRoutes new];
  return shared;
}
- (instancetype)init {
  if ((self = [super init])) _profiles = [NSMutableDictionary dictionary];
  return self;
}
- (NSString *)profile:(NSString *)downloadId { return _profiles[downloadId]; }
- (NSDictionary *)forwardedDownload:(NSDictionary *)download profile:(NSString *)profile epoch:(NSInteger)epoch privateDownloadsSupported:(BOOL)supported {
  NSCAssert(![download[@"offTheRecord"] boolValue] && epoch == 0 && !supported, @"private download fixture requires Swift coverage");
  if (download[@"id"]) _profiles[download[@"id"]] = profile;
  NSMutableDictionary *forwarded = [download mutableCopy];
  forwarded[@"profile"] = profile;
  return forwarded;
}
- (NSNumber *)privateEventEpoch:(NSString *)topic payload:(NSDictionary *)payload {
  NSCAssert(![payload[@"download"][@"offTheRecord"] boolValue], @"private download fixture requires Swift coverage");
  return nil;
}
- (BOOL)isCurrentPrivateEvent:(NSString *)profile epoch:(NSInteger)epoch privateDownloadsSupported:(BOOL)supported {
  NSCAssert(epoch == 0 && !supported, @"private download fixture requires Swift coverage");
  return YES;
}
@end

bool SolaraPrivateDownloadSourceFenceAvailable() { return false; }
