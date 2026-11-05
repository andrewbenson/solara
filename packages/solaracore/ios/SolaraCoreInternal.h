#import <AppKit/AppKit.h>

#import "SolaraCore.h"
#import "SolaraCoreHost.h"
#import "SolaraCoreTabStrip.h"

@class SolaraCoreWebView;

NS_ASSUME_NONNULL_BEGIN

namespace solaracore_host {

SolaraCoreProfile *_Nullable LoadedProfile(NSString *name);
bool IsDeletedProfile(NSString *name);
void WithProfile(NSString *name, void (^completion)(SolaraCoreProfile *_Nullable profile));
NSString *ProfileName(SolaraCoreProfile *_Nullable profile);
NSString *ProfileNameOfDirectory(NSString *directory);
SolaraCoreProfile *_Nullable PersonalIfLoaded(SolaraCoreEngine *engine);
bool IsIncognito(NSString *name);
NSString *OriginalProfileName(NSString *_Nullable name);
NSString *OriginalProfileNameOf(SolaraCoreProfile *_Nullable profile);
bool IsOffTheRecordOf(SolaraCoreProfile *_Nullable profile, NSString *_Nullable name);
NSArray<NSString *> *LoadedProfileNames();

int BrowserId(SolaraCoreTab *tab);
SolaraCoreTab *_Nullable TabWithBrowserId(int browserId);

NSString *AppDisposition(NSString *chromeDisposition);

void InstallActivationGuardsEarly();
void InstallActivationGuardsLate();
bool Background();
bool TestHooksAllowed();
bool ShowAlertSheetsInTests(bool show);
void LogActivation(NSString *what);
void SetAppActive(bool active);
void ActToggleFullScreen(NSWindow *window);
void InstallTestCrashGuard(NSString *_Nullable dataDir);

void OpenPopupWindow(SolaraCoreTab *tab, SolaraCoreWebView *_Nullable opener);
bool IsReservedKeyEvent(NSEvent *event);
bool IsReservedBinding(NSString *key, NSString *unshiftedKey, NSEventModifierFlags modifiers);
NSUInteger PopupWindowCount();
NSArray<NSDictionary *> *PopupOrigins();
bool AskPermissionInPopupWindow(SolaraCoreTab *tab, NSDictionary *request);
void DropPopupWindowPermission(NSString *requestId);
void NotePasswordPromptSource(SolaraCoreWebView *view, SolaraCoreTab *_Nullable source);
SolaraCoreTab *_Nullable PasswordPromptTab(SolaraCoreWebView *view, SolaraCoreTab *_Nullable own);

}

@interface SolaraCoreWindowController : NSObject <SolaraCoreWindowDelegate>
+ (nullable SolaraCoreWindowController *)forNSWindow:(nullable NSWindow *)window;
+ (NSArray<SolaraCoreWindowController *> *)all;
@property(nonatomic, readonly) SolaraCoreWindow *coreWindow;
@property(nonatomic, strong, nullable) NSView *root;
@property(nonatomic) NSInteger hostChanges;
@property(nonatomic, copy, nullable) NSString *appWindowId;
+ (SolaraCoreWindowController *)strayWindowForProfile:(SolaraCoreProfile *)profile;
+ (SolaraCoreWindowController *)keeperWindowForProfile:(SolaraCoreProfile *)profile;
+ (nullable SolaraCoreWindowController *)chromeMadeWindowForProfile:(SolaraCoreProfile *)profile;
@property(nonatomic, readonly) BOOL stray;
+ (SolaraCoreWindowController *)standaloneWindowForProfile:(SolaraCoreProfile *)profile;
@property(nonatomic, readonly) BOOL standalone;
- (void)noteClosing:(SolaraCoreTab *)tab;
+ (nullable SolaraCoreWindowController *)holding:(SolaraCoreTab *)tab;
+ (nullable SolaraCoreWebView *)hostingViewForProfile:(nullable SolaraCoreProfile *)profile;
+ (BOOL)userSees:(nullable NSWindow *)window;
@end
extern NSNotificationName const SolaraCoreWindowSeenDidChange;

@interface SolaraCoreTabStrip (Engine)
+ (void)changedInWindow:(SolaraCoreWindowController *)controller profile:(SolaraCoreProfile *)profile;
+ (void)changedInWindow:(SolaraCoreWindowController *)controller profile:(SolaraCoreProfile *)profile cause:(nullable id)cause;
+ (void)windowClosed:(SolaraCoreWindowController *)controller;
+ (void)activated:(SolaraCoreTab *)tab inWindow:(SolaraCoreWindowController *)controller;
+ (nullable SolaraCoreTab *)activeTabInWindow:(SolaraCoreWindowController *)controller profile:(SolaraCoreProfile *)profile;
+ (void)removed:(SolaraCoreTab *)tab fromWindow:(SolaraCoreWindowController *)controller;
+ (void)setPinned:(BOOL)pinned tab:(SolaraCoreTab *)tab;
@end

@interface SolaraCoreProfile (Pending)
- (nullable NSString *)loadComponentExtension:(NSString *)path;
- (void)releaseNavigationHoldReady;
- (void)unloadComponentExtension:(NSString *)extensionId;
@end

namespace solaracore_host {
NSArray<SolaraCoreProfile *> *LoadedProfiles();
void ApplyKeepAwakeSites(SolaraCoreProfile *profile);
void LoadContentBlocker(NSString *profile);
void PrepareContentBlocker();
bool EngineHasTabModel();
}

@interface SolaraCoreTabs : NSObject
+ (void)setView:(nullable SolaraCoreWebView *)view forTab:(SolaraCoreTab *)tab;
+ (nullable SolaraCoreWebView *)viewForTab:(SolaraCoreTab *)tab;
+ (NSString *)offerTab:(SolaraCoreTab *)tab;
+ (NSString *)offerTab:(SolaraCoreTab *)tab prefix:(NSString *)prefix;
+ (nullable SolaraCoreTab *)takeOffered:(NSString *)adoptId;
+ (nullable SolaraCoreTab *)offeredTab:(NSString *)adoptId;
+ (void)forget:(SolaraCoreTab *)tab;
@end

@interface SolaraCoreFavicons (Tabs)
+ (void)noteImage:(nullable NSImage *)image forURL:(nullable NSString *)url profile:(nullable NSString *)profile;
@end

NS_ASSUME_NONNULL_END
