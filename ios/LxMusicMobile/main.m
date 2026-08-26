#import <UIKit/UIKit.h>
#import <MediaPlayer/MediaPlayer.h>
#import <React/RCTBridgeModule.h>
#import <React/RCTEventEmitter.h>
@import CarPlay;

#import "AppDelegate.h"

static NSString * const LXCarPlaySnapshotDefaultsKey = @"LXCarPlayLibrarySnapshotV1";
static NSMutableArray<NSDictionary *> *LXCarPlayPendingActions;

@class LXCarPlayModule;
@class LXCarPlaySceneDelegate;

static LXCarPlayModule *LXCarPlayModuleInstance;
static LXCarPlaySceneDelegate *LXCarPlaySceneDelegateInstance;

static void LXCarPlayEmitAction(NSDictionary *action);

@interface LXCarPlaySceneDelegate : UIResponder <CPTemplateApplicationSceneDelegate>
@property (nonatomic, strong) CPInterfaceController *interfaceController;
- (void)refreshRootTemplate;
@end

@implementation LXCarPlaySceneDelegate

- (NSDictionary *)librarySnapshot {
  NSDictionary *snapshot = [[NSUserDefaults standardUserDefaults] objectForKey:LXCarPlaySnapshotDefaultsKey];
  return [snapshot isKindOfClass:[NSDictionary class]] ? snapshot : @{};
}

- (NSString *)nowPlayingDetail {
  NSDictionary *info = [MPNowPlayingInfoCenter defaultCenter].nowPlayingInfo;
  NSString *title = [info[MPMediaItemPropertyTitle] isKindOfClass:[NSString class]] ? info[MPMediaItemPropertyTitle] : @"";
  NSString *artist = [info[MPMediaItemPropertyArtist] isKindOfClass:[NSString class]] ? info[MPMediaItemPropertyArtist] : @"";
  if (title.length == 0) return @"暂无正在播放";
  return artist.length ? [NSString stringWithFormat:@"%@ · %@", title, artist] : title;
}

- (void)showNowPlaying {
  if (self.interfaceController == nil) return;
  [self.interfaceController pushTemplate:[CPNowPlayingTemplate sharedTemplate] animated:YES completion:NULL];
}

- (CPListTemplate *)playlistTemplateForList:(NSDictionary *)list offset:(NSUInteger)offset {
  NSString *listName = [list[@"name"] isKindOfClass:[NSString class]] ? list[@"name"] : @"歌单";
  NSString *listId = [list[@"id"] isKindOfClass:[NSString class]] ? list[@"id"] : @"";
  NSArray *songs = [list[@"songs"] isKindOfClass:[NSArray class]] ? list[@"songs"] : @[];

  static const NSUInteger pageSize = 50;
  NSUInteger end = MIN(offset + pageSize, songs.count);
  NSMutableArray<CPListItem *> *items = [NSMutableArray array];

  if (offset < end) {
    for (NSUInteger index = offset; index < end; index++) {
      NSDictionary *song = [songs[index] isKindOfClass:[NSDictionary class]] ? songs[index] : @{};
      NSString *songId = [song[@"id"] isKindOfClass:[NSString class]] ? song[@"id"] : @"";
      NSString *name = [song[@"name"] isKindOfClass:[NSString class]] ? song[@"name"] : @"未知歌曲";
      NSString *singer = [song[@"singer"] isKindOfClass:[NSString class]] ? song[@"singer"] : @"";
      NSString *album = [song[@"album"] isKindOfClass:[NSString class]] ? song[@"album"] : @"";
      NSString *detail = singer.length && album.length ? [NSString stringWithFormat:@"%@ · %@", singer, album] : (singer.length ? singer : album);

      CPListItem *item = [[CPListItem alloc] initWithText:name detailText:detail.length ? detail : nil];
      __weak typeof(self) weakSelf = self;
      item.handler = ^(id<CPSelectableListItem> selectedItem, dispatch_block_t completionBlock) {
        if (songId.length && listId.length) {
          LXCarPlayEmitAction(@{
            @"type": @"play",
            @"listId": listId,
            @"id": songId,
          });
        }
        if (completionBlock) completionBlock();
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.15 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
          [weakSelf showNowPlaying];
        });
      };
      [items addObject:item];
    }
  }

  if (items.count == 0) {
    CPListItem *empty = [[CPListItem alloc] initWithText:@"列表为空" detailText:@"请先在手机端添加歌曲"];
    empty.enabled = NO;
    [items addObject:empty];
  }

  if (end < songs.count) {
    NSUInteger nextOffset = end;
    CPListItem *next = [[CPListItem alloc] initWithText:@"下一页" detailText:[NSString stringWithFormat:@"%lu - %lu / %lu", (unsigned long)(nextOffset + 1), (unsigned long)MIN(nextOffset + pageSize, songs.count), (unsigned long)songs.count]];
    __weak typeof(self) weakSelf = self;
    next.handler = ^(id<CPSelectableListItem> selectedItem, dispatch_block_t completionBlock) {
      CPListTemplate *template = [weakSelf playlistTemplateForList:list offset:nextOffset];
      if (weakSelf.interfaceController && template) {
        [weakSelf.interfaceController pushTemplate:template animated:YES completion:NULL];
      }
      if (completionBlock) completionBlock();
    };
    [items addObject:next];
  }

  CPListSection *section = [[CPListSection alloc] initWithItems:items];
  return [[CPListTemplate alloc] initWithTitle:listName sections:@[ section ]];
}

