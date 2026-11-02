#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

__attribute__((swift_attr("@MainActor")))
@interface SolaraCoreNotifications : NSObject
+ (BOOL)install;
+ (void)abortStartup;
+ (BOOL)configureRoot:(NSString *)path;
+ (void)setEventHandler:(void (^)(NSDictionary<NSString *, id> *event))handler owner:(NSString *)owner;
+ (void)clearEventHandler:(NSString *)owner;
+ (void)watch:(void (^)(NSDictionary<NSString *, id> *result))completion;
+ (void)consume:(NSDictionary<NSString *, id> *)event completion:(void (^)(NSDictionary<NSString *, id> *result))completion;
+ (void)control:(NSDictionary<NSString *, id> *)payload completion:(void (^)(NSDictionary<NSString *, id> *result))completion;
+ (void)debugSnapshot:(void (^)(NSDictionary<NSString *, id> *result))completion;
+ (void)debugDisplayed:(NSString *)profile origin:(NSString *)origin completion:(void (^)(NSDictionary<NSString *, id> *result))completion;
@end

NS_ASSUME_NONNULL_END
