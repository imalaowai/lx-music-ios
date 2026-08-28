#import <UIKit/UIKit.h>
#import <MediaPlayer/MediaPlayer.h>
#import <React/RCTBridgeModule.h>
#import <React/RCTEventEmitter.h>
@import CarPlay;

#import "AppDelegate.h"

static NSString * const LXCarPlayLibraryDidChangeNotification = @"LXCarPlayLibraryDidChange";
static NSString * const LXCarPlayActionQueuedNotification = @"LXCarPlayActionQueued";
static NSString * const LXTrackPlayerLifecycleNotification = @"LXTrackPlayerLifecycle";

static NSString *LXCPString(id value, NSString *fallback) {
  return [value isKindOfClass:[NSString class]] && [value length] > 0 ? value : fallback;
}

static NSString *LXCPMusicDetail(NSDictionary *music) {
  NSString *singer = LXCPString(music[@"singer"], @"");
  NSString *album = LXCPString(music[@"album"], @"");
  if (singer.length && album.length) return [NSString stringWithFormat:@"%@ · %@", singer, album];
  if (singer.length) return singer;
  return album;
}

@interface LXCarPlayStore : NSObject
@property (nonatomic, strong) NSDictionary *snapshot;
@property (nonatomic, strong) NSMutableArray<NSDictionary *> *pendingActions;
@property (nonatomic, strong) dispatch_queue_t ioQueue;
+ (instancetype)sharedStore;
- (NSDictionary *)snapshotCopy;
- (void)updateSnapshot:(NSDictionary *)snapshot;
- (void)enqueueAction:(NSDictionary *)action;
- (NSArray<NSDictionary *> *)drainPendingActions;
@end

@implementation LXCarPlayStore

+ (instancetype)sharedStore {
  static LXCarPlayStore *store;
  static dispatch_once_t onceToken;
  dispatch_once(&onceToken, ^{
    store = [[LXCarPlayStore alloc] init];
  });
  return store;
}

- (instancetype)init {
  self = [super init];
  if (self) {
    _pendingActions = [NSMutableArray array];
    _ioQueue = dispatch_queue_create("cn.toside.music.carplay.cache", DISPATCH_QUEUE_SERIAL);
    _snapshot = [self loadSnapshotFromDisk] ?: @{
      @"version": @2,
      @"updatedAt": @0,
      @"lists": @[],
      @"recent": @[],
    };
  }
  return self;
}

- (NSURL *)snapshotURL {
  NSURL *baseURL = [[[NSFileManager defaultManager] URLsForDirectory:NSApplicationSupportDirectory
                                                           inDomains:NSUserDomainMask] firstObject];
  NSURL *directoryURL = [baseURL URLByAppendingPathComponent:@"LXMusic/CarPlay" isDirectory:YES];
  return [directoryURL URLByAppendingPathComponent:@"library-v2.json"];
}

- (NSDictionary *)loadSnapshotFromDisk {
  NSURL *url = [self snapshotURL];
  NSData *data = [NSData dataWithContentsOfURL:url options:0 error:nil];
  if (data.length == 0) return nil;
  id object = [NSJSONSerialization JSONObjectWithData:data options:0 error:nil];
  return [object isKindOfClass:[NSDictionary class]] ? object : nil;
}

- (NSDictionary *)snapshotCopy {
  @synchronized (self) {
    return [self.snapshot copy];
  }
}

- (void)updateSnapshot:(NSDictionary *)snapshot {
  if (![snapshot isKindOfClass:[NSDictionary class]] || ![NSJSONSerialization isValidJSONObject:snapshot]) return;
  NSDictionary *copy = [snapshot copy];
  @synchronized (self) {
    self.snapshot = copy;
  }

  dispatch_async(self.ioQueue, ^{
    NSURL *url = [self snapshotURL];
    NSURL *directoryURL = [url URLByDeletingLastPathComponent];
    [[NSFileManager defaultManager] createDirectoryAtURL:directoryURL
                              withIntermediateDirectories:YES
                                               attributes:nil
                                                    error:nil];
    NSData *data = [NSJSONSerialization dataWithJSONObject:copy options:0 error:nil];
    if (data.length) [data writeToURL:url options:NSDataWritingAtomic error:nil];
  });

  dispatch_async(dispatch_get_main_queue(), ^{
    [[NSNotificationCenter defaultCenter] postNotificationName:LXCarPlayLibraryDidChangeNotification object:nil];
  });
}

