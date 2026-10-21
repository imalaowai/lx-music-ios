#import <UIKit/UIKit.h>
#import <CarPlay/CarPlay.h>
#import <MediaPlayer/MediaPlayer.h>
#import <objc/runtime.h>
#ifndef LX_CARPLAY_TESTING
#import <React/RCTEventEmitter.h>
#import <React/RCTBridgeModule.h>
#endif
#import "LXFullLibrary.h"

// Keep the reference's scene/audio owner. Templates and asynchronous results
// belong to a particular controller connection, never to the delegate alone.
@interface LXCarConnection : NSObject
@property(nonatomic, weak) id owner;
@property(nonatomic, weak) CPTemplateApplicationScene *scene;
@property(nonatomic, strong) CPInterfaceController *controller;
@property(nonatomic, strong) CPWindow *window;
@property(nonatomic, strong) CPListTemplate *home;
@property(nonatomic, strong) CPListTemplate *lists;
@property(nonatomic, strong) CPListTemplate *recent;
@property(nonatomic, strong) CPTemplate *root;
@property(nonatomic, copy) NSString *identifier;
@property(nonatomic) NSUInteger generation;
@property(nonatomic) NSUInteger attempt;
@property(nonatomic) BOOL installing;
@property(nonatomic) BOOL simple;
@property(nonatomic) BOOL audio;
@end
@implementation LXCarConnection
@end

static IMP LXReferenceRoot, LXReferenceConnect, LXReferenceDisconnect;
static IMP LXReferenceAudioConnect, LXReferenceAudioDisconnect;
static IMP LXReferenceActive, LXReferenceForeground, LXReferenceSceneDisconnect;
static LXCarConnection *LXCurrent;
static char LXConnectionKey, LXRetiredSceneKey;
static NSUInteger LXGeneration;
static NSString *LXPhase = @"未连接", *LXError = @"", *LXCallback = @"";
static NSString *LXProcessID;
static NSMutableArray *LXHistory;
static NSDictionary *LXHooks;

