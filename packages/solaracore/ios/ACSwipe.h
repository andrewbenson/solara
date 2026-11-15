#import <AppKit/AppKit.h>

NS_ASSUME_NONNULL_BEGIN

@protocol ACSwipeTarget <NSObject>
@property (nonatomic, readonly) BOOL canSwipeBack;
@property (nonatomic, readonly) BOOL canSwipeForward;
@property (nonatomic, readonly) BOOL tracksUnavailableDirections;
@property (nonatomic, readonly) BOOL allowsVerticalMotion;
@optional
@property (nonatomic, readonly) BOOL isPager;
@property (nonatomic, readonly) BOOL hasNativePager;
@property (nonatomic, readonly) BOOL coversPage;
- (void)pagerInput:(NSString *)phase distance:(CGFloat)distance direction:(int)direction timestamp:(NSTimeInterval)timestamp;
#if SOLARA_PROBES
- (void)cancelProbeSwipe;
#endif
@required
- (void)swipeEvent:(NSDictionary<NSString *, id> *)event;
@end

@interface ACSwipe : NSObject

+ (void)performHaptic:(NSString *)pattern;

+ (void)addTarget:(NSView<ACSwipeTarget> *)target;
+ (void)removeTarget:(NSView<ACSwipeTarget> *)target;
+ (void)cancelTarget:(NSView<ACSwipeTarget> *)target;

+ (void)simulateInWindow:(NSWindow *)window
                   point:(NSPoint)point
                   steps:(NSArray<NSDictionary<NSString *, id> *> *)steps
  ignoreSystemPreference:(BOOL)ignoreSystemPreference
              completion:(void (^)(NSDictionary<NSString *, id> *result))completion;

#if SOLARA_PROBES
@property (class, nonatomic, readonly) BOOL probeDelivery;
@property (class, nonatomic, readonly) NSDictionary<NSString *, NSNumber *> *hapticSnapshot;

+ (dispatch_block_t)simulateInWindow:(NSWindow *)window
                              point:(NSPoint)point
                              steps:(NSArray<NSDictionary<NSString *, id> *> *)steps
             ignoreSystemPreference:(BOOL)ignoreSystemPreference
                     shouldContinue:(nullable BOOL (^)(void))shouldContinue
                         completion:(void (^)(NSDictionary<NSString *, id> *result))completion;
#endif

@end

NS_ASSUME_NONNULL_END
