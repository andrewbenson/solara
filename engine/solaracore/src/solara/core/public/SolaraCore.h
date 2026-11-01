#import <AppKit/AppKit.h>

#define SOLARACORE_EXPORT __attribute__((visibility("default")))

NS_ASSUME_NONNULL_BEGIN

@class SolaraCoreEngine;
@class SolaraCoreProfile;
@class SolaraCoreTab;
@class SolaraCoreWindow;

@protocol SolaraCoreEngineDelegate <NSObject>
- (void)engineDidStart;
@optional
- (void)engineWillShutDown;
- (void)engineQuitCancelled;
- (nullable SolaraCoreWindow*)engineWindowForNewBrowserOfProfile:(SolaraCoreProfile*)profile
                                                        type:(NSString*)type;
- (void)engine:(SolaraCoreEngine*)engine
    permissionRequest:(NSDictionary<NSString*, id>*)request
                  tab:(SolaraCoreTab*)tab;
- (void)engine:(SolaraCoreEngine*)engine permissionRequestDismissed:(NSString*)requestId;
- (void)engine:(SolaraCoreEngine*)engine
    extensionSidePanel:(NSDictionary<NSString*, id>*)panel
                   tab:(SolaraCoreTab*)tab;
- (BOOL)engine:(SolaraCoreEngine*)engine
    extensionActionPopup:(NSDictionary<NSString*, id>*)popup
                     tab:(SolaraCoreTab*)tab;
- (BOOL)engine:(SolaraCoreEngine*)engine
    extensionActionShortcut:(NSDictionary<NSString*, id>*)shortcut
                        tab:(SolaraCoreTab*)tab;
- (BOOL)engineIsReservedKeyEvent:(NSEvent*)event;
- (BOOL)engineIsReservedKey:(NSString*)key
               unshiftedKey:(NSString*)unshiftedKey
                  modifiers:(NSEventModifierFlags)modifiers;
- (void)engine:(SolaraCoreEngine*)engine
    extensionInstallPrompt:(NSDictionary<NSString*, id>*)prompt
                       tab:(nullable SolaraCoreTab*)tab;
- (void)engine:(SolaraCoreEngine*)engine
    deviceChooser:(NSDictionary<NSString*, id>*)chooser
              tab:(SolaraCoreTab*)tab;
- (void)engine:(SolaraCoreEngine*)engine
    castDialog:(NSDictionary<NSString*, id>*)dialog
           tab:(SolaraCoreTab*)tab;
- (void)engine:(SolaraCoreEngine*)engine
    castRoutes:(NSArray<NSDictionary<NSString*, NSString*>*>*)routes
       profile:(SolaraCoreProfile*)profile;
@end

SOLARACORE_EXPORT
@interface SolaraCoreEngine : NSObject
+ (int)runWithArgc:(int)argc
              argv:(const char* _Nonnull* _Nonnull)argv
          delegate:(id<SolaraCoreEngineDelegate>)delegate;
@property(class, readonly, nullable) SolaraCoreEngine* sharedEngine;

@property(readonly) SolaraCoreProfile* defaultProfile;
- (void)loadProfile:(NSString*)directoryName
         completion:(void (^)(SolaraCoreProfile* _Nullable profile))completion;
- (void)quit;
@property(nonatomic, copy, nullable) NSString* pageScript;
- (void)resolvePermission:(NSString*)requestId
                   result:(NSString*)result
                 remember:(BOOL)remember;
+ (void)resolveExtensionInstallPrompt:(NSString*)requestId accepted:(BOOL)accepted;
+ (void)startCasting:(int)dialogId sink:(NSString*)sinkId mode:(int)castMode;
+ (void)stopCasting:(int)dialogId route:(NSString*)routeId;
+ (void)closeCastDialog:(int)dialogId;
+ (void)terminateCastRoute:(NSString*)routeId;
+ (void)setAutoPictureInPicture:(BOOL)enabled;
+ (void)setVideoUpscaling:(BOOL)enabled;
+ (void)setVideoUpscalingTestConditions:(NSDictionary<NSString*, NSNumber*>*)conditions;
@property(class, readonly) NSDictionary<NSString*, id>* videoUpscalingState;
+ (void)reservedShortcutsChanged;
+ (BOOL)isReservedGlobalShortcut:(NSString*)shortcut;
+ (void)selectDevice:(int)chooserId index:(int)index;
+ (void)cancelDeviceChooser:(int)chooserId;
+ (void)refreshDeviceChooser:(int)chooserId;
+ (void)openDeviceChooserSettings:(int)chooserId;
+ (void)beginTracing:(void (^)(BOOL started))completion;
+ (void)endTracing:(BOOL)keep completion:(void (^)(NSString* _Nullable path))completion;
@property(class, readonly) BOOL isTracing;
- (void)deleteProfile:(SolaraCoreProfile*)profile
           completion:(nullable void (^)(BOOL deleted))completion;