- (CPListTemplate *)makeRootTemplate {
  NSDictionary *snapshot = [self librarySnapshot];
  NSArray *lists = [snapshot[@"lists"] isKindOfClass:[NSArray class]] ? snapshot[@"lists"] : @[];

  CPListItem *nowPlaying = [[CPListItem alloc] initWithText:@"正在播放" detailText:[self nowPlayingDetail]];
  __weak typeof(self) weakSelf = self;
  nowPlaying.handler = ^(id<CPSelectableListItem> selectedItem, dispatch_block_t completionBlock) {
    [weakSelf showNowPlaying];
    if (completionBlock) completionBlock();
  };

  CPListItem *refresh = [[CPListItem alloc] initWithText:@"刷新音乐库" detailText:@"同步手机中的收藏与歌单"];
  refresh.handler = ^(id<CPSelectableListItem> selectedItem, dispatch_block_t completionBlock) {
    LXCarPlayEmitAction(@{ @"type": @"refresh" });
    if (completionBlock) completionBlock();
  };

  CPListSection *controlSection = [[CPListSection alloc] initWithItems:@[ nowPlaying, refresh ]];
  NSMutableArray<CPListItem *> *playlistItems = [NSMutableArray array];

  for (id value in lists) {
    if (![value isKindOfClass:[NSDictionary class]]) continue;
    NSDictionary *list = value;
    NSString *name = [list[@"name"] isKindOfClass:[NSString class]] ? list[@"name"] : @"歌单";
    NSArray *songs = [list[@"songs"] isKindOfClass:[NSArray class]] ? list[@"songs"] : @[];
    NSString *detail = [NSString stringWithFormat:@"%lu 首", (unsigned long)songs.count];
    CPListItem *item = [[CPListItem alloc] initWithText:name detailText:detail];
    item.handler = ^(id<CPSelectableListItem> selectedItem, dispatch_block_t completionBlock) {
      CPListTemplate *template = [weakSelf playlistTemplateForList:list offset:0];
      if (weakSelf.interfaceController && template) {
        [weakSelf.interfaceController pushTemplate:template animated:YES completion:NULL];
      }
      if (completionBlock) completionBlock();
    };
    [playlistItems addObject:item];
  }

  if (playlistItems.count == 0) {
    CPListItem *syncing = [[CPListItem alloc] initWithText:@"音乐库正在同步" detailText:@"手机端启动后会自动显示收藏和歌单"];
    syncing.enabled = NO;
    [playlistItems addObject:syncing];
  }

  CPListSection *playlistSection = [[CPListSection alloc] initWithItems:playlistItems];
  return [[CPListTemplate alloc] initWithTitle:@"LX Music" sections:@[ controlSection, playlistSection ]];
}

