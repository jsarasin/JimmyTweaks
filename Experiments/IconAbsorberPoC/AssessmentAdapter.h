#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN
// Experimental private-API boundary. Never linked into Jimmy Tweaks.
@interface AssessmentAdapter : NSObject
+ (NSString *)capabilityReport;
- (void)activateAllowingBundles:(NSArray<NSString *> *)bundles
                    completion:(void (^)(NSString * _Nullable error))completion;
- (void)invalidate;
@end
NS_ASSUME_NONNULL_END
