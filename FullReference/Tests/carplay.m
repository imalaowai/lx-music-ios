// Execute the production Objective-C lifecycle with real CarPlay templates and
// controllable IPC completions. This does not impersonate a physical head unit.
#import <UIKit/UIKit.h>
#import <CarPlay/CarPlay.h>

@interface LXFixtureController : NSObject
@property(nonatomic, strong) CPTemplate *rootTemplate;
@property(nonatomic, strong) CPTemplate *top;
@property(nonatomic) NSUInteger sets;
@property(nonatomic) NSUInteger rejects;
@property(nonatomic) BOOL delay;
@property(nonatomic, strong) NSMutableArray *completions;
- (CPTemplate *)topTemplate;
- (void)setRootTemplate:(CPTemplate *)root animated:(BOOL)animated completion:(void (^)(BOOL, NSError *))completion;
- (void)pushTemplate:(CPTemplate *)page animated:(BOOL)animated completion:(void (^)(BOOL, NSError *))completion;
@end
@implementation LXFixtureController
- (instancetype)init { if ((self=[super init])) _completions=[NSMutableArray array]; return self; }
- (CPTemplate *)topTemplate { return self.top ?: self.rootTemplate; }
- (void)setRootTemplate:(CPTemplate *)root animated:(BOOL)animated completion:(void (^)(BOOL, NSError *))completion {
    self.sets++;
    if (self.delay) { [self.completions addObject:[completion copy]]; return; }
    if (self.rejects) { self.rejects--; completion(NO, [NSError errorWithDomain:@"Fixture" code:1 userInfo:@{NSLocalizedDescriptionKey:@"Fixture rejection"}]); return; }
    self.rootTemplate=root; self.top=nil; completion(YES,nil);
}
- (void)pushTemplate:(CPTemplate *)page animated:(BOOL)animated completion:(void (^)(BOOL, NSError *))completion { self.top=page; completion(YES,nil); }
@end
@interface LXFixtureScene : NSObject
@property(nonatomic, strong) LXFixtureController *interfaceController;
@property(nonatomic, weak) id delegate;
- (UISceneActivationState)activationState;
@end
@implementation LXFixtureScene
- (BOOL)isKindOfClass:(Class)cls { return cls==CPTemplateApplicationScene.class || [super isKindOfClass:cls]; }
- (UISceneActivationState)activationState { return UISceneActivationStateForegroundActive; }
@end

// Both reference callback variants are intentionally present: the production
// hook must wrap existing selectors, not silently fail at class_addMethod.
@interface CPSceneDelegate : NSObject
@property(nonatomic, strong) id interfaceController;
@property(nonatomic) NSUInteger audioConnects;
@property(nonatomic) NSUInteger windowConnects;
@property(nonatomic) NSUInteger disconnects;
@property(nonatomic) NSUInteger genericDisconnects;
- (void)setupRootTemplate;
- (void)templateApplicationScene:(id)scene didConnectInterfaceController:(id)controller;
- (void)templateApplicationScene:(id)scene didConnectInterfaceController:(id)controller toWindow:(id)window;
- (void)templateApplicationScene:(id)scene didDisconnectInterfaceController:(id)controller;
- (void)templateApplicationScene:(id)scene didDisconnectInterfaceController:(id)controller fromWindow:(id)window;
- (void)sceneDidBecomeActive:(id)scene;
- (void)sceneWillEnterForeground:(id)scene;
- (void)sceneDidDisconnect:(id)scene;
@end
@implementation CPSceneDelegate
- (void)setupRootTemplate { @throw [NSException exceptionWithName:@"UnhookedRoot" reason:@"Reference root must be wrapped" userInfo:nil]; }
- (void)templateApplicationScene:(id)scene didConnectInterfaceController:(id)controller {
    self.audioConnects++; self.interfaceController=controller; [self setupRootTemplate];
}
- (void)templateApplicationScene:(id)scene didConnectInterfaceController:(id)controller toWindow:(id)window {
    self.windowConnects++; self.interfaceController=controller; [self setupRootTemplate];
}
- (void)templateApplicationScene:(id)scene didDisconnectInterfaceController:(id)controller { self.disconnects++; self.interfaceController=nil; }
- (void)templateApplicationScene:(id)scene didDisconnectInterfaceController:(id)controller fromWindow:(id)window { self.disconnects++; self.interfaceController=nil; }
- (void)sceneDidBecomeActive:(id)scene {}
- (void)sceneWillEnterForeground:(id)scene {}
- (void)sceneDidDisconnect:(id)scene { self.genericDisconnects++; self.interfaceController=nil; }
@end
#define LX_CARPLAY_TESTING 1
#import "../Sources/LXFullCarPlay.m"