- (void)enqueueAction:(NSDictionary *)action {
  if (![action isKindOfClass:[NSDictionary class]]) return;
  NSString *type = LXCPString(action[@"type"], @"");
  if (type.length == 0) return;

  @synchronized (self) {
    if ([type isEqualToString:@"refresh-library"]) {
      for (NSDictionary *queued in self.pendingActions) {
        if ([queued[@"type"] isEqualToString:@"refresh-library"]) {
          dispatch_async(dispatch_get_main_queue(), ^{
            [[NSNotificationCenter defaultCenter] postNotificationName:LXCarPlayActionQueuedNotification object:nil];
          });
          return;
        }
      }
    }
    [self.pendingActions addObject:[action copy]];
    while (self.pendingActions.count > 32) [self.pendingActions removeObjectAtIndex:0];
  }

  dispatch_async(dispatch_get_main_queue(), ^{
    [[NSNotificationCenter defaultCenter] postNotificationName:LXCarPlayActionQueuedNotification object:nil];
  });
}

- (NSArray<NSDictionary *> *)drainPendingActions {
  @synchronized (self) {
    NSArray *actions = [self.pendingActions copy];
    [self.pendingActions removeAllObjects];
    return actions;
  }
}

@end

@interface CarPlayModule : RCTEventEmitter <RCTBridgeModule>
@property (nonatomic, assign) BOOL hasJSListeners;
@end

@implementation CarPlayModule

RCT_EXPORT_MODULE(CarPlayModule);

+ (BOOL)requiresMainQueueSetup {
  return YES;
}

- (instancetype)init {
  self = [super init];
  if (self) {
    [[NSNotificationCenter defaultCenter] addObserver:self
                                             selector:@selector(handleQueuedActions:)
                                                 name:LXCarPlayActionQueuedNotification
                                               object:nil];
  }
  return self;
}

- (void)dealloc {
  [[NSNotificationCenter defaultCenter] removeObserver:self];
}

- (NSArray<NSString *> *)supportedEvents {
  return @[ @"carplay-action" ];
}

- (void)startObserving {
  self.hasJSListeners = YES;
  [self flushQueuedActions];
}

- (void)stopObserving {
  self.hasJSListeners = NO;
}

- (void)handleQueuedActions:(NSNotification *)notification {
  [self flushQueuedActions];
}

- (void)flushQueuedActions {
  if (!self.hasJSListeners) return;
  NSArray<NSDictionary *> *actions = [[LXCarPlayStore sharedStore] drainPendingActions];
  for (NSDictionary *action in actions) {
    [self sendEventWithName:@"carplay-action" body:action];
  }
}

RCT_EXPORT_METHOD(updateLibrary:(NSDictionary *)snapshot
                  resolver:(RCTPromiseResolveBlock)resolve
                  rejecter:(RCTPromiseRejectBlock)reject) {
  if (![snapshot isKindOfClass:[NSDictionary class]]) {
    reject(@"invalid_snapshot", @"CarPlay library snapshot must be an object", nil);
    return;
  }
  [[LXCarPlayStore sharedStore] updateSnapshot:snapshot];
  resolve(nil);
}

@end

API_AVAILABLE(ios(14.0))
@interface LXCarPlaySceneDelegate : UIResponder <CPTemplateApplicationSceneDelegate, CPSearchTemplateDelegate>
@property (nonatomic, strong) CPInterfaceController *interfaceController;
@property (nonatomic, strong) CPListTemplate *rootTemplate;
@property (nonatomic, strong) CPSearchTemplate *searchTemplate;
@end

API_AVAILABLE(ios(14.0))
@implementation LXCarPlaySceneDelegate

- (instancetype)init {
  self = [super init];
  if (self) {
    [[NSNotificationCenter defaultCenter] addObserver:self
                                             selector:@selector(handleLibraryChanged:)
                                                 name:LXCarPlayLibraryDidChangeNotification
                                               object:nil];
    [[NSNotificationCenter defaultCenter] addObserver:self
                                             selector:@selector(handlePlaybackChanged:)
                                                 name:LXTrackPlayerLifecycleNotification
                                               object:nil];
    [[NSNotificationCenter defaultCenter] addObserver:self
                                             selector:@selector(handlePlaybackChanged:)
                                                 name:UIApplicationDidBecomeActiveNotification
                                               object:nil];
  }
  return self;
}

- (void)dealloc {
  [[NSNotificationCenter defaultCenter] removeObserver:self];
}

- (NSDictionary *)snapshot {
  return [[LXCarPlayStore sharedStore] snapshotCopy];
}

