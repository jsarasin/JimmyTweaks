#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN
// Private API is linked only into the disposable assertion holder, never the UI process.
@interface AssessmentAdapter : NSObject
+ (BOOL)isAvailable;
+ (NSString *)capabilityReport;
- (void)activateAllowingBundles:(NSArray<NSString *> *)bundles
                    completion:(void (^)(NSString * _Nullable error))completion;
- (void)invalidate;
@end
NS_ASSUME_NONNULL_END
