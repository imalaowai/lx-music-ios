#import "PhoneLookup.h"
#import <objc/message.h>
#import <MediaPlayer/MediaPlayer.h>
BOOL LXOwnInvokeTransport(NSString *command) {
    Class cls=NSClassFromString(@"LXNowPlayingCoordinator");
    id owner=((id (*)(id,SEL))objc_msgSend)(cls,NSSelectorFromString(@"shared"));
    id target=[owner valueForKey:@"remoteTargets"][command];
    if(!target)return NO;
    return ((NSInteger (*)(id,SEL,id))objc_msgSend)(target,NSSelectorFromString(@"invoke:"),nil)==MPRemoteCommandHandlerStatusSuccess;
}
BOOL LXOwnMediaIsIdle(void) {
    Class cls=NSClassFromString(@"LXNowPlayingCoordinator");
    id owner=((id (*)(id,SEL))objc_msgSend)(cls,NSSelectorFromString(@"shared"));
    return ![owner valueForKey:@"publishedInfo"] && ![[owner valueForKey:@"controlsInstalled"] boolValue] && ![owner valueForKey:@"placeholder"];
}
UIView *LXOwnMakeRoot(void) {
    Class root=NSClassFromString(@"LXOwnUIRootView");
    return root ? [[root alloc] initWithFrame:CGRectZero] : nil;
}