- (NSArray<NSDictionary *> *)allLists {
  id lists = [self snapshot][@"lists"];
  return [lists isKindOfClass:[NSArray class]] ? lists : @[];
}

- (NSArray<NSDictionary *> *)recentItems {
  id recent = [self snapshot][@"recent"];
  return [recent isKindOfClass:[NSArray class]] ? recent : @[];
}

- (NSDictionary *)listWithKind:(NSString *)kind {
  for (NSDictionary *list in [self allLists]) {
    if ([list[@"kind"] isEqualToString:kind]) return list;
  }
  return nil;
}

- (NSArray<NSDictionary *> *)userLists {
  NSMutableArray *result = [NSMutableArray array];
  for (NSDictionary *list in [self allLists]) {
    if ([list[@"kind"] isEqualToString:@"user"]) [result addObject:list];
  }
  return result;
}

- (NSString *)nowPlayingDetail {
  NSDictionary *info = [MPNowPlayingInfoCenter defaultCenter].nowPlayingInfo;
  NSString *title = LXCPString(info[MPMediaItemPropertyTitle], @"");
  NSString *artist = LXCPString(info[MPMediaItemPropertyArtist], @"");
  if (title.length == 0) {
    return [self allLists].count ? @"请选择歌曲" : @"音乐库正在同步";
  }
  return artist.length ? [NSString stringWithFormat:@"%@ · %@", title, artist] : title;
}

- (NSString *)syncDetail {
  NSNumber *updatedAt = [self snapshot][@"updatedAt"];
  if (![updatedAt isKindOfClass:[NSNumber class]] || updatedAt.doubleValue <= 0) return @"尚未同步，连接后会自动刷新";
  NSDate *date = [NSDate dateWithTimeIntervalSince1970:updatedAt.doubleValue / 1000.0];
  NSDateFormatter *formatter = [[NSDateFormatter alloc] init];
  formatter.dateStyle = NSDateFormatterNoStyle;
  formatter.timeStyle = NSDateFormatterShortStyle;
  return [NSString stringWithFormat:@"上次同步 %@", [formatter stringFromDate:date]];
}

- (void)pushTemplate:(CPTemplate *)template {
  if (!self.interfaceController || !template) return;
  [self.interfaceController pushTemplate:template animated:YES completion:NULL];
}

- (CPListItem *)containerItemWithText:(NSString *)text
                               detail:(NSString *)detail
                              handler:(void (^)(void))handler {
  CPListItem *item = [[CPListItem alloc] initWithText:text detailText:detail];
  item.accessoryType = CPListItemAccessoryTypeDisclosureIndicator;
  item.handler = ^(id<CPSelectableListItem> selectedItem, dispatch_block_t completionBlock) {
    if (handler) handler();
    if (completionBlock) completionBlock();
  };
  return item;
}

- (CPListItem *)musicItem:(NSDictionary *)music fallbackListId:(NSString *)fallbackListId {
  NSString *musicId = LXCPString(music[@"id"], @"");
  NSString *listId = LXCPString(music[@"listId"], fallbackListId ?: @"");
  CPListItem *item = [[CPListItem alloc] initWithText:LXCPString(music[@"name"], @"未知歌曲")
                                            detailText:LXCPMusicDetail(music)];
  item.userInfo = @{ @"listId": listId ?: @"", @"musicId": musicId ?: @"" };
  item.handler = ^(id<CPSelectableListItem> selectedItem, dispatch_block_t completionBlock) {
    NSDictionary *payload = [selectedItem isKindOfClass:[CPListItem class]] ? ((CPListItem *)selectedItem).userInfo : nil;
    NSString *selectedListId = LXCPString(payload[@"listId"], @"");
    NSString *selectedMusicId = LXCPString(payload[@"musicId"], @"");
    if (selectedListId.length && selectedMusicId.length) {
      [[LXCarPlayStore sharedStore] enqueueAction:@{
        @"type": @"play",
        @"listId": selectedListId,
        @"musicId": selectedMusicId,
      }];
    }
    if (completionBlock) completionBlock();
  };
  return item;
}

- (NSUInteger)pageCapacity {
  NSUInteger maximum = [CPListTemplate maximumItemCount];
  if (maximum == 0) maximum = 12;
  return maximum > 1 ? maximum - 1 : 1;
}