static NSMutableDictionary *LXResults;
static void Check(BOOL pass, NSString *name) {
    LXResults[name]=@(pass);
    if (!pass) @throw [NSException exceptionWithName:@"RegressionFailure" reason:name userInfo:nil];
}
static LXFixtureScene *Scene(CPSceneDelegate *owner, LXFixtureController *controller) {
    LXFixtureScene *scene=[LXFixtureScene new]; scene.delegate=owner; scene.interfaceController=controller; return scene;
}
static void RunTests(void) {
    LXInstallFullCarPlay();
    CPSceneDelegate *a=[CPSceneDelegate new];
    LXFixtureController *one=[LXFixtureController new]; LXFixtureScene *s1=Scene(a,one);
    [a templateApplicationScene:s1 didConnectInterfaceController:one];
    Check(a.audioConnects==1 && [one.rootTemplate isKindOfClass:CPTabBarTemplate.class], @"existingAudioCallbackWrapped");
    CPTabBarTemplate *tabs=(id)one.rootTemplate;
    Check(tabs.templates.count==3 && [(CPListTemplate *)tabs.templates[0] sections].count>0 && [(CPListTemplate *)tabs.templates[1] sections].count>0, @"populatedRootBeforeConnectReturns");
    CPTemplate *first=one.rootTemplate;
    [a templateApplicationScene:s1 didConnectInterfaceController:one toWindow:nil];
    Check(one.sets==1 && one.rootTemplate==first && a.windowConnects==0, @"duplicateCallbackKeepsPage");
    one.top=CPNowPlayingTemplate.sharedTemplate;
    [a sceneDidBecomeActive:s1]; [a sceneWillEnterForeground:s1];
    Check(one.sets==1 && one.top==CPNowPlayingTemplate.sharedTemplate, @"activationKeepsNavigationStack");
    one.top=nil; one.rootTemplate=nil;
    [a sceneDidBecomeActive:s1];
    Check(one.sets==2 && one.rootTemplate!=nil, @"activationRestoresMissingRoot");
    LXFixtureController *two=[LXFixtureController new]; LXFixtureScene *s2=Scene(a,two);
    [a templateApplicationScene:s2 didConnectInterfaceController:two toWindow:nil];
    NSUInteger released=a.disconnects;
    [a templateApplicationScene:s1 didDisconnectInterfaceController:one]; [a sceneDidDisconnect:s1]; [a sceneDidBecomeActive:s1];
    Check(LXCurrent.controller==(id)two && a.interfaceController==two && a.disconnects==released && a.genericDisconnects==0, @"staleDisconnectAndActivationCannotClearNewConnection");
    Check(a.windowConnects==1, @"windowCallbackRetainsReferenceOwner");
    [a templateApplicationScene:s2 didDisconnectInterfaceController:two fromWindow:nil];
    Check(!LXCurrent && !a.interfaceController, @"matchingDisconnectReleasesController");
    CPTemplate *oldRoot=two.rootTemplate;
    [a templateApplicationScene:s2 didConnectInterfaceController:two];
    Check(two.rootTemplate!=oldRoot && two.sets==2, @"reusedControllerGetsFreshActionHandlers");

    CPSceneDelegate *b=[CPSceneDelegate new];
    LXFixtureController *delayed=[LXFixtureController new]; delayed.delay=YES; LXFixtureScene *sd=Scene(a,delayed);
    [a templateApplicationScene:sd didConnectInterfaceController:delayed];
    LXCarConnection *old=LXCurrent;
    LXFixtureController *next=[LXFixtureController new]; LXFixtureScene *sn=Scene(b,next);
    [b templateApplicationScene:sn didConnectInterfaceController:next];
    void (^finish)(BOOL,NSError *)=delayed.completions.firstObject; finish(NO,[NSError errorWithDomain:@"Late" code:1 userInfo:nil]);
    LXRootTimeout(old,old.attempt);
    [a templateApplicationScene:sd didDisconnectInterfaceController:delayed]; [a sceneDidDisconnect:sd];
    Check(next.sets==1 && LXCurrent.owner==b && b.interfaceController==next && a.genericDisconnects==0, @"oldAsyncFailureCannotReplaceNewRoot");

    LXFixtureController *reject=[LXFixtureController new]; reject.rejects=1; LXFixtureScene *sr=Scene(b,reject);
    [b templateApplicationScene:sr didConnectInterfaceController:reject];
    Check(reject.sets==2 && [reject.rootTemplate isKindOfClass:CPListTemplate.class] && LXCurrent.simple, @"rejectedTabsUseSinglePopulatedListFallback");
    CPListTemplate *plain=(id)reject.rootTemplate;
    Check(plain.sections.firstObject.items.count>=5 && LXCurrent.lists.sections.count>0, @"fallbackKeepsPlaybackAndLibraryAccess");

    LXFixtureController *timeout=[LXFixtureController new]; timeout.delay=YES; LXFixtureScene *st=Scene(b,timeout);
    [b templateApplicationScene:st didConnectInterfaceController:timeout];
    LXCarConnection *pending=LXCurrent; NSUInteger attempt=pending.attempt;
    timeout.delay=NO; LXRootTimeout(pending,attempt);
    Check(timeout.sets==2 && [timeout.rootTemplate isKindOfClass:CPListTemplate.class], @"missingCompletionHasBoundedFallback");
    void (^late)(BOOL,NSError *)=timeout.completions.firstObject; late(NO,nil); LXRootTimeout(pending,attempt);
    Check(timeout.sets==2, @"lateAttemptCannotRepeatFallback");
    [b sceneDidDisconnect:st];
    Check(!LXCurrent && b.genericDisconnects==1, @"genericSceneDisconnectCleansMatchingSession");
    [b sceneDidBecomeActive:st];
    Check(!LXCurrent, @"retiredSceneCannotReattachStaleController");

    // Exercise the actual supplied reference's missing-audio-selector path.
    IMP audio=LXReferenceAudioConnect, audioDisconnect=LXReferenceAudioDisconnect;
    LXReferenceAudioConnect=NULL; LXReferenceAudioDisconnect=NULL;
    LXFixtureController *missing=[LXFixtureController new]; LXFixtureScene *sm=Scene(a,missing);
    NSUInteger windows=a.windowConnects;
    [a templateApplicationScene:sm didConnectInterfaceController:missing];
    Check(missing.rootTemplate && a.windowConnects==windows+1, @"navigationOnlyReferenceSupportsAudioCallback");
    [a templateApplicationScene:sm didDisconnectInterfaceController:missing];
    LXReferenceAudioConnect=audio; LXReferenceAudioDisconnect=audioDisconnect;

    // Existing-scene recovery covers installing while a scene is already alive.
    LXFixtureController *existing=[LXFixtureController new]; LXFixtureScene *se=Scene(a,existing);
    [a sceneWillEnterForeground:se];
    Check(existing.rootTemplate && LXCurrent.controller==(id)existing, @"foregroundCanAdoptUnobservedScene");
    [NSNotificationCenter.defaultCenter postNotificationName:UISceneDidActivateNotification object:se];
    Check(existing.sets==1, @"sceneNotificationIsIdempotent");
    [a templateApplicationScene:se didDisconnectInterfaceController:existing];
    for (NSUInteger i=0;i<20;i++) {
        LXFixtureController *repeat=[LXFixtureController new]; LXFixtureScene *rs=Scene(a,repeat);
        if (i%2) [a templateApplicationScene:rs didConnectInterfaceController:repeat toWindow:nil];
        else [a templateApplicationScene:rs didConnectInterfaceController:repeat];
        [a sceneDidBecomeActive:rs];
        if (!repeat.rootTemplate || repeat.sets!=1) @throw [NSException exceptionWithName:@"RepeatedOpen" reason:@"Repeated open lost or reset root" userInfo:nil];
        [a templateApplicationScene:rs didDisconnectInterfaceController:repeat];
        if (LXCurrent || a.interfaceController) @throw [NSException exceptionWithName:@"RepeatedClose" reason:@"Repeated close retained connection" userInfo:nil];
    }
    Check(YES, @"twentyAlternatingReconnectsRemainUsable");
    // More than 120 events must not erase process/connection metadata or grow unbounded.
    for (NSUInteger i=0;i<130;i++) LXRecord(@"回归记录", @"test");
    NSDictionary *saved=[NSJSONSerialization JSONObjectWithData:[NSData dataWithContentsOfURL:LXDiagnosticURL()] options:0 error:nil];
    Check([saved[@"history"] count]==120 && [saved[@"hooks"][@"audio"] boolValue] && [saved[@"process"] length]>0, @"diagnosticHistoryIsBoundedAndIdentifiesProcess");
    LXHistory=nil; LXRecord(@"新进程模拟", @"test-restart");
    Check(LXHistory.count==120 && [LXHistory[LXHistory.count-2][@"phase"] isEqual:@"回归记录"], @"diagnosticsPreservePreviousProcessHistory");
}

