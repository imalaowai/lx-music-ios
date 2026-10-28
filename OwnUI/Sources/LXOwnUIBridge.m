#import <React/RCTEventEmitter.h>
#import <React/RCTViewManager.h>
#import <UIKit/UIKit.h>
#import <objc/runtime.h>
#import <objc/message.h>
#import "LXFullLibrary.h"

@interface LXOwnUIBridge : RCTEventEmitter <RCTBridgeModule>
@property(nonatomic) BOOL listening;
@property(nonatomic, strong) NSMutableArray *pending;
@end

static IMP LXOwnPreviousBackgroundDownload;
static void LXOwnBackgroundDownload(id owner,SEL selector,id application,NSString *identifier,void (^completion)(void)) {
    if ([identifier isEqualToString:@"net.minyue.lxcompanion.downloads"]) {
        Class integration=NSClassFromString(@"LXOwnIntegration");
        SEL action=NSSelectorFromString(@"handleBackgroundDownload:");
        if ([integration respondsToSelector:action]) { ((void (*)(id,SEL,id))objc_msgSend)(integration,action,completion); return; }
    }
    if (LXOwnPreviousBackgroundDownload) ((void (*)(id,SEL,id,id,id))LXOwnPreviousBackgroundDownload)(owner,selector,application,identifier,completion);
    else if (completion) completion();
}
__attribute__((constructor)) static void LXOwnInstallBackgroundDownload(void) {
    Class app=NSClassFromString(@"AppDelegate");
    SEL selector=NSSelectorFromString(@"application:handleEventsForBackgroundURLSession:completionHandler:");
    Method method=class_getInstanceMethod(app,selector);
    if (method) LXOwnPreviousBackgroundDownload=method_setImplementation(method,(IMP)LXOwnBackgroundDownload);
    else if (app) class_addMethod(app,selector,(IMP)LXOwnBackgroundDownload,"v@:@@@?");
}
@implementation LXOwnUIBridge
RCT_EXPORT_MODULE();
+ (BOOL)requiresMainQueueSetup { return YES; }
- (dispatch_queue_t)methodQueue { return dispatch_get_main_queue(); }
- (instancetype)init {
    if ((self=[super init])) {
        _pending=[NSMutableArray array];
        [NSNotificationCenter.defaultCenter addObserver:self selector:@selector(command:) name:@"LXOwnAudioCommand" object:nil];
        [NSNotificationCenter.defaultCenter addObserver:self selector:@selector(library:) name:@"LXOwnLibrary" object:nil];
        [NSNotificationCenter.defaultCenter addObserver:self selector:@selector(drain:) name:@"LXOwnDrainCarPlay" object:nil];
    }
    return self;
}
- (void)dealloc { [NSNotificationCenter.defaultCenter removeObserver:self]; }
- (NSArray *)supportedEvents { return @[@"own-ui-audio-command"]; }
- (void)startObserving { self.listening=YES; for (NSDictionary *command in self.pending) [self sendEventWithName:@"own-ui-audio-command" body:command]; [self.pending removeAllObjects]; }
- (void)stopObserving { self.listening=NO; }
- (void)command:(NSNotification *)note {
    NSDictionary *command=[note.userInfo isKindOfClass:NSDictionary.class]?note.userInfo:@{};
    NSString *operation=[command[@"operation"] isKindOfClass:NSString.class]?command[@"operation"]:@"";
    // Probes are disposable snapshots, not playback commands. Never queue them while
    // JavaScript is suspended: they can otherwise fill the 128-entry queue and block a track load.
    if([operation isEqualToString:@"probe"])return;
    if(self.listening){[self sendEventWithName:@"own-ui-audio-command" body:command];return;}
    NSInteger generation=[command[@"generation"] integerValue];
    NSInteger newest=-1;
    for(NSDictionary *queued in self.pending) newest=MAX(newest,[queued[@"generation"] integerValue]);
    if(generation<newest)return;
    if([@[@"load",@"clear",@"transition"] containsObject:operation]){
        NSIndexSet *stale=[self.pending indexesOfObjectsPassingTest:^BOOL(NSDictionary *queued,NSUInteger idx,BOOL *stop){return [queued[@"generation"] integerValue]<=generation;}];
        [self.pending removeObjectsAtIndexes:stale];
    }else if([@[@"play",@"pause"] containsObject:operation]){
        NSIndexSet *superseded=[self.pending indexesOfObjectsPassingTest:^BOOL(NSDictionary *queued,NSUInteger idx,BOOL *stop){
            NSString *queuedOperation=[queued[@"operation"] isKindOfClass:NSString.class]?queued[@"operation"]:@"";
            return [queued[@"generation"] integerValue]==generation && [@[@"play",@"pause"] containsObject:queuedOperation];
        }];
        [self.pending removeObjectsAtIndexes:superseded];
    }else if([@[@"seek",@"volume"] containsObject:operation]){
        NSIndexSet *superseded=[self.pending indexesOfObjectsPassingTest:^BOOL(NSDictionary *queued,NSUInteger idx,BOOL *stop){
            return [queued[@"generation"] integerValue]==generation && [queued[@"operation"] isEqual:operation];
        }];
        [self.pending removeObjectsAtIndexes:superseded];
    }
    if(self.pending.count>=128)[self.pending removeObjectAtIndex:0];
    [self.pending addObject:command];
}
- (void)library:(NSNotification *)note { [LXFullLibrary.shared update:note.userInfo error:nil]; }
- (void)drain:(NSNotification *)note { for (NSDictionary *action in [LXFullLibrary.shared drain]) [NSNotificationCenter.defaultCenter postNotificationName:@"LXOwnCarPlayAction" object:nil userInfo:action]; }
RCT_EXPORT_METHOD(ready) {
    Class integration=NSClassFromString(@"LXOwnIntegration");
    if ([integration respondsToSelector:NSSelectorFromString(@"activate")]) [integration performSelector:NSSelectorFromString(@"activate")];
}
RCT_EXPORT_METHOD(reportState:(NSDictionary *)value) { [NSNotificationCenter.defaultCenter postNotificationName:@"LXOwnAudioState" object:nil userInfo:value]; }
RCT_EXPORT_METHOD(audioReady) { [NSNotificationCenter.defaultCenter postNotificationName:@"LXOwnAudioReady" object:nil]; }
RCT_EXPORT_METHOD(complete:(NSString *)ticket value:(NSDictionary *)value error:(NSString *)error) { [NSNotificationCenter.defaultCenter postNotificationName:@"LXOwnAudioReply" object:nil userInfo:@{@"ticket":ticket?:@"",@"value":value?:@{},@"error":error?:@""}]; }
RCT_EXPORT_METHOD(remote:(NSDictionary *)value) { [NSNotificationCenter.defaultCenter postNotificationName:@"LXOwnRemoteCommand" object:nil userInfo:value]; }
RCT_EXPORT_METHOD(bootError:(NSString *)message) { NSLog(@"[LXOwnUI] phone bootstrap error: %@",message); }
@end

@interface LXOwnUIRootManager : RCTViewManager @end
@implementation LXOwnUIRootManager
RCT_EXPORT_MODULE(LXOwnUIRoot);
+ (BOOL)requiresMainQueueSetup { return YES; }
- (UIView *)view {
    Class root=NSClassFromString(@"LXOwnUIRootView");
    if (root) return [[root alloc] initWithFrame:CGRectZero];
    UILabel *label=[UILabel new]; label.text=@"自有界面组件未加载，请重新安装完整整合包"; label.numberOfLines=0; return label;
}
@end
