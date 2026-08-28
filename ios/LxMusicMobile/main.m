#import <UIKit/UIKit.h>
#import <MediaPlayer/MediaPlayer.h>
#import <React/RCTBridgeModule.h>
#import <React/RCTEventEmitter.h>

#import "AppDelegate.h"

static NSString * const LXCarPlayLibraryDidChangeNotification = @"LXCarPlayLibraryDidChange";
static NSString * const LXCarPlayActionQueuedNotification = @"LXCarPlayActionQueued";

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
  NSData *data = [NSData dataWithContentsOfURL:[self snapshotURL] options:0 error:nil];
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
        if ([queued[@"type"] isEqualToString:@"refresh-library"]) return;
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

#pragma mark - Legacy MediaPlayer CarPlay provider

// This app intentionally uses MPPlayableContentManager instead of CPTemplateApplicationScene.
// LX Music's phone UI is based on ReactNativeNavigation's legacy UIApplication/AppDelegate
// lifecycle. Opting the process into a CarPlay UIScene caused the phone window to become black
// on TrollStore installations. Apple's MediaPlayer CarPlay API does not create or take ownership
// of a phone UIScene and remains supported on iOS 14 and later for audio apps.
@interface LXPlayableContentCoordinator : NSObject <MPPlayableContentDataSource, MPPlayableContentDelegate>
@property (nonatomic, assign) BOOL installed;
+ (instancetype)sharedCoordinator;
- (void)installIfNeeded;
- (void)reloadLibrary;
@end

@implementation LXPlayableContentCoordinator

+ (instancetype)sharedCoordinator {
  static LXPlayableContentCoordinator *coordinator;
  static dispatch_once_t onceToken;
  dispatch_once(&onceToken, ^{
    coordinator = [[LXPlayableContentCoordinator alloc] init];
  });
  return coordinator;
}

- (void)installIfNeeded {
  if (self.installed) return;
  self.installed = YES;

  MPPlayableContentManager *manager = [MPPlayableContentManager sharedContentManager];
  manager.dataSource = self;
  manager.delegate = self;
  [manager beginUpdates];
  [manager endUpdates];

  [[NSNotificationCenter defaultCenter] addObserver:self
                                           selector:@selector(handleLibraryChanged:)
                                               name:LXCarPlayLibraryDidChangeNotification
                                             object:nil];
}

- (void)dealloc {
  [[NSNotificationCenter defaultCenter] removeObserver:self];
}

- (void)handleLibraryChanged:(NSNotification *)notification {
  [self reloadLibrary];
}

- (void)reloadLibrary {
  dispatch_async(dispatch_get_main_queue(), ^{
    MPPlayableContentManager *manager = [MPPlayableContentManager sharedContentManager];
    [manager beginUpdates];
    [manager reloadData];
    [manager endUpdates];
  });
}

- (NSArray<NSDictionary *> *)rootEntries {
  NSDictionary *snapshot = [[LXCarPlayStore sharedStore] snapshotCopy];
  NSMutableArray<NSDictionary *> *entries = [NSMutableArray array];

  NSArray *recent = [snapshot[@"recent"] isKindOfClass:[NSArray class]] ? snapshot[@"recent"] : @[];
  if (recent.count > 0) {
    [entries addObject:@{
      @"id": @"__recent__",
      @"name": @"最近播放",
      @"kind": @"recent",
      @"musics": recent,
    }];
  }

  NSArray *lists = [snapshot[@"lists"] isKindOfClass:[NSArray class]] ? snapshot[@"lists"] : @[];
  for (id value in lists) {
    if ([value isKindOfClass:[NSDictionary class]]) [entries addObject:value];
  }
  return entries;
}

- (NSUInteger)contentLimitForCount:(NSUInteger)count {
  MPPlayableContentManagerContext *context = [MPPlayableContentManager sharedContentManager].context;
  if (context != nil && context.contentLimitsEnforced) {
    NSInteger enforced = context.enforcedContentItemsCount;
    if (enforced > 0 && enforced != NSIntegerMax) return MIN(count, (NSUInteger)enforced);
  }
  return count;
}

- (NSDictionary *)rootEntryAtIndex:(NSUInteger)index {
  NSArray<NSDictionary *> *entries = [self rootEntries];
  NSUInteger count = [self contentLimitForCount:entries.count];
  if (index >= count) return nil;
  id value = entries[index];
  return [value isKindOfClass:[NSDictionary class]] ? value : nil;
}

- (NSArray<NSDictionary *> *)musicsForRootEntry:(NSDictionary *)entry {
  id musics = entry[@"musics"];
  return [musics isKindOfClass:[NSArray class]] ? musics : @[];
}

- (NSDictionary *)musicAtIndexPath:(NSIndexPath *)indexPath rootEntry:(NSDictionary **)rootEntryOut {
  if (indexPath.length < 2) return nil;
  NSUInteger rootIndex = [indexPath indexAtPosition:0];
  NSUInteger musicIndex = [indexPath indexAtPosition:1];
  NSDictionary *entry = [self rootEntryAtIndex:rootIndex];
  if (rootEntryOut != NULL) *rootEntryOut = entry;
  if (entry == nil) return nil;
  NSArray<NSDictionary *> *musics = [self musicsForRootEntry:entry];
  NSUInteger count = [self contentLimitForCount:musics.count];
  if (musicIndex >= count) return nil;
  id value = musics[musicIndex];
  return [value isKindOfClass:[NSDictionary class]] ? value : nil;
}

