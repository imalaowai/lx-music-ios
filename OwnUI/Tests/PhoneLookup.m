#import "PhoneLookup.h"
UIView *LXOwnMakeRoot(void) {
    Class root=NSClassFromString(@"LXOwnUIRootView");
    return root ? [[root alloc] initWithFrame:CGRectZero] : nil;
}