static NSURL *LXDiagnosticURL(void) {
    NSURL *documents = [NSFileManager.defaultManager URLsForDirectory:NSDocumentDirectory inDomains:NSUserDomainMask].firstObject;
    [NSFileManager.defaultManager createDirectoryAtURL:documents withIntermediateDirectories:YES attributes:nil error:nil];
    return [documents URLByAppendingPathComponent:@"LX-CarPlay-Connection.json"];
}
static BOOL LXIsCurrent(LXCarConnection *connection) {
    return connection && LXCurrent == connection && connection.owner && connection.controller;
}
static NSString *LXClassName(id object) { return object ? NSStringFromClass([object class]) : @""; }
static void LXRecord(NSString *phase, NSString *callback) {
    if (!NSThread.isMainThread) { dispatch_async(dispatch_get_main_queue(), ^{ LXRecord(phase, callback); }); return; }
    if (!LXHistory) {
        NSData *previous = [NSData dataWithContentsOfURL:LXDiagnosticURL()];
        id json = previous ? [NSJSONSerialization JSONObjectWithData:previous options:0 error:nil] : nil;
        LXHistory = [NSMutableArray array];
        if ([json isKindOfClass:NSDictionary.class] && [json[@"history"] isKindOfClass:NSArray.class])
            for (id entry in json[@"history"]) if ([entry isKindOfClass:NSDictionary.class]) [LXHistory addObject:entry];
        LXProcessID = NSUUID.UUID.UUIDString;
    }
    if (phase.length) LXPhase = phase;
    if (callback.length) LXCallback = callback;
    LXCarConnection *c = LXCurrent;
    NSDictionary *event = @{@"at": @([NSDate.date timeIntervalSince1970]), @"phase": LXPhase,
        @"callback": LXCallback, @"error": LXError, @"process": LXProcessID,
        @"connection": c.identifier ?: @"", @"generation": @(c.generation), @"attempt": @(c.attempt),
        @"root": LXClassName(c.controller.rootTemplate), @"top": LXClassName(c.controller.topTemplate)};
    [LXHistory addObject:event];
    while (LXHistory.count > 120) [LXHistory removeObjectAtIndex:0];
    NSDictionary *info = @{@"build": NSBundle.mainBundle.infoDictionary[@"CFBundleVersion"] ?: @"",
        @"bundleIdentifier": NSBundle.mainBundle.bundleIdentifier ?: @"", @"iOS": UIDevice.currentDevice.systemVersion,
        @"phase": LXPhase, @"callback": LXCallback, @"error": LXError, @"process": LXProcessID,
        @"connected": @(LXIsCurrent(c)), @"connection": c.identifier ?: @"", @"generation": @(c.generation),
        @"root": LXClassName(c.controller.rootTemplate), @"top": LXClassName(c.controller.topTemplate),
        @"sceneState": c.scene ? @(c.scene.activationState) : @(-1),
        @"cachedPlaylists": @([LXFullLibrary.shared.snapshot[@"lists"] count]),
        @"referenceDelegateLoaded": @(NSClassFromString(@"CPSceneDelegate") != Nil),
        @"hooks": LXHooks ?: @{}, @"history": [LXHistory copy]};
    NSData *json = [NSJSONSerialization dataWithJSONObject:info options:NSJSONWritingPrettyPrinted error:nil];
    [json writeToURL:LXDiagnosticURL() options:NSDataWritingAtomic error:nil];
}
static void LXMain(dispatch_block_t action) {
    if (NSThread.isMainThread) action(); else dispatch_sync(dispatch_get_main_queue(), action);
}
static NSString *LXText(id value, NSString *fallback) { return [value isKindOfClass:NSString.class] && [value length] ? value : fallback; }
static void LXPush(CPTemplate *page) {
    LXCarConnection *c = LXCurrent;
    if (!LXIsCurrent(c) || !page || c.controller.topTemplate == page) return;
    __weak LXCarConnection *weak = c;
    [c.controller pushTemplate:page animated:YES completion:^(BOOL ok, NSError *error) {
        if (!LXIsCurrent(weak)) return;
        if (!ok) { LXError = error.localizedDescription ?: @"无法打开车机页面"; LXRecord(@"车机页面打开失败", nil); }
    }];
}
static CPListItem *LXRow(NSString *title, NSString *detail, dispatch_block_t action) {
    CPListItem *item = [[CPListItem alloc] initWithText:title detailText:detail];
    __weak LXCarConnection *connection = LXCurrent;
    if (action) item.handler = ^(id<CPSelectableListItem> row, dispatch_block_t completion) {
        @try { if (LXIsCurrent(connection)) action(); }
        @catch (NSException *error) { LXError = error.reason ?: @"菜单操作失败"; LXRecord(@"车机菜单操作异常", nil); }
        @finally { completion(); }
    };
    return item;
}
static CPListSection *LXSection(NSArray *rows) { return [[CPListSection alloc] initWithItems:rows]; }
static void LXCommand(NSString *command) {
    [NSNotificationCenter.defaultCenter postNotificationName:@"LXRemoteCommand" object:nil userInfo:@{@"command": command}];
}
static NSArray *LXSongRows(NSArray *songs, NSString *listID, NSUInteger offset) {
    NSUInteger limit = MAX((NSUInteger)2, MIN((NSUInteger)100, (NSUInteger)CPListTemplate.maximumItemCount));
    NSUInteger end = MIN(songs.count, offset + (songs.count - MIN(offset, songs.count) > limit ? limit - 1 : limit));
    NSMutableArray *rows = [NSMutableArray array];
    for (NSUInteger index = offset; index < end; index++) {
        NSDictionary *song = [songs[index] isKindOfClass:NSDictionary.class] ? songs[index] : @{};
        NSString *musicID = LXText(song[@"id"], @""), *owner = LXText(song[@"listId"], listID);
        if (!musicID.length || !owner.length) continue;
        [rows addObject:LXRow(LXText(song[@"name"], @"未知歌曲"), LXText(song[@"singer"], @""), ^{
            [LXFullLibrary.shared enqueue:@{@"type": @"play", @"listId": owner, @"musicId": musicID}];
            LXPush(CPNowPlayingTemplate.sharedTemplate);
        })];
    }
    if (end < songs.count) [rows addObject:LXRow(@"更多歌曲", nil, ^{ LXPush([[CPListTemplate alloc] initWithTitle:@"歌曲" sections:@[LXSection(LXSongRows(songs, listID, end))]]); })];
    if (!rows.count) [rows addObject:LXRow(@"暂无歌曲", @"在手机端添加歌曲后刷新", nil)];
    return rows;
}
static NSArray *LXListRows(NSUInteger offset) {
    NSMutableArray *rows = [NSMutableArray array];
    NSArray *lists = LXFullLibrary.shared.snapshot[@"lists"];
    NSUInteger maximum = MAX((NSUInteger)3, MIN((NSUInteger)100, (NSUInteger)CPListTemplate.maximumItemCount));
    NSUInteger end = MIN(lists.count, offset + maximum - 2);
    for (NSUInteger index = offset; index < end; index++) {
        NSDictionary *list = lists[index];
        if (![list isKindOfClass:NSDictionary.class]) continue;
        NSArray *songs = [list[@"musics"] isKindOfClass:NSArray.class] ? list[@"musics"] : @[];
        NSString *title = LXText(list[@"name"], @"歌单"), *listID = LXText(list[@"id"], @"");
        if (!listID.length) continue;
        [rows addObject:LXRow(title, [NSString stringWithFormat:@"%lu 首", (unsigned long)songs.count], ^{
            LXPush([[CPListTemplate alloc] initWithTitle:title sections:@[LXSection(LXSongRows(songs, listID, 0))]]);
        })];
    }
    if (!rows.count) [rows addObject:LXRow(@"音乐库正在准备", @"可先使用播放控制，歌单准备后自动显示", nil)];
    if (end < lists.count && end > offset) [rows addObject:LXRow(@"更多歌单", nil, ^{ LXPush([[CPListTemplate alloc] initWithTitle:@"我的歌单" sections:@[LXSection(LXListRows(end))]]); })];
    [rows addObject:LXRow(@"刷新音乐库", nil, ^{ [LXFullLibrary.shared enqueue:@{@"type": @"refresh-library"}]; })];
    return rows;
}
static void LXRefresh(void) {
    LXCarConnection *c = LXCurrent;
    if (!LXIsCurrent(c) || !c.home) return;
    __weak LXCarConnection *weak = c;
    @try {
        [c.home updateSections:@[LXSection(@[
            LXRow(@"正在播放", @"原生播放控制与封面", ^{ LXPush(CPNowPlayingTemplate.sharedTemplate); }),
            LXRow(@"播放 / 暂停", nil, ^{ LXCommand(@"toggle"); }),
            LXRow(@"下一首", nil, ^{ LXCommand(@"next"); }),
            LXRow(@"上一首", nil, ^{ LXCommand(@"previous"); }),
            LXRow(@"我的歌单", nil, ^{ LXPush(weak.lists); })
        ])]];
        [c.lists updateSections:@[LXSection(LXListRows(0))]];
        NSArray *recent = LXFullLibrary.shared.snapshot[@"recent"];
        [c.recent updateSections:@[LXSection(LXSongRows([recent isKindOfClass:NSArray.class] ? recent : @[], @"default", 0))]];
    } @catch (NSException *error) { LXError = error.reason ?: @"歌单刷新失败"; LXRecord(@"车机音乐库刷新异常", nil); }
}
static void LXInstallRoot(LXCarConnection *c);
static void LXRootTimeout(LXCarConnection *c, NSUInteger attempt) {
    if (!LXIsCurrent(c) || c.attempt != attempt || !c.installing) return;
    c.installing = NO;
    if (c.controller.rootTemplate) { LXRecord(@"车机已有菜单，系统未回传完成通知", nil); return; }
    LXError = @"系统未完成菜单建立";
    LXRecord(@"车机菜单建立超时", nil);
    if (!c.simple) { c.simple = YES; LXInstallRoot(c); }
}
static void LXInstallRoot(LXCarConnection *c) {
    if (!LXIsCurrent(c) || c.installing) return;
    c.installing = YES;
    NSUInteger attempt = ++c.attempt;
    @try {
        c.home = [[CPListTemplate alloc] initWithTitle:@"栖页音乐" sections:@[]];
        c.lists = [[CPListTemplate alloc] initWithTitle:@"我的歌单" sections:@[]];
        c.recent = [[CPListTemplate alloc] initWithTitle:@"最近播放" sections:@[]];
        c.home.tabTitle = @"播放"; c.home.tabImage = [UIImage systemImageNamed:@"play.circle"];
        c.lists.tabTitle = @"歌单"; c.lists.tabImage = [UIImage systemImageNamed:@"music.note.list"];
        c.recent.tabTitle = @"最近"; c.recent.tabImage = [UIImage systemImageNamed:@"clock"];
        LXRefresh(); // Populate before setRootTemplate, without waiting for JS/network.
        NSArray *tabs = @[c.home, c.lists, c.recent];
        NSUInteger count = MIN(tabs.count, (NSUInteger)CPTabBarTemplate.maximumTabCount);
        c.root = !c.simple && count >= 2 ? [[CPTabBarTemplate alloc] initWithTemplates:[tabs subarrayWithRange:NSMakeRange(0, count)]] : c.home;
        LXRecord(c.simple ? @"正在建立兼容菜单" : @"正在建立完整原生菜单", nil);
        __weak LXCarConnection *weak = c;
        [c.controller setRootTemplate:c.root animated:NO completion:^(BOOL ok, NSError *error) {
            LXMain(^{
                LXCarConnection *current = weak;
                if (!LXIsCurrent(current) || current.attempt != attempt || !current.installing) return;
                current.installing = NO;
                if (ok) { LXError = @""; LXRecord(current.simple ? @"兼容菜单已就绪" : @"完整原生菜单已就绪", nil); }
                else {
                    LXError = error.localizedDescription ?: @"系统拒绝车机菜单";
                    LXRecord(@"系统拒绝车机菜单", nil);
                    if (!current.simple) { current.simple = YES; LXInstallRoot(current); }
                }
            });
        }];
        // Only the current attempt may fall back; old completions cannot replace
        // the new controller's menu. No periodic timer runs while disconnected.
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 4 * NSEC_PER_SEC), dispatch_get_main_queue(), ^{ LXRootTimeout(weak, attempt); });
    } @catch (NSException *error) {
        c.installing = NO; LXError = error.reason ?: @"菜单异常"; LXRecord(@"车机菜单建立异常", nil);
        if (!c.simple) { c.simple = YES; LXInstallRoot(c); }
    }
}
static void LXEnsureRoot(LXCarConnection *c) {
    if (!LXIsCurrent(c)) return;
    // A nonempty stack may be showing Now Playing or a nested playlist. Keep it.
    if ((!c.root || !c.controller.rootTemplate) && !c.installing) LXInstallRoot(c);
}
static void LXBuildRoot(id owner, SEL selector) {
    LXMain(^{ LXCarConnection *c = objc_getAssociatedObject(owner, &LXConnectionKey); LXEnsureRoot(c); });
}
static void LXCallReferenceDisconnect(LXCarConnection *c) {
    IMP original = c.audio ? LXReferenceAudioDisconnect : LXReferenceDisconnect;
    if (c.audio && original) ((void (*)(id, SEL, id, id))original)(c.owner, NSSelectorFromString(@"templateApplicationScene:didDisconnectInterfaceController:"), c.scene, c.controller);
    else if (LXReferenceDisconnect) ((void (*)(id, SEL, id, id, id))LXReferenceDisconnect)(c.owner, NSSelectorFromString(@"templateApplicationScene:didDisconnectInterfaceController:fromWindow:"), c.scene, c.controller, c.window);
}
static void LXRelease(LXCarConnection *c) {
    if (!LXIsCurrent(c)) return;
    @try { LXCallReferenceDisconnect(c); } @catch (NSException *error) { LXError = error.reason ?: @"参考断开异常"; }
    c.installing = NO; c.attempt++;
    if (c.scene) objc_setAssociatedObject(c.scene, &LXRetiredSceneKey, @YES, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    objc_setAssociatedObject(c.owner, &LXConnectionKey, nil, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    LXRecord(@"车机连接已释放", nil);
    LXCurrent = nil;
    LXRecord(@"车机已断开", nil);
}
static void LXConnect(id owner, id scene, CPInterfaceController *controller, CPWindow *window, BOOL audio, NSString *callback) {
    if (!owner || !controller) { LXError = @"连接未提供控制器"; LXRecord(@"车机连接参数不完整", callback); return; }
    LXCarConnection *c = LXCurrent;
    if (LXIsCurrent(c) && c.owner == owner && c.scene == scene && c.controller == controller) {
        LXRecord(@"重复连接回调，保留当前页面", callback); LXEnsureRoot(c); return;
    }
    // Release the reference's retained state BEFORE attaching a new controller.
    // A delayed disconnect for the old controller is ignored below, including
    // its original implementation, which otherwise clears the new reference.
    if (c) LXRelease(c);
    c = [LXCarConnection new]; c.owner = owner; c.scene = scene; c.controller = controller; c.window = window;
    c.audio = audio; c.generation = ++LXGeneration; c.identifier = NSUUID.UUID.UUIDString;
    LXCurrent = c; LXError = @"";
    if (scene) objc_setAssociatedObject(scene, &LXRetiredSceneKey, nil, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    objc_setAssociatedObject(owner, &LXConnectionKey, c, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    LXRecord(@"车机连接回调已触发", callback);
    @try {
        if (audio && LXReferenceAudioConnect) ((void (*)(id, SEL, id, id))LXReferenceAudioConnect)(owner, NSSelectorFromString(@"templateApplicationScene:didConnectInterfaceController:"), scene, controller);
        else if (LXReferenceConnect) ((void (*)(id, SEL, id, id, id))LXReferenceConnect)(owner, NSSelectorFromString(@"templateApplicationScene:didConnectInterfaceController:toWindow:"), scene, controller, window);
    } @catch (NSException *error) { LXError = error.reason ?: @"参考连接异常"; LXRecord(@"参考连接出现异常，直接恢复菜单", nil); }
    LXEnsureRoot(c); // Root is submitted synchronously before didConnect returns.
}
static void LXConnected(id owner, SEL selector, id scene, id controller, id window) {
    LXMain(^{ LXConnect(owner, scene, controller, window, NO, @"window"); });
}
static void LXAudioConnected(id owner, SEL selector, id scene, id controller) {
    LXMain(^{ LXConnect(owner, scene, controller, nil, YES, @"audio"); });
}
static void LXDisconnect(id owner, id scene, id controller, NSString *callback) {
    LXCarConnection *c = LXCurrent;
    if (!LXIsCurrent(c) || c.owner != owner || c.scene != scene || c.controller != controller) {
        LXRecord(@"忽略旧连接的断开回调", callback); return;
    }
    LXCallback = callback; LXRelease(c);
}
static void LXDisconnected(id owner, SEL selector, id scene, id controller, id window) {
    LXMain(^{ LXDisconnect(owner, scene, controller, @"disconnect-window"); });
}
static void LXAudioDisconnected(id owner, SEL selector, id scene, id controller) {
    LXMain(^{ LXDisconnect(owner, scene, controller, @"disconnect-audio"); });
}
static void LXRecoverScene(id owner, CPTemplateApplicationScene *scene, NSString *event) {
    if (![scene isKindOfClass:CPTemplateApplicationScene.class]) return;
    if ([objc_getAssociatedObject(scene, &LXRetiredSceneKey) boolValue]) { LXRecord(@"忽略已断开场景的恢复事件", event); return; }
    CPInterfaceController *controller = scene.interfaceController;
    if (!controller) { LXRecord(@"车机场景尚无控制器", event); return; }
    if (LXIsCurrent(LXCurrent) && (LXCurrent.owner != owner || LXCurrent.scene != scene || LXCurrent.controller != controller)) {
        LXRecord(@"忽略其他连接的恢复事件", event); return;
    }
    if (!LXIsCurrent(LXCurrent))
        LXConnect(owner, scene, controller, nil, YES, event);
    else { LXRecord(@"车机场景重新进入前台", event); LXEnsureRoot(LXCurrent); }
}
static void LXSceneActive(id owner, SEL selector, CPTemplateApplicationScene *scene) {
    LXMain(^{
        if (LXReferenceActive) ((void (*)(id, SEL, id))LXReferenceActive)(owner, selector, scene);
        LXRecoverScene(owner, scene, @"scene-active");
    });
}
static void LXSceneForeground(id owner, SEL selector, CPTemplateApplicationScene *scene) {
    LXMain(^{
        if (LXReferenceForeground) ((void (*)(id, SEL, id))LXReferenceForeground)(owner, selector, scene);
        LXRecoverScene(owner, scene, @"scene-foreground");
    });
}
static void LXSceneDisconnected(id owner, SEL selector, id scene) {
    LXMain(^{
        BOOL matched = LXIsCurrent(LXCurrent) && LXCurrent.owner == owner && LXCurrent.scene == scene;
        if (matched) LXRelease(LXCurrent);
        else LXRecord(@"忽略旧场景的断开事件", @"scene-disconnect");
        if (LXReferenceSceneDisconnect && matched)
            ((void (*)(id, SEL, id))LXReferenceSceneDisconnect)(owner, selector, scene);
    });
}

#ifndef LX_CARPLAY_TESTING
@interface LXFullCarPlayModule : RCTEventEmitter <RCTBridgeModule>
@property(atomic, assign) BOOL listening;
@end
@implementation LXFullCarPlayModule
RCT_EXPORT_MODULE(CarPlayModule);
+ (BOOL)requiresMainQueueSetup { return NO; }
- (instancetype)init {
    if ((self = [super init])) [NSNotificationCenter.defaultCenter addObserver:self selector:@selector(queued:) name:LXFullActionQueued object:nil];
    return self;
}
- (void)dealloc { [NSNotificationCenter.defaultCenter removeObserver:self]; }
- (NSArray<NSString *> *)supportedEvents { return @[@"carplay-action"]; }
- (void)startObserving { self.listening = YES; [self flush]; }
- (void)stopObserving { self.listening = NO; }
- (void)queued:(NSNotification *)note { [self flush]; }
- (void)flush { if (self.listening) for (NSDictionary *action in [LXFullLibrary.shared drain]) [self sendEventWithName:@"carplay-action" body:action]; }
RCT_EXPORT_METHOD(updateLibrary:(NSDictionary *)snapshot resolver:(RCTPromiseResolveBlock)resolve rejecter:(RCTPromiseRejectBlock)reject) {
    NSError *error; if ([LXFullLibrary.shared update:snapshot error:&error]) { LXRecord(nil, nil); resolve(nil); } else reject(@"library_cache", error.localizedDescription, error);
}
@end
#endif

// class_replaceMethod also wraps an existing audio callback. class_addMethod
// alone silently fails on a reference that already implements that selector.
static IMP LXHook(Class cls, NSString *name, IMP replacement, const char *types) {
    SEL selector = NSSelectorFromString(name);
    Method method = class_getInstanceMethod(cls, selector);
    IMP original = method ? method_getImplementation(method) : NULL;
    class_replaceMethod(cls, selector, replacement, method ? method_getTypeEncoding(method) : types);
    return original;
}
#ifndef LX_CARPLAY_TESTING
__attribute__((constructor))
#endif
static void LXInstallFullCarPlay(void) {
    @autoreleasepool {
        Class reference = NSClassFromString(@"CPSceneDelegate");
        if (!reference) { dispatch_async(dispatch_get_main_queue(), ^{ LXRecord(@"缺少参考 CarPlaySupport 接入", @"install"); }); return; }
        LXReferenceRoot = LXHook(reference, @"setupRootTemplate", (IMP)LXBuildRoot, "v@:");
        LXReferenceConnect = LXHook(reference, @"templateApplicationScene:didConnectInterfaceController:toWindow:", (IMP)LXConnected, "v@:@@@");
        LXReferenceDisconnect = LXHook(reference, @"templateApplicationScene:didDisconnectInterfaceController:fromWindow:", (IMP)LXDisconnected, "v@:@@@");
        LXReferenceAudioConnect = LXHook(reference, @"templateApplicationScene:didConnectInterfaceController:", (IMP)LXAudioConnected, "v@:@@");
        LXReferenceAudioDisconnect = LXHook(reference, @"templateApplicationScene:didDisconnectInterfaceController:", (IMP)LXAudioDisconnected, "v@:@@");
        LXReferenceActive = LXHook(reference, @"sceneDidBecomeActive:", (IMP)LXSceneActive, "v@:@");
        LXReferenceForeground = LXHook(reference, @"sceneWillEnterForeground:", (IMP)LXSceneForeground, "v@:@");
        LXReferenceSceneDisconnect = LXHook(reference, @"sceneDidDisconnect:", (IMP)LXSceneDisconnected, "v@:@");
        LXHooks = @{@"window": @(class_getMethodImplementation(reference, NSSelectorFromString(@"templateApplicationScene:didConnectInterfaceController:toWindow:")) == (IMP)LXConnected),
            @"audio": @(class_getMethodImplementation(reference, NSSelectorFromString(@"templateApplicationScene:didConnectInterfaceController:")) == (IMP)LXAudioConnected),
            @"root": @(class_getMethodImplementation(reference, NSSelectorFromString(@"setupRootTemplate")) == (IMP)LXBuildRoot),
            @"existingAudio": @(LXReferenceAudioConnect != NULL), @"sceneRecovery": @YES};
        [NSNotificationCenter.defaultCenter addObserverForName:LXFullLibraryChanged object:nil queue:NSOperationQueue.mainQueue usingBlock:^(NSNotification *note) { LXRefresh(); }];
        // Recover a scene even when a reference implementation doesn't forward
        // activation callbacks. This is event-driven and does not poll the car.
        for (NSString *name in @[UISceneDidActivateNotification, UISceneWillEnterForegroundNotification])
            [NSNotificationCenter.defaultCenter addObserverForName:name object:nil queue:NSOperationQueue.mainQueue usingBlock:^(NSNotification *note) {
                CPTemplateApplicationScene *scene = note.object;
                if ([scene isKindOfClass:CPTemplateApplicationScene.class] && [scene.delegate isKindOfClass:reference]) LXRecoverScene(scene.delegate, scene, name);
            }];
        dispatch_async(dispatch_get_main_queue(), ^{
            LXRecord(@"完整参考接入已加载", @"install");
            for (UIScene *scene in UIApplication.sharedApplication.connectedScenes)
                if ([scene isKindOfClass:CPTemplateApplicationScene.class] && [scene.delegate isKindOfClass:reference]) LXRecoverScene(scene.delegate, (id)scene, @"existing-scene");
        });
    }
}
