#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

@interface SolaraCoreTabStrip : NSObject
+ (void)setHandler:(nullable void (^)(NSDictionary<NSString *, id> *transaction))handler;
+ (NSInteger)addObserver:(void (^)(NSDictionary<NSString *, id> *transaction))observer;
+ (void)removeObserver:(NSInteger)token;
+ (void)claimCommands;
@property(class, readonly) BOOL commandsClaimed;
@property(class, readonly) NSDictionary<NSString *, id> *allStrips;
+ (void)command:(NSInteger)commandId command:(NSDictionary<NSString *, id> *)command NS_SWIFT_NAME(command(_:command:));
@end

NS_ASSUME_NONNULL_END
