#import "AssessmentAdapter.h"
#import <dlfcn.h>
#import <objc/runtime.h>

@protocol IAConfiguration
- (instancetype)initWithAllowedSystemItems:(NSArray<NSNumber *> *)items
                 allowedBundleIdentifiers:(NSArray<NSString *> *)bundles;
@end
@protocol IAAssertion
- (void)activateWithConfiguration:(id)configuration completionHandler:(void (^)(NSError *))handler;
- (void)invalidate;
@end

static BOOL IALoad(void) {
    static void *handle;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        handle = dlopen("/System/Library/PrivateFrameworks/MenuBarClientCore.framework/MenuBarClientCore", RTLD_NOW | RTLD_LOCAL);
    });
    return handle != NULL;
}

// Reject a changed method signature before making an undocumented call.
static BOOL IAMatches(Class cls, SEL selector, const char *result, NSArray<NSString *> *arguments) {
    Method method = class_getInstanceMethod(cls, selector);
    if (!method) return NO;
    NSMethodSignature *signature = [NSMethodSignature signatureWithObjCTypes:method_getTypeEncoding(method)];
    if (strcmp(signature.methodReturnType, result) || signature.numberOfArguments != arguments.count + 2) return NO;
    for (NSUInteger i = 0; i < arguments.count; i++) {
        if (strcmp([signature getArgumentTypeAtIndex:i + 2], arguments[i].UTF8String)) return NO;
    }
    return YES;
}

static BOOL IAAvailable(void) {
    if (!IALoad()) return NO;
    Class config = NSClassFromString(@"MBAssessmentModeConfiguration");
    Class assertion = NSClassFromString(@"MBAssessmentModeAssertion");
    return IAMatches(config, @selector(initWithAllowedSystemItems:allowedBundleIdentifiers:), "@", @[@"@", @"@"])
        && IAMatches(assertion, @selector(activateWithConfiguration:completionHandler:), "v", @[@"@", @"@?"])
        && IAMatches(assertion, @selector(invalidate), "v", @[]);
}

@implementation AssessmentAdapter {
    id<IAAssertion> _assertion;
    NSUInteger _generation;
}

+ (NSString *)capabilityReport {
    NSMutableArray *lines = [NSMutableArray arrayWithObject:[NSString stringWithFormat:@"dlopen=%@; compatible method signatures=%@", IALoad() ? @"YES" : @"NO", IAAvailable() ? @"YES" : @"NO"]];
    for (NSString *name in @[@"MBAssessmentModeConfiguration", @"MBAssessmentModeAssertion"]) {
        Class cls = NSClassFromString(name);
        [lines addObject:[NSString stringWithFormat:@"%@ present=%@", name, cls ? @"YES" : @"NO"]];
        for (NSString *selector in @[@"initWithAllowedSystemItems:allowedBundleIdentifiers:", @"activateWithConfiguration:completionHandler:", @"invalidate"]) {
            Method method = class_getInstanceMethod(cls, NSSelectorFromString(selector));
            if (method) [lines addObject:[NSString stringWithFormat:@"  %@ %s", selector, method_getTypeEncoding(method)]];
        }
    }
    return [lines componentsJoinedByString:@"\n"];
}

- (void)activateAllowingBundles:(NSArray<NSString *> *)bundles completion:(void (^)(NSString *))completion {
    NSAssert(NSThread.isMainThread, @"Main thread only");
    [self invalidate];
    if (!IAAvailable()) { completion(@"Private framework or ABI unavailable; no assertion held."); return; }
    NSUInteger generation = _generation;
    @try {
        Class configClass = NSClassFromString(@"MBAssessmentModeConfiguration");
        // The nine values are reverse-engineered, NOT an Apple-supported contract.
        NSArray *systemItems = @[@0, @1, @2, @3, @4, @5, @6, @7, @8];
        id configuration = [(id<IAConfiguration>)[configClass alloc] initWithAllowedSystemItems:systemItems allowedBundleIdentifiers:bundles];
        Class assertionClass = NSClassFromString(@"MBAssessmentModeAssertion");
        _assertion = (id<IAAssertion>)[[assertionClass alloc] init];
        if (!configuration || !_assertion) { [self invalidate]; completion(@"Private object initialization failed."); return; }
        __weak AssessmentAdapter *weakSelf = self;
        [_assertion activateWithConfiguration:configuration completionHandler:^(NSError *error) {
            dispatch_async(dispatch_get_main_queue(), ^{
                AssessmentAdapter *owner = weakSelf;
                if (!owner || owner->_generation != generation) return;
                if (error) [owner invalidate];
                completion(error.localizedDescription);
            });
        }];
    } @catch (NSException *exception) {
        [self invalidate];
        completion([NSString stringWithFormat:@"Private API exception: %@: %@", exception.name, exception.reason]);
    }
}

- (void)invalidate {
    _generation++;
    id<IAAssertion> old = _assertion;
    _assertion = nil;
    @try { [old invalidate]; }
    @catch (NSException *exception) { NSLog(@"Assertion invalidation exception: %@", exception); }
}
- (void)dealloc { [self invalidate]; }
@end
