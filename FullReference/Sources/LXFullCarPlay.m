#import <UIKit/UIKit.h>
#import <CarPlay/CarPlay.h>
#import <MediaPlayer/MediaPlayer.h>
#import <objc/runtime.h>
#import <React/RCTEventEmitter.h>
#import <React/RCTBridgeModule.h>
#import "LXFullLibrary.h"

// This extension runs INSIDE the supplied complete reference app. Its existing
// CarPlaySupport.dylib owns UIApplication/phone/CarPlay connection hooks. Do not
// replace that owner or create a second audio player.
static IMP LXReferenceRoot;
static __weak id LXConnectedDelegate;
static CPListTemplate *LXHome, *LXLists, *LXRecent;
static CPTabBarTemplate *LXTabs;
static NSString *LXPhase = @"未连接";
static NSString *LXError = @"";

static NSString *LXText(id value, NSString *fallback) { return [value isKindOfClass:NSString.class] && [value length] ? value : fallback; }
static void LXPush(CPTemplate *page) {
    CPInterfaceController *controller = [LXConnectedDelegate valueForKey:@"interfaceController"];
    if (!controller || controller.topTemplate == page) return;
    [controller pushTemplate:page animated:YES completion:^(BOOL ok, NSError *error) { if (!ok) LXError = error.localizedDescription ?: @"无法打开车机页面"; }];
}
static CPListItem *LXRow(NSString *title, NSString *detail, dispatch_block_t action) {
    CPListItem *item = [[CPListItem alloc] initWithText:title detailText:detail];
    if (action) item.handler = ^(id<CPSelectableListItem> row, dispatch_block_t completion) { action(); completion(); };
    return item;
}
static CPListSection *LXSection(NSArray *rows) { return [[CPListSection alloc] initWithItems:rows]; }
static void LXCommand(NSString *command) {
    // The reference's own UtilsModule delivers this event to its existing JS
    // player service. Do not use systemMusicPlayer (the user's Apple Music queue).
    [NSNotificationCenter.defaultCenter postNotificationName:@"LXRemoteCommand" object:nil userInfo:@{@"command": command}];
}
static NSArray *LXSongRows(NSArray *songs, NSString *listID, NSUInteger offset) {
    NSUInteger limit = MIN((NSUInteger)100, (NSUInteger)CPListTemplate.maximumItemCount);
    if (limit < 2) limit = 2;
    NSUInteger end = MIN(songs.count, offset + (songs.count - MIN(offset, songs.count) > limit ? limit - 1 : limit));
    NSMutableArray *rows = [NSMutableArray array];
    for (NSUInteger index = offset; index < end; index++) {
        NSDictionary *song = [songs[index] isKindOfClass:NSDictionary.class] ? songs[index] : @{};
        NSString *musicID = LXText(song[@"id"], @"");
        NSString *owner = LXText(song[@"listId"], listID);
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
static NSArray *LXListRows(void) {
    NSMutableArray *rows = [NSMutableArray array];
    NSArray *lists = LXFullLibrary.shared.snapshot[@"lists"];
    NSUInteger maximum = MAX((NSUInteger)2, MIN((NSUInteger)100, (NSUInteger)CPListTemplate.maximumItemCount));
    for (NSDictionary *list in lists) {
        if (![list isKindOfClass:NSDictionary.class] || rows.count >= maximum - 1) continue;
        NSArray *songs = [list[@"musics"] isKindOfClass:NSArray.class] ? list[@"musics"] : @[];
        NSString *title = LXText(list[@"name"], @"歌单"), *listID = LXText(list[@"id"], @"");
        if (!listID.length) continue;
        [rows addObject:LXRow(title, [NSString stringWithFormat:@"%lu 首", (unsigned long)songs.count], ^{
            LXPush([[CPListTemplate alloc] initWithTitle:title sections:@[LXSection(LXSongRows(songs, listID, 0))]]);
        })];
    }
    if (!rows.count) [rows addObject:LXRow(@"音乐库正在准备", @"请先在手机打开一次原生客户端", nil)];
    [rows addObject:LXRow(@"刷新音乐库", nil, ^{ [LXFullLibrary.shared enqueue:@{@"type": @"refresh-library"}]; })];
    return rows;
}
static void LXRefresh(void) {
    if (!LXConnectedDelegate) return;
    [LXHome updateSections:@[LXSection(@[
        LXRow(@"正在播放", @"原生播放控制与封面", ^{ LXPush(CPNowPlayingTemplate.sharedTemplate); }),
        LXRow(@"播放 / 暂停", nil, ^{ LXCommand(@"toggle"); }),
        LXRow(@"下一首", nil, ^{ LXCommand(@"next"); }),
        LXRow(@"上一首", nil, ^{ LXCommand(@"previous"); }),
        LXRow(@"我的歌单", @"使用手机原有音乐库", ^{ LXPush(LXLists); })
    ])]];
    [LXLists updateSections:@[LXSection(LXListRows())]];
    NSArray *recent = LXFullLibrary.shared.snapshot[@"recent"];
    [LXRecent updateSections:@[LXSection(LXSongRows([recent isKindOfClass:NSArray.class] ? recent : @[], @"default", 0))]];
}
static void LXUseReferenceRoot(id delegate) {
    if (LXReferenceRoot) ((void (*)(id, SEL))LXReferenceRoot)(delegate, NSSelectorFromString(@"setupRootTemplate"));
}
static void LXBuildRoot(id delegate, SEL selector) {
    LXConnectedDelegate = delegate;
    CPInterfaceController *controller = [delegate valueForKey:@"interfaceController"];
    if (!controller) { LXPhase = @"参考连接尚未提供控制器"; return; }
    @try {
        LXHome = [[CPListTemplate alloc] initWithTitle:@"LX 音乐" sections:@[]];
        LXLists = [[CPListTemplate alloc] initWithTitle:@"我的歌单" sections:@[]];
        LXRecent = [[CPListTemplate alloc] initWithTitle:@"最近播放" sections:@[]];
        LXHome.tabTitle = @"播放"; LXHome.tabImage = [UIImage systemImageNamed:@"play.circle"];
        LXLists.tabTitle = @"歌单"; LXLists.tabImage = [UIImage systemImageNamed:@"music.note.list"];
        LXRecent.tabTitle = @"最近"; LXRecent.tabImage = [UIImage systemImageNamed:@"clock"];
        LXRefresh();
        NSArray *tabs = @[LXHome, LXLists, LXRecent];
        NSUInteger count = MIN(tabs.count, (NSUInteger)CPTabBarTemplate.maximumTabCount);
        CPTemplate *root = LXHome;
        if (count >= 2) { LXTabs = [[CPTabBarTemplate alloc] initWithTemplates:[tabs subarrayWithRange:NSMakeRange(0, count)]]; root = LXTabs; }
        LXPhase = @"正在建立完整原生菜单";
        __weak id owner = delegate;
        [controller setRootTemplate:root animated:NO completion:^(BOOL ok, NSError *error) {
            if (LXConnectedDelegate != owner) return;
            LXPhase = ok ? @"完整原生菜单已就绪" : @"回退参考原生菜单";
            if (!ok) { LXError = error.localizedDescription ?: @"系统拒绝扩展菜单"; LXUseReferenceRoot(owner); }
        }];
    } @catch (NSException *error) { LXPhase = @"回退参考原生菜单"; LXError = error.reason ?: @"菜单异常"; LXUseReferenceRoot(delegate); }
}

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
    NSError *error; if ([LXFullLibrary.shared update:snapshot error:&error]) resolve(nil); else reject(@"library_cache", error.localizedDescription, error);
}
@end

__attribute__((constructor)) static void LXInstallFullCarPlay(void) {
    dispatch_async(dispatch_get_main_queue(), ^{
        Class reference = NSClassFromString(@"CPSceneDelegate");
        Method method = class_getInstanceMethod(reference, NSSelectorFromString(@"setupRootTemplate"));
        if (!method) { LXPhase = @"缺少参考 CarPlaySupport 接入"; return; }
        LXReferenceRoot = method_setImplementation(method, (IMP)LXBuildRoot);
        [NSNotificationCenter.defaultCenter addObserverForName:LXFullLibraryChanged object:nil queue:NSOperationQueue.mainQueue usingBlock:^(NSNotification *note) { LXRefresh(); }];
        LXPhase = @"完整参考接入已加载";
        NSLog(@"[LXFullCarPlay] reference CPSceneDelegate retained; original player and phone lifecycle unchanged");
    });
}
