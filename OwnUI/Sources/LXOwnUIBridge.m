#import <React/RCTEventEmitter.h>
#import <React/RCTViewManager.h>
#import <UIKit/UIKit.h>
#import "LXFullLibrary.h"

@interface LXOwnUIBridge : RCTEventEmitter <RCTBridgeModule>
@property(nonatomic) BOOL listening;
@property(nonatomic, strong) NSMutableArray *pending;
@end
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
    if (self.listening) [self sendEventWithName:@"own-ui-audio-command" body:note.userInfo];
    else if (self.pending.count<128) [self.pending addObject:note.userInfo];
}
- (void)library:(NSNotification *)note { [LXFullLibrary.shared update:note.userInfo error:nil]; }
- (void)drain:(NSNotification *)note { for (NSDictionary *action in [LXFullLibrary.shared drain]) [NSNotificationCenter.defaultCenter postNotificationName:@"LXOwnCarPlayAction" object:nil userInfo:action]; }
RCT_EXPORT_METHOD(ready) {
    Class integration=NSClassFromString(@"LXOwnIntegration");
    if ([integration respondsToSelector:NSSelectorFromString(@"activate")]) [integration performSelector:NSSelectorFromString(@"activate")];
}
RCT_EXPORT_METHOD(reportState:(NSDictionary *)value) { [NSNotificationCenter.defaultCenter postNotificationName:@"LXOwnAudioState" object:nil userInfo:value]; }
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