- (void)releaseProfile:(SolaraCoreProfile*)profile;
+ (void)resolveExternalApp:(NSString*)requestId open:(BOOL)open remember:(BOOL)remember;
@property(class, readonly) NSArray<NSDictionary*>* testExternalLaunches;
@property(class, readonly) NSArray<NSDictionary*>* testChooserEvents;
+ (void)allowDesktopCapture:(NSString*)sourceId
                        tab:(SolaraCoreTab*)tab
                      frame:(nullable NSString*)frameId
                     origin:(nullable NSString*)origin
                      audio:(nullable NSString*)audio;
@property(class, readonly) NSDictionary<NSString*, NSNumber*>* desktopCaptureAudio;
- (void)offTheRecordProfileFor:(SolaraCoreProfile*)profile
                    completion:(void (^)(SolaraCoreProfile* _Nullable offTheRecord,
                                         NSString* _Nullable error))completion;
@property(readonly) NSString* chromiumVersion;
@property(readonly) NSString* keepAliveState;
@end

SOLARACORE_EXPORT
@interface SolaraCoreProfile : NSObject
@property(readonly) NSString* name;
@property(readonly) NSString* path;
@property(readonly) BOOL offTheRecord;
@property(readonly) BOOL destroyed;
- (nullable NSString*)loadComponentExtension:(NSString*)path;
- (void)unloadComponentExtension:(NSString*)extensionId;
- (void)warmSpareRenderer;
- (void)holdNavigationsUntilRulesetsOf:(NSString*)extensionId;
- (void)releaseNavigationHold:(NSString*)reason;
- (void)releaseNavigationHoldReady;
- (void)watchCastRoutes;
@property(readonly) NSArray<NSDictionary<NSString*, id>*>* extensions;
- (nullable NSNumber*)boolPreference:(NSString*)name;
- (void)setBoolPreference:(NSString*)name value:(BOOL)value;
- (void)clearBrowsingData:(NSArray<NSString*>*)types
                    since:(nullable NSDate*)since
               completion:(nullable void (^)(void))completion;
@end

@interface SolaraCoreProfile (Icons)
- (void)fetchIcon:(NSString*)url
         maxBytes:(NSUInteger)maxBytes
       completion:(void (^)(NSData* _Nullable body))completion;
@end

@protocol SolaraCoreWindowDelegate <NSObject>
@optional
- (void)window:(SolaraCoreWindow*)window
    didInsertTab:(SolaraCoreTab*)tab
          opener:(nullable SolaraCoreTab*)opener
     disposition:(NSString*)disposition;
- (void)window:(SolaraCoreWindow*)window didRemoveTab:(SolaraCoreTab*)tab;
- (void)window:(SolaraCoreWindow*)window didActivateTab:(SolaraCoreTab*)tab;
- (void)window:(SolaraCoreWindow*)window
    devToolsDidChangeForTab:(SolaraCoreTab*)tab
                       view:(nullable NSView*)devToolsView;
- (void)window:(SolaraCoreWindow*)window
                    tab:(SolaraCoreTab*)tab
    didChangeFullscreen:(BOOL)fullscreen;
- (void)window:(SolaraCoreWindow*)window
    passwordPrompt:(NSDictionary<NSString*, id>*)prompt
            forTab:(SolaraCoreTab*)tab;
- (void)window:(SolaraCoreWindow*)window
    autofillPrompt:(NSDictionary<NSString*, id>*)prompt
            forTab:(SolaraCoreTab*)tab;
- (void)window:(SolaraCoreWindow*)window
    passwordSavePromptForTab:(SolaraCoreTab*)tab
                    username:(NSString*)username
                      origin:(NSString*)origin;
