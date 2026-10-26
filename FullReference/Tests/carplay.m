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
@property(nonatomic) BOOL blockRoots;
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
    if (self.blockRoots || self.rejects) { if(self.rejects)self.rejects--; completion(NO, [NSError errorWithDomain:@"Fixture" code:1 userInfo:@{NSLocalizedDescriptionKey:@"Fixture rejection"}]); return; }
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

// Standalone decoder modules expose the same selectors as the preserved IPA.
// Exercise the real native guard with no RN/JavaScript event loop present.
typedef void (^LXTestResolve)(id);
typedef void (^LXTestReject)(NSString *,NSString *,NSError *);
@interface RNTrackPlayer:NSObject
@property(nonatomic) NSUInteger plays;
@property(nonatomic,strong) NSDictionary *lastEvent;
- (void)sendEventWithName:(NSString *)name body:(id)body;
@property(nonatomic) NSUInteger pauses;
- (void)play:(LXTestResolve)resolve rejecter:(LXTestReject)reject;
- (void)pause:(LXTestResolve)resolve rejecter:(LXTestReject)reject;
@end
@implementation RNTrackPlayer
- (void)sendEventWithName:(NSString *)name body:(id)body {self.lastEvent=body;}
- (void)play:(LXTestResolve)resolve rejecter:(LXTestReject)reject {self.plays++;if(resolve)resolve(nil);}
- (void)pause:(LXTestResolve)resolve rejecter:(LXTestReject)reject {self.pauses++;if(resolve)resolve(nil);}
@end
@interface StreamingFlacPlayerModule:NSObject
@property(nonatomic) NSUInteger resumes;
@property(nonatomic) NSUInteger pauses;
- (void)resumeStreamWithResolver:(LXTestResolve)resolve rejecter:(LXTestReject)reject;
- (void)pauseStreamWithResolver:(LXTestResolve)resolve rejecter:(LXTestReject)reject;
@end
@implementation StreamingFlacPlayerModule
- (void)resumeStreamWithResolver:(LXTestResolve)resolve rejecter:(LXTestReject)reject {self.resumes++;if(resolve)resolve(nil);}
- (void)pauseStreamWithResolver:(LXTestResolve)resolve rejecter:(LXTestReject)reject {self.pauses++;if(resolve)resolve(nil);}
@end
@interface NowPlayingModule:NSObject
@property(nonatomic) double rate;
- (void)playNowPlaying:(NSDictionary *)value resolver:(LXTestResolve)resolve rejecter:(LXTestReject)reject;
- (void)pauseNowPlaying:(NSDictionary *)value resolver:(LXTestResolve)resolve rejecter:(LXTestReject)reject;
@end
@implementation NowPlayingModule
- (void)playNowPlaying:(NSDictionary *)value resolver:(LXTestResolve)resolve rejecter:(LXTestReject)reject {self.rate=1;if(resolve)resolve(nil);}
- (void)pauseNowPlaying:(NSDictionary *)value resolver:(LXTestResolve)resolve rejecter:(LXTestReject)reject {self.rate=0;if(resolve)resolve(nil);}
@end
#import "../../OwnUI/Sources/LXAudioRouteSafety.m"
#import "../../OwnUI/Sources/LXNowPlayingCoordinator.m"
#import "../../OwnUI/Tests/NowPlayingTests.m"

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
    // Call our actual observer with the fixture. Broadcasting a fake UIScene
    // to UIKit's own observers would require private UIKit scene internals.
    LXHandleSceneEvent([NSNotification notificationWithName:UISceneDidActivateNotification object:se]);
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
    LXFixtureController *held=[LXFixtureController new]; held.delay=YES;
    __weak LXCarConnection *releasedConnection;
    @autoreleasepool {
        LXFixtureScene *heldScene=Scene(a,held);
        [a templateApplicationScene:heldScene didConnectInterfaceController:held];
        releasedConnection=LXCurrent;
        [a templateApplicationScene:heldScene didDisconnectInterfaceController:held];
    }
    Check(releasedConnection==nil && held.completions.count==1, @"unansweredSystemCompletionCannotRetainDisconnectedSession");
    // Reopen after backgrounding without a new process. UIKit's current scene
    // inventory is authoritative; stale detached callbacks remain rejected.
    LXFixtureController *reuse=[LXFixtureController new]; LXFixtureScene *reuseScene=Scene(a,reuse);
    [a templateApplicationScene:reuseScene didConnectInterfaceController:reuse];
    [a templateApplicationScene:reuseScene didDisconnectInterfaceController:reuse];
    LXConnectedScenesForTesting=[NSSet setWithObject:reuseScene];
    [a sceneWillEnterForeground:reuseScene];
    Check(LXCurrent.controller==(id)reuse && reuse.sets==2, @"retiredLiveSceneReopensWithoutKillingPhoneApp");
    LXFixtureController *replacement=[LXFixtureController new];reuseScene.interfaceController=replacement;
    [a sceneDidBecomeActive:reuseScene];
    Check(LXCurrent.controller==(id)replacement && replacement.sets==1, @"currentSceneControllerReplacementIsRecovered");
    LXFixtureController *newCar=[LXFixtureController new];LXFixtureScene *newScene=Scene(b,newCar);
    LXConnectedScenesForTesting=[NSSet setWithObject:newScene];
    LXHandleSceneEvent([NSNotification notificationWithName:UISceneDidActivateNotification object:newScene]);
    Check(LXCurrent.controller==(id)newCar && newCar.rootTemplate!=nil, @"orphanedOldConnectionCannotBlockLiveCarScene");
    LXHandleSceneEvent([NSNotification notificationWithName:UISceneDidDisconnectNotification object:reuseScene]);
    Check(LXCurrent.controller==(id)newCar,@"staleDisconnectNotificationCannotReleaseReconnectedCar");
    LXHandleSceneEvent([NSNotification notificationWithName:UISceneDidDisconnectNotification object:newScene]);
    Check(LXCurrent==nil,@"systemDisconnectNotificationReleasesCurrentController");
    LXConnectedScenesForTesting=[NSSet set];
    [b sceneDidBecomeActive:newScene];Check(LXCurrent==nil,@"disconnectedSceneStillCannotRecoverFromLateDelegateCallback");
    LXFixtureController *routeRecovered=[LXFixtureController new];LXFixtureScene *routeScene=Scene(a,routeRecovered);
    LXConnectedScenesForTesting=[NSSet setWithObject:routeScene];
    [NSNotificationCenter.defaultCenter postNotificationName:@"LXOwnCarPlayReconcile" object:nil];
    Check(LXCurrent.controller==(id)routeRecovered && routeRecovered.rootTemplate!=nil,@"newAudioRouteReconcilesAnAlreadyForegroundCarScene");
    [a templateApplicationScene:routeScene didDisconnectInterfaceController:routeRecovered];LXConnectedScenesForTesting=[NSSet set];
    LXReconcileLiveScenes();Check(LXCurrent==nil,@"audioRecoveryDoesNotCreateAnAbsentCarScene");
    LXConnectedScenesForTesting=nil;
    // IPC may temporarily reject new menus while retaining a non-nil old root.
    // A stale root is not evidence that the new connection is usable.
    LXFixtureController *warming=[LXFixtureController new];warming.blockRoots=YES;
    CPTemplate *staleRoot=[[CPListTemplate alloc] initWithTitle:@"旧连接菜单" sections:@[]];warming.rootTemplate=staleRoot;
    LXFixtureScene *warmingScene=Scene(a,warming);[a templateApplicationScene:warmingScene didConnectInterfaceController:warming];
    warming.blockRoots=NO;[a sceneDidBecomeActive:warmingScene];
    Check(warming.rootTemplate!=staleRoot && warming.rootTemplate==LXCurrent.root,@"foregroundRetriesRejectedRootEvenWhenOldRootStillExists");
    LXFixtureController *silent=[LXFixtureController new];silent.delay=YES;silent.rootTemplate=staleRoot;
    LXFixtureScene *silentScene=Scene(b,silent);[b templateApplicationScene:silentScene didConnectInterfaceController:silent];
    LXCarConnection *silentConnection=LXCurrent;NSUInteger silentAttempt=silentConnection.attempt;silent.delay=NO;LXRootTimeout(silentConnection,silentAttempt);
    Check(silent.rootTemplate!=staleRoot && silent.rootTemplate==LXCurrent.root && silent.sets==2,@"timeoutCannotMistakePreviousConnectionRootForCurrentRoot");
    [b templateApplicationScene:silentScene didDisconnectInterfaceController:silent];

    LXOwnInstallAudioSafety();
    RNTrackPlayer *track=[RNTrackPlayer new];StreamingFlacPlayerModule *flac=[StreamingFlacPlayerModule new];NowPlayingModule *metadata=[NowPlayingModule new];
    [track sendEventWithName:@"remote-play" body:@{@"position":@17}];
    Check([track.lastEvent[@"nativeEventAt"] doubleValue]>0 && [track.lastEvent[@"position"] intValue]==17,@"remoteCommandsAreTimestampedBeforeJavaScriptQueuesThem");
    [track play:nil rejecter:nil];[flac resumeStreamWithResolver:nil rejecter:nil];
    [NSNotificationCenter.defaultCenter postNotificationName:@"LXOwnAudioRouteHold" object:nil userInfo:@{@"held":@YES}];
    Check(track.pauses>0 && flac.pauses>0,@"outputLossPausesBothNativeDecodersWithoutJavaScript");
    [track play:nil rejecter:nil];[flac resumeStreamWithResolver:nil rejecter:nil];
    Check(track.plays==1 && flac.resumes==1,@"lateNativePlayCannotBypassOutputLossHold");
    [metadata playNowPlaying:@{@"playbackRate":@1} resolver:nil rejecter:nil];Check(metadata.rate==0,@"lateMetadataCannotRestorePlayingDuringOutputHold");
    [NSNotificationCenter.defaultCenter postNotificationName:@"LXOwnAudioRouteHold" object:nil userInfo:@{@"held":@NO}];
    Check(track.plays==1 && flac.resumes==1,@"releasingHoldDoesNotAutoplayEitherDecoder");
    [track play:nil rejecter:nil];[flac resumeStreamWithResolver:nil rejecter:nil];
    Check(track.plays==2 && flac.resumes==2,@"explicitPlaybackCanResumePreservedNativeDecoders");
    // More than 120 events must not erase process/connection metadata or grow unbounded.
    for (NSUInteger i=0;i<130;i++) LXRecord(@"回归记录", @"test");
    NSDictionary *saved=[NSJSONSerialization JSONObjectWithData:[NSData dataWithContentsOfURL:LXDiagnosticURL()] options:0 error:nil];
    Check([saved[@"history"] count]==120 && [saved[@"hooks"][@"audio"] boolValue] && [saved[@"process"] length]>0, @"diagnosticHistoryIsBoundedAndIdentifiesProcess");
    LXHistory=nil; LXRecord(@"新进程模拟", @"test-restart");
    Check(LXHistory.count==120 && [LXHistory[LXHistory.count-2][@"phase"] isEqual:@"回归记录"], @"diagnosticsPreservePreviousProcessHistory");
    LXRunNowPlayingTests(^(BOOL pass,NSString *name){Check(pass,name);});
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