- (NSInteger)numberOfChildItemsAtIndexPath:(NSIndexPath *)indexPath {
  if (indexPath.length == 0) {
    return (NSInteger)[self contentLimitForCount:[self rootEntries].count];
  }
  if (indexPath.length == 1) {
    NSDictionary *entry = [self rootEntryAtIndex:[indexPath indexAtPosition:0]];
    if (entry == nil) return 0;
    return (NSInteger)[self contentLimitForCount:[self musicsForRootEntry:entry].count];
  }
  return 0;
}

- (MPContentItem *)contentItemAtIndexPath:(NSIndexPath *)indexPath {
  if (indexPath.length == 1) {
    NSDictionary *entry = [self rootEntryAtIndex:[indexPath indexAtPosition:0]];
    if (entry == nil) return nil;

    NSString *listId = LXCPString(entry[@"id"], [NSString stringWithFormat:@"root-%lu", (unsigned long)[indexPath indexAtPosition:0]]);
    MPContentItem *item = [[MPContentItem alloc] initWithIdentifier:[NSString stringWithFormat:@"lx:list:%@", listId]];
    item.title = LXCPString(entry[@"name"], @"歌单");
    NSArray *musics = [self musicsForRootEntry:entry];
    item.subtitle = [NSString stringWithFormat:@"%lu 首", (unsigned long)musics.count];
    item.container = YES;
    item.playable = NO;
    return item;
  }

  if (indexPath.length == 2) {
    NSDictionary *entry = nil;
    NSDictionary *music = [self musicAtIndexPath:indexPath rootEntry:&entry];
    if (music == nil || entry == nil) return nil;

    NSString *fallbackListId = LXCPString(entry[@"id"], @"");
    NSString *listId = LXCPString(music[@"listId"], fallbackListId);
    NSString *musicId = LXCPString(music[@"id"], [NSString stringWithFormat:@"music-%lu", (unsigned long)[indexPath indexAtPosition:1]]);
    NSString *identifier = [NSString stringWithFormat:@"lx:music:%@:%@", listId, musicId];
    MPContentItem *item = [[MPContentItem alloc] initWithIdentifier:identifier];
    item.title = LXCPString(music[@"name"], @"未知歌曲");
    NSString *detail = LXCPMusicDetail(music);
    item.subtitle = detail.length ? detail : nil;
    item.container = NO;
    item.playable = YES;
    item.streamingContent = YES;
    return item;
  }

  return nil;
}

- (void)playableContentManager:(MPPlayableContentManager *)contentManager
 initiatePlaybackOfContentItemAtIndexPath:(NSIndexPath *)indexPath
              completionHandler:(void (^)(NSError * _Nullable))completionHandler {
  NSDictionary *entry = nil;
  NSDictionary *music = [self musicAtIndexPath:indexPath rootEntry:&entry];
  if (music == nil || entry == nil) {
    if (completionHandler) {
      NSError *error = [NSError errorWithDomain:@"LXMusicCarPlay"
                                           code:1
                                       userInfo:@{NSLocalizedDescriptionKey: @"找不到选择的歌曲"}];
      completionHandler(error);
    }
    return;
  }

  NSString *listId = LXCPString(music[@"listId"], LXCPString(entry[@"id"], @""));
  NSString *musicId = LXCPString(music[@"id"], @"");
  if (listId.length == 0 || musicId.length == 0) {
    if (completionHandler) {
      NSError *error = [NSError errorWithDomain:@"LXMusicCarPlay"
                                           code:2
                                       userInfo:@{NSLocalizedDescriptionKey: @"歌曲标识无效"}];
      completionHandler(error);
    }
    return;
  }

  [[LXCarPlayStore sharedStore] enqueueAction:@{
    @"type": @"play",
    @"listId": listId,
    @"musicId": musicId,
  }];

  MPContentItem *selected = [self contentItemAtIndexPath:indexPath];
  if (selected.identifier.length) contentManager.nowPlayingIdentifiers = @[ selected.identifier ];

  // JS receives this action on the existing RN bridge and starts the same player used by
  // the phone, lock screen and steering-wheel controls. Do not create a second AVPlayer.
  if (completionHandler) completionHandler(nil);
}

@end

#pragma mark - React Native bridge

@interface CarPlayModule : RCTEventEmitter <RCTBridgeModule>
@property (nonatomic, assign) BOOL hasJSListeners;
@end

@implementation CarPlayModule

RCT_EXPORT_MODULE(CarPlayModule);

+ (BOOL)requiresMainQueueSetup {
  return NO;
}

- (instancetype)init {
  self = [super init];
  if (self) {
    [[NSNotificationCenter defaultCenter] addObserver:self
                                             selector:@selector(handleQueuedActions:)
                                                 name:LXCarPlayActionQueuedNotification
                                               object:nil];
    dispatch_async(dispatch_get_main_queue(), ^{
      [[LXPlayableContentCoordinator sharedCoordinator] installIfNeeded];
    });
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
  dispatch_async(dispatch_get_main_queue(), ^{
    [[LXPlayableContentCoordinator sharedCoordinator] installIfNeeded];
    [[LXPlayableContentCoordinator sharedCoordinator] reloadLibrary];
  });
  resolve(nil);
}

@end

// Install only the MediaPlayer content provider. This schedules work on the main queue but does
// not create any UIWindow/UIScene and does not change ReactNativeNavigation's phone lifecycle.
__attribute__((constructor))
static void LXInstallMediaPlayerCarPlayProvider(void) {
  dispatch_async(dispatch_get_main_queue(), ^{
    [[LXPlayableContentCoordinator sharedCoordinator] installIfNeeded];
  });
}

int main(int argc, char *argv[])
{
  @autoreleasepool {
    return UIApplicationMain(argc, argv, nil, NSStringFromClass([AppDelegate class]));
  }
}