- (void)refreshRootTemplate {
  if (self.interfaceController == nil) return;
  CPListTemplate *root = [self makeRootTemplate];
  [self.interfaceController setRootTemplate:root animated:NO completion:NULL];
}

- (void)templateApplicationScene:(CPTemplateApplicationScene *)templateApplicationScene
   didConnectInterfaceController:(CPInterfaceController *)interfaceController {
  self.interfaceController = interfaceController;
  LXCarPlaySceneDelegateInstance = self;
  // CarPlay requires a root template before this callback returns. This makes
  // cold launches deterministic even when React Native or the network is slow.
  [self refreshRootTemplate];
}

- (void)templateApplicationScene:(CPTemplateApplicationScene *)templateApplicationScene
 didDisconnectInterfaceController:(CPInterfaceController *)interfaceController {
  if (LXCarPlaySceneDelegateInstance == self) LXCarPlaySceneDelegateInstance = nil;
  self.interfaceController = nil;
}

@end

@interface LXCarPlayModule : RCTEventEmitter <RCTBridgeModule>
@property (nonatomic, assign) BOOL hasJSListeners;
@end

@implementation LXCarPlayModule

RCT_EXPORT_MODULE(CarPlayModule);

+ (BOOL)requiresMainQueueSetup {
  return YES;
}

- (instancetype)init {
  self = [super init];
  if (self) {
    LXCarPlayModuleInstance = self;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
      LXCarPlayPendingActions = [NSMutableArray array];
    });
  }
  return self;
}

- (NSArray<NSString *> *)supportedEvents {
  return @[ @"carplay-action" ];
}

- (void)startObserving {
  self.hasJSListeners = YES;
}

- (void)stopObserving {
  self.hasJSListeners = NO;
}

RCT_REMAP_METHOD(setLibrarySnapshot,
                 setLibrarySnapshot:(NSDictionary *)snapshot
                 resolver:(RCTPromiseResolveBlock)resolve
                 rejecter:(RCTPromiseRejectBlock)reject) {
  if (![snapshot isKindOfClass:[NSDictionary class]]) {
    reject(@"invalid_snapshot", @"CarPlay snapshot must be a dictionary", nil);
    return;
  }

  [[NSUserDefaults standardUserDefaults] setObject:snapshot forKey:LXCarPlaySnapshotDefaultsKey];
  [[NSUserDefaults standardUserDefaults] synchronize];
  dispatch_async(dispatch_get_main_queue(), ^{
    [LXCarPlaySceneDelegateInstance refreshRootTemplate];
  });
  resolve(@YES);
}

RCT_REMAP_METHOD(drainPendingActions,
                 drainPendingActionsWithResolver:(RCTPromiseResolveBlock)resolve
                 rejecter:(RCTPromiseRejectBlock)reject) {
  @synchronized (LXCarPlayPendingActions) {
    NSArray *actions = [LXCarPlayPendingActions copy] ?: @[];
    [LXCarPlayPendingActions removeAllObjects];
    resolve(actions);
  }
}

RCT_REMAP_METHOD(isConnected,
                 isConnectedWithResolver:(RCTPromiseResolveBlock)resolve
                 rejecter:(RCTPromiseRejectBlock)reject) {
  resolve(@(LXCarPlaySceneDelegateInstance.interfaceController != nil));
}

@end

static void LXCarPlayEmitAction(NSDictionary *action) {
  if (![action isKindOfClass:[NSDictionary class]]) return;
  dispatch_async(dispatch_get_main_queue(), ^{
    LXCarPlayModule *module = LXCarPlayModuleInstance;
    if (module != nil && module.hasJSListeners) {
      [module sendEventWithName:@"carplay-action" body:action];
      return;
    }
    @synchronized (LXCarPlayPendingActions) {
      if (LXCarPlayPendingActions == nil) LXCarPlayPendingActions = [NSMutableArray array];
      [LXCarPlayPendingActions addObject:action];
    }
  });
}

int main(int argc, char *argv[])
{
  @autoreleasepool {
    return UIApplicationMain(argc, argv, nil, NSStringFromClass([AppDelegate class]));
  }
}