- (CPListTemplate *)musicTemplateWithTitle:(NSString *)title
                                     musics:(NSArray<NSDictionary *> *)musics
                                     listId:(NSString *)listId
                                     offset:(NSUInteger)offset {
  NSUInteger capacity = [self pageCapacity];
  NSUInteger end = MIN(musics.count, offset + capacity);
  NSMutableArray<CPListItem *> *items = [NSMutableArray array];

  for (NSUInteger index = offset; index < end; index++) {
    NSDictionary *music = [musics[index] isKindOfClass:[NSDictionary class]] ? musics[index] : @{};
    [items addObject:[self musicItem:music fallbackListId:listId]];
  }

  if (end < musics.count && [CPListTemplate maximumItemCount] != 1) {
    __weak typeof(self) weakSelf = self;
    NSString *nextDetail = [NSString stringWithFormat:@"%lu–%lu / %lu",
                            (unsigned long)(end + 1),
                            (unsigned long)MIN(musics.count, end + capacity),
                            (unsigned long)musics.count];
    CPListItem *next = [self containerItemWithText:@"下一页" detail:nextDetail handler:^{
      [weakSelf pushTemplate:[weakSelf musicTemplateWithTitle:title musics:musics listId:listId offset:end]];
    }];
    [items addObject:next];
  }

  CPListSection *section = [[CPListSection alloc] initWithItems:items];
  CPListTemplate *template = [[CPListTemplate alloc] initWithTitle:title sections:@[ section ]];
  if (items.count == 0) {
    template.emptyViewTitleVariants = @[ @"这个歌单还没有歌曲" ];
    template.emptyViewSubtitleVariants = @[ @"请先在手机端添加歌曲" ];
  }
  return template;
}

- (CPListTemplate *)templateForList:(NSDictionary *)list {
  NSString *title = LXCPString(list[@"name"], @"歌单");
  NSString *listId = LXCPString(list[@"id"], @"");
  id rawMusics = list[@"musics"];
  NSArray *musics = [rawMusics isKindOfClass:[NSArray class]] ? rawMusics : @[];
  return [self musicTemplateWithTitle:title musics:musics listId:listId offset:0];
}

- (CPListTemplate *)playlistsTemplateAtOffset:(NSUInteger)offset {
  NSArray<NSDictionary *> *lists = [self userLists];
  NSUInteger capacity = [self pageCapacity];
  NSUInteger end = MIN(lists.count, offset + capacity);
  NSMutableArray<CPListItem *> *items = [NSMutableArray array];
  __weak typeof(self) weakSelf = self;

  for (NSUInteger index = offset; index < end; index++) {
    NSDictionary *list = [lists[index] isKindOfClass:[NSDictionary class]] ? lists[index] : @{};
    NSArray *musics = [list[@"musics"] isKindOfClass:[NSArray class]] ? list[@"musics"] : @[];
    NSString *detail = [NSString stringWithFormat:@"%lu 首", (unsigned long)musics.count];
    CPListItem *item = [self containerItemWithText:LXCPString(list[@"name"], @"未命名歌单") detail:detail handler:^{
      [weakSelf pushTemplate:[weakSelf templateForList:list]];
    }];
    [items addObject:item];
  }

  if (end < lists.count && [CPListTemplate maximumItemCount] != 1) {
    CPListItem *next = [self containerItemWithText:@"下一页" detail:nil handler:^{
      [weakSelf pushTemplate:[weakSelf playlistsTemplateAtOffset:end]];
    }];
    [items addObject:next];
  }

  CPListSection *section = [[CPListSection alloc] initWithItems:items];
  CPListTemplate *template = [[CPListTemplate alloc] initWithTitle:@"我的歌单" sections:@[ section ]];
  if (items.count == 0) {
    template.emptyViewTitleVariants = @[ @"还没有自建歌单" ];
  }
  return template;
}

- (CPSearchTemplate *)makeSearchTemplate {
  CPSearchTemplate *template = [[CPSearchTemplate alloc] init];
  template.delegate = self;
  return template;
}