- (void)window:(SolaraCoreWindow*)window showRequestedActive:(BOOL)active;
- (BOOL)windowShouldClose:(SolaraCoreWindow*)window;
- (NSArray<SolaraCoreTab*>*)window:(SolaraCoreWindow*)window
                 tabsToKeepOnClose:(NSArray<SolaraCoreTab*>*)tabs
                    closedByChrome:(BOOL)closedByChrome;
- (void)window:(SolaraCoreWindow*)window
    moveKeptTabs:(NSArray<SolaraCoreTab*>*)tabs;
- (void)windowDidCancelClose:(SolaraCoreWindow*)window;
- (void)window:(SolaraCoreWindow*)window
    confirmCloseWithDownloads:(int)count
                   completion:(void (^)(BOOL closeAnyway))completion;
- (BOOL)window:(SolaraCoreWindow*)window preHandleKeyEvent:(NSEvent*)event;
- (BOOL)window:(SolaraCoreWindow*)window handleKeyEvent:(NSEvent*)event;
@end

SOLARACORE_EXPORT
@interface SolaraCoreWindow : NSObject
- (instancetype)initWithContentRect:(NSRect)rect;
@property(readonly) NSWindow* window;
@property(readonly) NSView* hostView;
@property(readonly) BOOL closing;
- (NSInteger)keptOnCloseCountForProfile:(SolaraCoreProfile*)profile;
@property(weak, nullable) id<SolaraCoreWindowDelegate> delegate;

- (SolaraCoreTab*)openTab:(NSString*)url
              profile:(SolaraCoreProfile*)profile
           foreground:(BOOL)foreground;
- (nullable SolaraCoreTab*)openExtensionView:(NSString*)url
                                 profile:(SolaraCoreProfile*)profile
                                    kind:(NSString*)kind;
@property(nonatomic, nullable) SolaraCoreProfile* activeProfile;
- (void)activateTab:(SolaraCoreTab*)tab;
- (NSArray<SolaraCoreTab*>*)tabsForProfile:(SolaraCoreProfile*)profile;
- (int)chromeWindowIdForProfile:(SolaraCoreProfile*)profile;
- (BOOL)executeChromeCommand:(int)commandId profile:(SolaraCoreProfile*)profile;
- (void)showInactive;
@property(nonatomic) BOOL actedFullScreen;
- (void)close;

- (void)prepareProfile:(SolaraCoreProfile*)profile;
- (NSDictionary<NSString*, id>*)devCloseBrowserKeepingWindow:(SolaraCoreProfile*)profile;
- (void)adoptTab:(SolaraCoreTab*)tab;
- (nullable SolaraCoreTab*)restoreTab:(nullable NSString*)state
                          profile:(SolaraCoreProfile*)profile
                       foreground:(BOOL)foreground;
- (nullable SolaraCoreTab*)duplicateTab:(SolaraCoreTab*)source
                            profile:(SolaraCoreProfile*)profile
                         foreground:(BOOL)foreground;
- (void)placeTab:(SolaraCoreTab*)tab index:(int)index pinned:(BOOL)pinned;
@property(nonatomic) BOOL internal;
@end

@protocol SolaraCoreTabDelegate <NSObject>
@optional
- (void)tabDidChangeTitle:(SolaraCoreTab*)tab;
- (void)tabDidChangeURL:(SolaraCoreTab*)tab;
- (void)tabDidChangeLoading:(SolaraCoreTab*)tab;
- (void)tabDidChangeProgress:(SolaraCoreTab*)tab;
- (void)tabDidChangeFavicon:(SolaraCoreTab*)tab;
- (void)tabDidChangeNavigationState:(SolaraCoreTab*)tab;
- (void)tab:(SolaraCoreTab*)tab didFindMatches:(int)count active:(int)active final:(BOOL)final;
- (void)tab:(SolaraCoreTab*)tab didReceivePageMessage:(NSString*)kind json:(NSString*)json;
- (void)tab:(SolaraCoreTab*)tab
    didReceivePageMessage:(NSString*)kind
                     json:(NSString*)json
                    frame:(NSString*)frameId
                     main:(BOOL)main;
- (void)tab:(SolaraCoreTab*)tab
    didReceivePageMessage:(NSString*)kind
                     json:(NSString*)json
                    frame:(NSString*)frameId
                     main:(BOOL)main
                   origin:(NSString*)origin;
