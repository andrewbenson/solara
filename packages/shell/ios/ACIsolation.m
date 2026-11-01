#import "ACIsolation.h"

#import <AppKit/AppKit.h>
#import <objc/runtime.h>

static NSString *gDataDirectory;
static NSUserDefaults *gDefaults;

NSString *ACIsolatedDataDirectory(void) { return gDataDirectory; }

static NSUserDefaults *IsolatedStandardUserDefaults(id self, SEL _cmd) { return gDefaults; }

static NSString *gPasteboardName;
static NSString *gFindPasteboardName;
static IMP gPasteboardWithName;

static NSPasteboard *SystemPasteboardWithName(NSPasteboardName name) {
  return ((NSPasteboard * (*)(id, SEL, NSPasteboardName)) gPasteboardWithName)(NSPasteboard.class, @selector(pasteboardWithName:), name);
}

static NSPasteboard *IsolatedGeneralPasteboard(id self, SEL _cmd) { return SystemPasteboardWithName(gPasteboardName); }

static NSPasteboard *IsolatedPasteboardWithName(id self, SEL _cmd, NSPasteboardName name) {
  if ([name isEqualToString:NSPasteboardNameGeneral]) return SystemPasteboardWithName(gPasteboardName);
  if ([name isEqualToString:NSPasteboardNameFind]) return SystemPasteboardWithName(gFindPasteboardName);
  return SystemPasteboardWithName(name);
}

static void IsolatePasteboard(NSString *scope) {
  gPasteboardName = [@"com.solara.scratch:" stringByAppendingString:scope];
  gFindPasteboardName = [@"com.solara.scratch.find:" stringByAppendingString:scope];
  Method withName = class_getClassMethod(NSPasteboard.class, @selector(pasteboardWithName:));
  gPasteboardWithName = method_getImplementation(withName);
  method_setImplementation(withName, (IMP)IsolatedPasteboardWithName);
  method_setImplementation(class_getClassMethod(NSPasteboard.class, @selector(generalPasteboard)), (IMP)IsolatedGeneralPasteboard);
  [NSNotificationCenter.defaultCenter addObserverForName:NSApplicationWillTerminateNotification
                                                  object:nil
                                                   queue:nil
                                              usingBlock:^(NSNotification *note) {
                                                [SystemPasteboardWithName(gPasteboardName) releaseGlobally];
                                                [SystemPasteboardWithName(gFindPasteboardName) releaseGlobally];
                                                NSLog(@"ACIsolation: released isolated pasteboards %@", gPasteboardName);
                                              }];
}

static BOOL BackgroundInstance(void) {
  const char *background = getenv("SOLARA_BACKGROUND");
  return background && !strcmp(background, "1");
}

static BOOL ShouldIsolatePasteboard(void) {
#if DEBUG
  if (gDataDirectory) return YES;
#endif
  return BackgroundInstance();
}

@interface ACIsolation : NSObject
@end

@implementation ACIsolation

+ (void)load {
  const char *dir = getenv("SOLARA_DATA_DIR");
  if (dir && *dir) {
    NSString *path = @(dir);
    if (!path.absolutePath)
      path = [NSFileManager.defaultManager.currentDirectoryPath stringByAppendingPathComponent:path];
    gDataDirectory = path.stringByStandardizingPath;
  }
  if (ShouldIsolatePasteboard())
    IsolatePasteboard(gDataDirectory ?: [NSString stringWithFormat:@"pid-%d", getpid()]);
  if (!gDataDirectory) return;
  NSString *domain = NSBundle.mainBundle.bundleIdentifier ?: @"network.benson.solara.unbundled";
  gDefaults = [[NSUserDefaults alloc]
      initWithSuiteName:[[gDataDirectory stringByAppendingPathComponent:@"Preferences"] stringByAppendingPathComponent:domain]];
  if (!gDefaults) return;
  method_setImplementation(class_getClassMethod(NSUserDefaults.class, @selector(standardUserDefaults)),
                           (IMP)IsolatedStandardUserDefaults);
}

@end
