#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

FOUNDATION_EXPORT NSErrorDomain const SolaraCoreBookmarkURLErrorDomain;

typedef NS_ERROR_ENUM(SolaraCoreBookmarkURLErrorDomain, SolaraCoreBookmarkURLError) {
  SolaraCoreBookmarkURLUnavailable = 1,
  SolaraCoreBookmarkURLInvalid = 2,
  SolaraCoreBookmarkURLBadReply = 3,
};

@interface SolaraCoreEngineBridge : NSObject
+ (nullable NSString *)canonicalBookmarkURL:(NSString *)url
                                     error:(NSError * _Nullable * _Nullable)error NS_SWIFT_NAME(canonicalBookmarkURL(_:));
+ (nullable NSString *)canonicalBookmarkURLUTF16:(NSData *)units
                                          error:(NSError * _Nullable * _Nullable)error NS_SWIFT_NAME(canonicalBookmarkURLUTF16(_:));
+ (void)call:(NSString *)name
       profile:(NSString *)profile
          args:(nullable NSString *)args
    completion:(void (^)(NSString *json))completion NS_SWIFT_NAME(call(_:profile:args:completion:));
+ (void)callWithSecret:(NSString *)name
               profile:(NSString *)profile
                  args:(NSMutableData *)args
            completion:(void (^)(NSString *json))completion NS_SWIFT_NAME(callWithSecret(_:profile:args:completion:));
+ (void)setEventHandler:(nullable void (^)(NSString *topic, NSString *json))handler;
+ (void)forwardTopics:(NSArray<NSString *> *)topics;
+ (void)observe:(NSString *)topic handler:(void (^)(NSDictionary<NSString *, id> *payload))handler;
+ (BOOL)exports:(NSString *)name;
+ (nullable NSDictionary<NSString *, id> *)configureHooks:(NSString *)json NS_SWIFT_NAME(configureHooks(_:));
+ (nullable NSDictionary<NSString *, id> *)matchHooks:(NSString *)url NS_SWIFT_NAME(matchHooks(_:));
@end

NS_ASSUME_NONNULL_END