- (NSArray<CPListSection *> *)rootSections {
  __weak typeof(self) weakSelf = self;
  NSMutableArray<CPListItem *> *primaryItems = [NSMutableArray array];

  CPListItem *nowPlaying = [self containerItemWithText:@"正在播放" detail:[self nowPlayingDetail] handler:^{
    if (!weakSelf.interfaceController) return;
    CPNowPlayingTemplate *template = [CPNowPlayingTemplate sharedTemplate];
    if (weakSelf.interfaceController.topTemplate != template) {
      [weakSelf pushTemplate:template];
    }
  }];
  [primaryItems addObject:nowPlaying];

  NSDictionary *loveList = [self listWithKind:@"love"];
  if (loveList) {
    NSArray *musics = [loveList[@"musics"] isKindOfClass:[NSArray class]] ? loveList[@"musics"] : @[];
    CPListItem *love = [self containerItemWithText:@"我的收藏"
                                           detail:[NSString stringWithFormat:@"%lu 首", (unsigned long)musics.count]
                                          handler:^{ [weakSelf pushTemplate:[weakSelf templateForList:loveList]]; }];
    [primaryItems addObject:love];
  }

  NSDictionary *defaultList = [self listWithKind:@"default"];
  if (defaultList) {
    NSArray *musics = [defaultList[@"musics"] isKindOfClass:[NSArray class]] ? defaultList[@"musics"] : @[];
    CPListItem *audition = [self containerItemWithText:LXCPString(defaultList[@"name"], @"试听列表")
                                                detail:[NSString stringWithFormat:@"%lu 首", (unsigned long)musics.count]
                                               handler:^{ [weakSelf pushTemplate:[weakSelf templateForList:defaultList]]; }];
    [primaryItems addObject:audition];
  }

  NSArray *userLists = [self userLists];
  if (userLists.count) {
    CPListItem *playlists = [self containerItemWithText:@"我的歌单"
                                                 detail:[NSString stringWithFormat:@"%lu 个歌单", (unsigned long)userLists.count]
                                                handler:^{ [weakSelf pushTemplate:[weakSelf playlistsTemplateAtOffset:0]]; }];
    [primaryItems addObject:playlists];
  }

  NSArray *recent = [self recentItems];
  if (recent.count) {
    CPListItem *recentItem = [self containerItemWithText:@"最近播放"
                                                  detail:[NSString stringWithFormat:@"%lu 首", (unsigned long)recent.count]
                                                 handler:^{ [weakSelf pushTemplate:[weakSelf musicTemplateWithTitle:@"最近播放" musics:recent listId:@"" offset:0]]; }];
    [primaryItems addObject:recentItem];
  }

  CPListItem *search = [self containerItemWithText:@"搜索音乐" detail:@"搜索已同步的收藏和歌单" handler:^{
    weakSelf.searchTemplate = [weakSelf makeSearchTemplate];
    [weakSelf pushTemplate:weakSelf.searchTemplate];
  }];
  [primaryItems addObject:search];

  CPListItem *refresh = [[CPListItem alloc] initWithText:@"刷新音乐库" detailText:[self syncDetail]];
  refresh.handler = ^(id<CPSelectableListItem> selectedItem, dispatch_block_t completionBlock) {
    [[LXCarPlayStore sharedStore] enqueueAction:@{ @"type": @"refresh-library" }];
    if (completionBlock) completionBlock();
  };
  [primaryItems addObject:refresh];

  NSUInteger maximum = [CPListTemplate maximumItemCount];
  if (maximum > 0 && primaryItems.count > maximum) {
    [primaryItems removeObjectsInRange:NSMakeRange(maximum, primaryItems.count - maximum)];
  }
  return @[ [[CPListSection alloc] initWithItems:primaryItems] ];
}

- (CPListTemplate *)buildRootTemplate {
  CPListTemplate *template = [[CPListTemplate alloc] initWithTitle:@"LX Music" sections:[self rootSections]];
  if ([self allLists].count == 0) {
    template.emptyViewTitleVariants = @[ @"LX Music" ];
    template.emptyViewSubtitleVariants = @[ @"正在等待手机端同步音乐库" ];
  }
  return template;
}

- (void)refreshRootTemplate {
  if (!self.interfaceController || !self.rootTemplate) return;
  dispatch_async(dispatch_get_main_queue(), ^{
    [self.rootTemplate updateSections:[self rootSections]];
  });
}

- (void)handleLibraryChanged:(NSNotification *)notification {
  [self refreshRootTemplate];
}

- (void)handlePlaybackChanged:(NSNotification *)notification {
  [self refreshRootTemplate];
}

- (void)templateApplicationScene:(CPTemplateApplicationScene *)templateApplicationScene
   didConnectInterfaceController:(CPInterfaceController *)interfaceController {
  self.interfaceController = interfaceController;

  // CarPlay requires a root template before this callback returns. Build it only from
  // local/native state: never wait for React Native, networking, custom sources, or disk writes.
  self.rootTemplate = [self buildRootTemplate];
  [interfaceController setRootTemplate:self.rootTemplate animated:NO completion:NULL];

  // Ask RN to refresh in the background. If RN is still booting the action stays queued and
  // is delivered as soon as CarPlayModule starts observing.
  [[LXCarPlayStore sharedStore] enqueueAction:@{ @"type": @"refresh-library" }];
}