- (void)tabWillClose:(SolaraCoreTab*)tab;
- (void)tab:(SolaraCoreTab*)tab rendererGone:(NSString*)status code:(int)code;
- (void)tab:(SolaraCoreTab*)tab didFailLoad:(NSString*)url code:(int)code description:(NSString*)text;
- (void)tab:(SolaraCoreTab*)tab didChangeStatusText:(NSString*)text;
- (void)tab:(SolaraCoreTab*)tab didRequestAppURL:(NSString*)url userGesture:(BOOL)userGesture;
- (void)tabDidChangeThemeColor:(SolaraCoreTab*)tab;
- (void)tabDidCommitDocument:(SolaraCoreTab*)tab;
- (void)tabDidGainFocus:(SolaraCoreTab*)tab;
- (void)tabDidChangeAudio:(SolaraCoreTab*)tab;
- (void)tabDidChangeSecurity:(SolaraCoreTab*)tab;
- (void)tabDidChangeZoom:(SolaraCoreTab*)tab;
- (void)tab:(SolaraCoreTab*)tab didBlockPopup:(NSDictionary<NSString*, NSString*>*)popup;
- (void)tab:(SolaraCoreTab*)tab preferredSizeDidChange:(NSSize)size;
- (void)tab:(SolaraCoreTab*)tab externalAppRequest:(NSDictionary<NSString*, id>*)request;
- (void)tab:(SolaraCoreTab*)tab requestsActivation:(NSString*)reason;
- (void)tab:(SolaraCoreTab*)tab didChangePictureInPicture:(NSDictionary<NSString*, id>*)state;
- (void)tab:(SolaraCoreTab*)tab didShowAutofillSuggestions:(NSArray<NSDictionary<NSString*, NSString*>*>*)items;
- (void)tab:(SolaraCoreTab*)tab didBlockRequests:(int)count lastURL:(NSString*)url;
- (NSArray<NSDictionary<NSString*, NSString*>*>*)tab:(SolaraCoreTab*)tab
                         contextMenuItemsForSelection:(NSString*)text;
- (void)tab:(SolaraCoreTab*)tab
    contextMenuCommand:(NSString*)itemId
                  text:(NSString*)selection
             modifiers:(NSDictionary<NSString*, NSNumber*>*)modifiers;
- (void)tab:(SolaraCoreTab*)tab didShowContextMenu:(NSArray<NSDictionary*>*)items;
- (nullable NSDictionary<NSString*, id>*)tab:(SolaraCoreTab*)tab
                              runContextMenu:(NSDictionary<NSString*, id>*)menu;
- (void)tab:(SolaraCoreTab*)tab navigationBecameDownload:(NSString*)url;
- (void)tabDidChangeDiscarded:(SolaraCoreTab*)tab;
- (void)tabBecameUnresponsive:(SolaraCoreTab*)tab;
- (void)tabBecameResponsive:(SolaraCoreTab*)tab;
- (void)tab:(SolaraCoreTab*)tab didChangeMediaAccess:(NSDictionary<NSString*, NSNumber*>*)access;
@end

SOLARACORE_EXPORT
@interface SolaraCoreTab : NSObject
@property(readonly) NSView* view;
@property(readonly, weak) SolaraCoreProfile* profile;
@property(readonly) int tabId;
@property(readonly) NSString* url;
@property(readonly) NSString* title;
@property(readonly) BOOL loading;
@property(readonly) double progress;
@property(readonly, nullable) NSImage* favicon;
@property(readonly) BOOL canGoBack;
@property(readonly) BOOL canGoForward;
@property(readonly) BOOL closed;
@property(readonly) BOOL closingWithWindow;
@property(weak, nullable) id<SolaraCoreTabDelegate> delegate;

- (void)loadURL:(NSString*)url;
- (void)focus;
- (void)find:(NSString*)text forward:(BOOL)forward;
- (void)stopFinding;
- (void)goBack;
- (void)goForward;
- (void)reload;
- (void)stop;
- (void)close;
- (void)showDevTools;
- (void)closeDevTools;
@property(readonly, nullable) NSView* devToolsView;
- (void)devToolsLayoutForSize:(NSSize)size
                     devTools:(NSRect*)devToolsFrame
                         page:(NSRect*)pageFrame;
@property(readonly, nullable) NSDictionary<NSString*, id>* passwordPrompt;
- (void)resolvePasswordPrompt:(NSString*)action
                     username:(nullable NSString*)username
                     password:(nullable NSString*)password;
