#import <AppKit/AppKit.h>
#import "AssessmentAdapter.h"

static void reply(NSDictionary *message) {
    NSData *json = [NSJSONSerialization dataWithJSONObject:message options:0 error:nil];
    if (!json) exit(2);
    @try {
        [NSFileHandle.fileHandleWithStandardOutput writeData:json];
        [NSFileHandle.fileHandleWithStandardOutput writeData:[@"\n" dataUsingEncoding:NSUTF8StringEncoding]];
    } @catch (NSException *exception) { exit(0); }
}

@interface Agent : NSObject
@property(nonatomic, strong) AssessmentAdapter *adapter;
@property(nonatomic, strong) NSMutableData *input;
@property(nonatomic, copy) NSSet<NSString *> *hidden;
@property(nonatomic, copy) NSSet<NSString *> *allowed;
@property(nonatomic, strong) NSNumber *requestID;
@property(nonatomic) BOOL observingApplications;
@end

@implementation Agent
- (instancetype)init {
    if ((self = [super init])) {
        _adapter = [AssessmentAdapter new]; _input = [NSMutableData data];
        _hidden = [NSSet set]; _allowed = [NSSet set]; _requestID = @0;
        // Agent apps do not always send launch notifications. Observe the actual
        // process list so an unselected newcomer is admitted immediately.
        [NSWorkspace.sharedWorkspace addObserver:self forKeyPath:@"runningApplications" options:NSKeyValueObservingOptionNew context:NULL];
        _observingApplications = YES;
        __weak Agent *weakSelf = self;
        [NSFileHandle.fileHandleWithStandardInput setReadabilityHandler:^(NSFileHandle *handle) {
            NSData *data = handle.availableData;
            dispatch_async(dispatch_get_main_queue(), ^{
                Agent *owner = weakSelf;
                if (!data.length || !owner) { [owner.adapter invalidate]; exit(0); }
                [owner consume:data];
            });
        }];
    }
    return self;
}
- (NSSet *)runningBundles {
    NSMutableSet *result = [NSMutableSet set];
    for (NSRunningApplication *app in NSWorkspace.sharedWorkspace.runningApplications) {
        if (app.bundleIdentifier) [result addObject:app.bundleIdentifier];
    }
    return result;
}
- (void)refreshForApplicationChange {
    if (!_hidden.count) return;
    NSSet *running = [self runningBundles];
    NSMutableSet *newcomers = [running mutableCopy];
    [newcomers minusSet:_hidden]; [newcomers minusSet:_allowed];
    if (newcomers.count || ![running intersectsSet:_hidden]) [self apply];
}
- (void)observeValueForKeyPath:(NSString *)keyPath ofObject:(id)object change:(NSDictionary *)change context:(void *)context {
    (void)object; (void)change; (void)context;
    if ([keyPath isEqualToString:@"runningApplications"]) {
        dispatch_async(dispatch_get_main_queue(), ^{ [self refreshForApplicationChange]; });
    }
}
- (void)dealloc {
    if (_observingApplications) [NSWorkspace.sharedWorkspace removeObserver:self forKeyPath:@"runningApplications"];
}
- (void)apply {
    NSSet *running = [self runningBundles];
    if (!_hidden.count || ![running intersectsSet:_hidden]) {
        [_adapter invalidate]; _allowed = [NSSet set];
        reply(@{@"id": _requestID, @"ok": @YES, @"held": @NO}); return;
    }
    NSMutableSet *allowed = [running mutableCopy]; [allowed minusSet:_hidden]; _allowed = allowed;
    NSNumber *token = _requestID;
    [_adapter activateAllowingBundles:allowed.allObjects completion:^(NSString *error) {
        if (![token isEqual:self.requestID]) return;
        if (error) reply(@{@"id": token, @"ok": @NO, @"held": @NO, @"error": error});
        else reply(@{@"id": token, @"ok": @YES, @"held": @YES});
    }];
}
- (void)consume:(NSData *)data {
    [_input appendData:data];
    if (_input.length > 65536) { [_adapter invalidate]; exit(2); }
    const char newline = '\n';
    for (;;) {
        NSRange line = [_input rangeOfData:[NSData dataWithBytes:&newline length:1] options:0 range:NSMakeRange(0, _input.length)];
        if (line.location == NSNotFound) break;
        NSData *payload = [_input subdataWithRange:NSMakeRange(0, line.location)];
        [_input replaceBytesInRange:NSMakeRange(0, line.location + 1) withBytes:NULL length:0];
        id message = [NSJSONSerialization JSONObjectWithData:payload options:0 error:nil];
        if (![message isKindOfClass:NSDictionary.class] || ![message[@"id"] isKindOfClass:NSNumber.class]
            || ![message[@"hidden"] isKindOfClass:NSArray.class] || [message[@"hidden"] count] > 256) {
            [_adapter invalidate]; exit(2);
        }
        NSMutableSet *hidden = [NSMutableSet set];
        for (id bundle in message[@"hidden"]) {
            if (![bundle isKindOfClass:NSString.class] || ![bundle length] || [bundle length] > 255 || [bundle hasPrefix:@"com.apple."]) {
                [_adapter invalidate]; exit(2);
            }
            [hidden addObject:bundle];
        }
        _requestID = message[@"id"]; _hidden = hidden; [self apply];
    }
}
@end

int main(void) {
    @autoreleasepool {
        [NSApplication sharedApplication];
        [NSApp setActivationPolicy:NSApplicationActivationPolicyProhibited];
        if (![AssessmentAdapter isAvailable]) {
            reply(@{@"id": @0, @"ok": @NO, @"available": @NO, @"error": @"Unsupported macOS or assessment API."}); return 1;
        }
        Agent *agent = [Agent new];
        reply(@{@"id": @0, @"ok": @YES, @"available": @YES});
        [NSApp run];
        [agent.adapter invalidate];
    }
    return 0;
}