- (void)templateApplicationScene:(CPTemplateApplicationScene *)templateApplicationScene
 didDisconnectInterfaceController:(CPInterfaceController *)interfaceController {
  if (self.interfaceController == interfaceController) {
    self.interfaceController = nil;
    self.rootTemplate = nil;
    self.searchTemplate = nil;
  }
}

#pragma mark - CPSearchTemplateDelegate

- (void)searchTemplate:(CPSearchTemplate *)searchTemplate
     updatedSearchText:(NSString *)searchText
     completionHandler:(void (^)(NSArray<CPListItem *> *searchResults))completionHandler {
  NSString *query = [searchText stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
  if (query.length == 0) {
    completionHandler(@[]);
    return;
  }

  NSMutableArray<CPListItem *> *results = [NSMutableArray array];
  NSMutableSet<NSString *> *seen = [NSMutableSet set];
  NSUInteger maximum = [CPListTemplate maximumItemCount];
  if (maximum == 0) maximum = 24;

  for (NSDictionary *list in [self allLists]) {
    NSString *listId = LXCPString(list[@"id"], @"");
    NSArray *musics = [list[@"musics"] isKindOfClass:[NSArray class]] ? list[@"musics"] : @[];
    for (NSDictionary *music in musics) {
      NSString *musicId = LXCPString(music[@"id"], @"");
      if (musicId.length == 0 || [seen containsObject:musicId]) continue;
      NSString *name = LXCPString(music[@"name"], @"");
      NSString *singer = LXCPString(music[@"singer"], @"");
      NSString *album = LXCPString(music[@"album"], @"");
      BOOL matched = [name localizedCaseInsensitiveContainsString:query]
        || [singer localizedCaseInsensitiveContainsString:query]
        || [album localizedCaseInsensitiveContainsString:query];
      if (!matched) continue;

      CPListItem *item = [[CPListItem alloc] initWithText:name.length ? name : @"未知歌曲"
                                               detailText:LXCPMusicDetail(music)];
      item.userInfo = @{ @"listId": listId, @"musicId": musicId };
      [results addObject:item];
      [seen addObject:musicId];
      if (results.count >= maximum) break;
    }
    if (results.count >= maximum) break;
  }
  completionHandler(results);
}

- (void)searchTemplate:(CPSearchTemplate *)searchTemplate
         selectedResult:(CPListItem *)item
      completionHandler:(void (^)(void))completionHandler {
  NSDictionary *payload = [item.userInfo isKindOfClass:[NSDictionary class]] ? item.userInfo : @{};
  NSString *listId = LXCPString(payload[@"listId"], @"");
  NSString *musicId = LXCPString(payload[@"musicId"], @"");
  if (listId.length && musicId.length) {
    [[LXCarPlayStore sharedStore] enqueueAction:@{
      @"type": @"play",
      @"listId": listId,
      @"musicId": musicId,
    }];
  }
  if (completionHandler) completionHandler();
}

- (void)searchTemplateSearchButtonPressed:(CPSearchTemplate *)searchTemplate {
  // Results are updated incrementally by updatedSearchText; no network request is needed here.
}

@end

@implementation AppDelegate (LXCarPlaySceneConfiguration)

- (UISceneConfiguration *)application:(UIApplication *)application
 configurationForConnectingSceneSession:(UISceneSession *)connectingSceneSession
                              options:(UISceneConnectionOptions *)options API_AVAILABLE(ios(13.0)) {
  if (@available(iOS 14.0, *)) {
    if ([connectingSceneSession.role isEqualToString:CPTemplateApplicationSceneSessionRoleApplication]) {
      UISceneConfiguration *configuration = [[UISceneConfiguration alloc] initWithName:@"LX Music CarPlay"
                                                                            sessionRole:connectingSceneSession.role];
      configuration.sceneClass = [CPTemplateApplicationScene class];
      configuration.delegateClass = [LXCarPlaySceneDelegate class];
      return configuration;
    }
  }
  // The phone UI intentionally remains on ReactNativeNavigation's legacy AppDelegate lifecycle.
  return nil;
}

@end

int main(int argc, char *argv[])
{
  @autoreleasepool {
    return UIApplicationMain(argc, argv, nil, NSStringFromClass([AppDelegate class]));
  }
}