@property(readonly, nullable) NSDictionary<NSString*, id>* autofillPrompt;
- (void)resolveAutofillPrompt:(NSInteger)promptId action:(NSString*)action;

@property(readonly, nullable) NSString* faviconURL;
@property(readonly, nullable) NSString* themeColor;
@property(readonly) BOOL audible;
@property(nonatomic) BOOL muted;
@property(readonly) int browserId;
@property(readonly, nullable) NSString* committedOrigin;
+ (nullable NSString*)originForURL:(NSString*)url;
@property(readonly) BOOL initialDocumentAccessed;
@property(readonly) BOOL committedInitial;
- (nullable id)suppressInput;
- (void)loadURL:(NSString*)url userInitiated:(BOOL)userInitiated;
- (void)goToOffset:(int)offset;
- (void)reloadIgnoringCache;
- (void)loadIfNeeded;
- (void)closeNow;
@property(nonatomic) BOOL temporary;
- (void)setTemporarySource:(nullable SolaraCoreTab*)source;
- (void)deliverHeldPageMessages;
@property(readonly) NSArray<NSDictionary<NSString*, id>*>* navigationEntries;
- (void)executeJavaScript:(NSString*)code;
- (void)executeJavaScript:(NSString*)code frame:(NSString*)frameId;
- (void)evaluate:(NSString*)code completion:(void (^)(NSString* _Nullable json))completion;
- (void)exitPictureInPicture;
- (void)enterPictureInPictureForClickAt:(NSTimeInterval)clickTime
                             completion:(void (^)(NSString* route, BOOL opened))completion;
- (BOOL)hasLiveFrame:(NSString*)frameId;
- (void)callPage:(NSString*)kind json:(NSString*)json;

@property(readonly) NSDictionary<NSString*, id>* securityInfo;
@property(nonatomic) double zoomFactor;
- (void)zoomStep:(int)direction;
@property(readonly) double pinchScale;
- (BOOL)executeChromeCommand:(int)command;
- (void)openBlockedPopup:(NSString*)popupId always:(BOOL)always;
- (BOOL)discard;
@property(readonly) BOOL discarded;
@property(nonatomic) BOOL frozen;
- (void)resolveUnresponsive:(BOOL)terminate;
@property(nonatomic, nullable) NSColor* pageBackgroundColor;
@property(nonatomic, copy, nullable) NSString* pageColor;
@property(nonatomic, nullable) NSColor* contentsBackgroundColor;
- (NSString*)executeExtensionAction:(NSString*)extensionId;
- (NSDictionary<NSString*, NSDictionary*>*)actionStatesForExtensions:(NSArray<NSString*>*)extensionIds;
- (nullable NSString*)sidePanelURLForExtension:(NSString*)extensionId;
@property(readonly, nullable) NSString* mediaCaptureSourceId;
- (void)copyPicture:(NSTimeInterval)timeout completion:(void (^)(CGImageRef _Nullable picture))completion;
- (BOOL)stopCapture;
@property(readonly) BOOL autoPictureInPictureIsChromes;
- (void)noteShownByHost:(BOOL)shown;
- (void)exitFullscreen;
- (void)exitExclusiveAccess;
- (void)tracePictureInPicture:(NSString*)line withInputs:(BOOL)withInputs;
- (void)devToolsCall:(NSString*)method
              params:(nullable NSDictionary*)params
          completion:(void (^)(NSDictionary* _Nullable result,
                               NSString* _Nullable error))completion;
- (void)devToolsCall:(NSString*)method
              params:(nullable NSDictionary*)params
             timeout:(NSTimeInterval)timeout
          completion:(void (^)(NSDictionary* _Nullable result,
                               NSString* _Nullable error))completion;
- (BOOL)canShareThisTabInsteadFor:(SolaraCoreTab*)capturer;
- (BOOL)shareThisTabInsteadFor:(SolaraCoreTab*)capturer;
- (BOOL)showAutofillSuggestions:(BOOL)passwords;
- (BOOL)showCastDialog;
- (BOOL)devShowBluetoothChooser:(BOOL)unauthorized;
@property(readonly, nullable) NSDictionary<NSString*, NSNumber*>* popupFeatures;
@property(readonly) NSSize preferredSize;
- (void)callFrame:(NSString*)frameId kind:(NSString*)kind json:(NSString*)json;
@end

NS_ASSUME_NONNULL_END