@interface LXCarPlayTestApp : UIResponder <UIApplicationDelegate>
@property(nonatomic, strong) UIWindow *window;
@end
@implementation LXCarPlayTestApp
- (BOOL)application:(UIApplication *)app didFinishLaunchingWithOptions:(NSDictionary *)options {
    self.window=[[UIWindow alloc] initWithFrame:UIScreen.mainScreen.bounds]; self.window.rootViewController=[UIViewController new]; [self.window makeKeyAndVisible];
    dispatch_async(dispatch_get_main_queue(), ^{
        LXResults=[NSMutableDictionary dictionary];
        @try { RunTests(); } @catch (NSException *error) { LXResults[@"failure"]=error.reason ?: error.name; }
        NSData *data=[NSJSONSerialization dataWithJSONObject:LXResults options:NSJSONWritingPrettyPrinted error:nil];
        NSURL *doc=[NSFileManager.defaultManager URLsForDirectory:NSDocumentDirectory inDomains:NSUserDomainMask].firstObject;
        [data writeToURL:[doc URLByAppendingPathComponent:@"carplay-lifecycle.json"] options:NSDataWritingAtomic error:nil];
    });
    return YES;
}
@end
int main(int argc,char **argv) { @autoreleasepool { return UIApplicationMain(argc,argv,nil,NSStringFromClass(LXCarPlayTestApp.class)); } }
