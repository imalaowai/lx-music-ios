#import "PhoneLookup.h"
#import <objc/message.h>
BOOL LXOwnMediaIsIdle(void) {
    Class cls=NSClassFromString(@"LXNowPlayingCoordinator");
    id owner=((id (*)(id,SEL))objc_msgSend)(cls,NSSelectorFromString(@"shared"));
    return ![owner valueForKey:@"publishedInfo"] && ![[owner valueForKey:@"controlsInstalled"] boolValue] && ![owner valueForKey:@"placeholder"];
}
UIView *LXOwnMakeRoot(void) {
    Class root=NSClassFromString(@"LXOwnUIRootView");
    return root ? [[root alloc] initWithFrame:CGRectZero] : nil;
}
