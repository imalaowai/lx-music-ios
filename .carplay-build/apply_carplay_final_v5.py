from pathlib import Path

path = Path('ios/LxMusicMobile/main.m')
text = path.read_text()

def replace_once(old: str, new: str, label: str):
    global text
    if old not in text:
        raise SystemExit(f'Unable to locate {label}')
    text = text.replace(old, new, 1)

replace_once(
'''@interface LXCarPlaySceneDelegate : UIResponder <CPTemplateApplicationSceneDelegate>\n@property (nonatomic, strong, nullable) CPInterfaceController *interfaceController;\n@property (nonatomic, strong, nullable) CPTabBarTemplate *tabBarTemplate;\n@property (nonatomic, strong, nullable) CPListTemplate *homeTemplate;\n@property (nonatomic, strong, nullable) CPListTemplate *libraryTemplate;\n@property (nonatomic, strong, nullable) CPListTemplate *playlistsTemplate;\n@end''',
'''@interface LXCarPlaySceneDelegate : UIResponder <CPTemplateApplicationSceneDelegate, CPNowPlayingTemplateObserver>\n@property (nonatomic, strong, nullable) CPInterfaceController *interfaceController;\n@property (nonatomic, strong, nullable) CPTabBarTemplate *tabBarTemplate;\n@property (nonatomic, strong, nullable) CPListTemplate *homeTemplate;\n@property (nonatomic, strong, nullable) CPListTemplate *libraryTemplate;\n@property (nonatomic, strong, nullable) CPListTemplate *playlistsTemplate;\n@property (nonatomic, strong, nullable) CPListTemplate *recentTemplate;\n@property (nonatomic, strong, nullable) CPListTemplate *favoritesTemplate;\n@property (nonatomic, assign) BOOL enhancedRootAttempted;\n@property (nonatomic, assign) BOOL enhancedRootActive;\n@property (nonatomic, assign) BOOL nowPlayingObserverInstalled;\n@end''',
'CarPlay scene interface')

replace_once(
'''- (void)showNowPlaying {\n  CPInterfaceController *controller = self.interfaceController;\n  if (controller == nil) return;\n  CPNowPlayingTemplate *template = CPNowPlayingTemplate.sharedTemplate;\n  if (controller.topTemplate == template) return;\n  [self pushTemplate:template];\n}\n''',
'''- (void)configureNowPlayingTemplate {\n  CPNowPlayingTemplate *template = CPNowPlayingTemplate.sharedTemplate;\n  if (template == nil) return;\n\n  if (!self.nowPlayingObserverInstalled) {\n    @try {\n      [template addObserver:self];\n      self.nowPlayingObserverInstalled = YES;\n    } @catch (NSException *exception) {\n      NSLog(@"[LXCarPlay] Now Playing observer exception: %@", exception);\n    }\n  }\n\n  // Match mature native CarPlay audio apps: the system Now Playing screen remains the single\n  // playback surface, while these buttons navigate back into LX Music content.\n  template.upNextButtonEnabled = YES;\n  template.upNextTitle = @"最近播放";\n  template.albumArtistButtonEnabled = YES;\n}\n\n- (void)showNowPlaying {\n  CPInterfaceController *controller = self.interfaceController;\n  if (controller == nil) return;\n  [self configureNowPlayingTemplate];\n  CPNowPlayingTemplate *template = CPNowPlayingTemplate.sharedTemplate;\n  if (controller.topTemplate == template) return;\n  [self pushTemplate:template];\n}\n\n- (void)nowPlayingTemplateUpNextButtonTapped:(CPNowPlayingTemplate *)nowPlayingTemplate {\n  NSDictionary *entry = @{\n    @"id": @"__recent__",\n    @"name": @"最近播放",\n    @"kind": @"recent",\n    @"musics": [self recentMusics],\n  };\n  [self pushPlaylistEntry:entry offset:0];\n}\n\n- (void)nowPlayingTemplateAlbumArtistButtonTapped:(CPNowPlayingTemplate *)nowPlayingTemplate {\n  CPListTemplate *template = [[CPListTemplate alloc] initWithTitle:@"音乐库"\n                                                          sections:[self librarySections]];\n  template.emptyViewTitleVariants = @[ @"LX Music" ];\n  template.emptyViewSubtitleVariants = @[ @"请先在手机端打开一次 LX Music 完成音乐库同步" ];\n  [self pushTemplate:template];\n}\n''',
'showNowPlaying')

root_start = text.find('- (void)buildRootTemplate {')
root_end = text.find('- (void)refreshVisibleLibrary {', root_start)
if root_start < 0 or root_end < 0:
    raise SystemExit('Unable to locate root block')

new_root = r'''- (NSDictionary *)recentEntry {
  return @{
    @"id": @"__recent__",
    @"name": @"最近播放",
    @"kind": @"recent",
    @"musics": [self recentMusics],
  };
}

- (NSDictionary *)favoritesEntry {
  NSDictionary *love = [self listWithKind:@"love"];
  if (love != nil) return love;
  return @{
    @"id": @"__love__",
    @"name": @"我的收藏",
    @"kind": @"love",
    @"musics": @[],
  };
}

- (void)configureTabTemplate:(CPTemplate *)template title:(NSString *)title symbol:(NSString *)symbolName {
  template.tabTitle = title;
  template.tabImage = [self symbol:symbolName];
}

- (NSArray<CPTemplate *> *)enhancedTabTemplates {
  NSInteger maximumTabs = CPTabBarTemplate.maximumTabCount;
  if (maximumTabs < 2) return @[];

  self.homeTemplate = [[CPListTemplate alloc] initWithTitle:@"LX Music" sections:[self homeSections]];
  self.homeTemplate.emptyViewTitleVariants = @[ @"LX Music" ];
  self.homeTemplate.emptyViewSubtitleVariants = @[ @"请先在手机端打开一次 LX Music 完成音乐库同步" ];
  [self configureTabTemplate:self.homeTemplate title:@"首页" symbol:@"house.fill"];

  NSMutableArray<CPTemplate *> *templates = [NSMutableArray arrayWithObject:self.homeTemplate];

  if (templates.count < (NSUInteger)maximumTabs) {
    self.recentTemplate = [self playlistTemplateForEntry:[self recentEntry] offset:0];
    self.recentTemplate.emptyViewTitleVariants = @[ @"暂无最近播放" ];
    self.recentTemplate.emptyViewSubtitleVariants = @[ @"你播放过的歌曲会自动出现在这里" ];
    [self configureTabTemplate:self.recentTemplate title:@"最近" symbol:@"clock.fill"];
    [templates addObject:self.recentTemplate];
  }

  if (templates.count < (NSUInteger)maximumTabs) {
    self.favoritesTemplate = [self playlistTemplateForEntry:[self favoritesEntry] offset:0];
    self.favoritesTemplate.emptyViewTitleVariants = @[ @"我的收藏还是空的" ];
    self.favoritesTemplate.emptyViewSubtitleVariants = @[ @"在手机里收藏歌曲后会同步到这里" ];
    [self configureTabTemplate:self.favoritesTemplate title:@"收藏" symbol:@"heart.fill"];
    [templates addObject:self.favoritesTemplate];
  }

  if (templates.count < (NSUInteger)maximumTabs) {
    self.playlistsTemplate = [[CPListTemplate alloc] initWithTitle:@"我的歌单"
                                                          sections:[self playlistSectionsFromOffset:0]];
    self.playlistsTemplate.emptyViewTitleVariants = @[ @"暂无自建歌单" ];
    self.playlistsTemplate.emptyViewSubtitleVariants = @[ @"你创建的歌单会自动同步到这里" ];
    [self configureTabTemplate:self.playlistsTemplate title:@"歌单" symbol:@"rectangle.stack.fill"];
    [templates addObject:self.playlistsTemplate];
  }

  return templates;
}

- (CPListTemplate *)fallbackRootTemplate {
  CPListItem *fallbackItem = [[CPListItem alloc] initWithText:@"LX Music"
                                                  detailText:@"CarPlay 已连接，可从手机端刷新音乐库"
                                                       image:nil
                                              accessoryImage:nil
                                               accessoryType:CPListItemAccessoryTypeNone];
  CPListSection *fallbackSection = [[CPListSection alloc] initWithItems:@[ fallbackItem ]];
  return [[CPListTemplate alloc] initWithTitle:@"LX Music" sections:@[ fallbackSection ]];
}

- (void)restoreSafeRootAfterEnhancedFailure:(NSString *)reason {
  CPInterfaceController *controller = self.interfaceController;
  if (controller == nil) return;
  self.enhancedRootActive = NO;
  self.tabBarTemplate = nil;

  CPListTemplate *safeHome = self.homeTemplate;
  if (safeHome == nil) {
    safeHome = [[CPListTemplate alloc] initWithTitle:@"LX Music" sections:[self homeSections]];
    safeHome.emptyViewTitleVariants = @[ @"LX Music" ];
  }
  self.homeTemplate = safeHome;

  @try {
    [controller setRootTemplate:safeHome animated:NO completion:^(BOOL success, NSError *error) {
      if (!success) NSLog(@"[LXCarPlay] V5 safe root restore failed (%@): %@", reason, error);
    }];
  } @catch (NSException *exception) {
    NSLog(@"[LXCarPlay] V5 safe root restore exception (%@): %@", reason, exception);
    @try {
      [controller setRootTemplate:[self fallbackRootTemplate] animated:NO completion:nil];
    } @catch (__unused NSException *fallbackException) {}
  }
}

- (void)attemptEnhancedRootUpgrade {
  CPInterfaceController *controller = self.interfaceController;
  if (controller == nil || self.enhancedRootAttempted) return;
  self.enhancedRootAttempted = YES;

  @try {
    NSArray<CPTemplate *> *templates = [self enhancedTabTemplates];
    if (templates.count < 2) {
      NSLog(@"[LXCarPlay] V5 enhanced root skipped: maximumTabCount=%ld", (long)CPTabBarTemplate.maximumTabCount);
      return;
    }

    CPTabBarTemplate *tabBar = [[CPTabBarTemplate alloc] initWithTemplates:templates];
    self.tabBarTemplate = tabBar;
    __weak typeof(self) weakSelf = self;
    [controller setRootTemplate:tabBar animated:NO completion:^(BOOL success, NSError *error) {
      __strong typeof(weakSelf) self = weakSelf;
      if (self == nil || self.interfaceController != controller) return;
      if (success) {
        self.enhancedRootActive = YES;
        NSLog(@"[LXCarPlay] V5 enhanced tab root active (%lu tabs)", (unsigned long)templates.count);
      } else {
        NSLog(@"[LXCarPlay] V5 enhanced root failed: %@", error);
        [self restoreSafeRootAfterEnhancedFailure:@"completion"];
      }
    }];
  } @catch (NSException *exception) {
    NSLog(@"[LXCarPlay] V5 enhanced root exception: %@", exception);
    [self restoreSafeRootAfterEnhancedFailure:@"exception"];
  }
}

- (void)scheduleEnhancedRootUpgradeForController:(CPInterfaceController *)controller {
  __weak typeof(self) weakSelf = self;
  dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(450 * NSEC_PER_MSEC)), dispatch_get_main_queue(), ^{
    __strong typeof(weakSelf) self = weakSelf;
    if (self == nil || self.interfaceController != controller) return;
    [self attemptEnhancedRootUpgrade];
  });
}

- (void)buildRootTemplate {
  CPInterfaceController *controller = self.interfaceController;
  if (controller == nil) return;

  self.enhancedRootAttempted = NO;
  self.enhancedRootActive = NO;
  self.tabBarTemplate = nil;
  self.libraryTemplate = nil;
  self.playlistsTemplate = nil;
  self.recentTemplate = nil;
  self.favoritesTemplate = nil;

  self.homeTemplate = [[CPListTemplate alloc] initWithTitle:@"LX Music" sections:[self homeSections]];
  self.homeTemplate.emptyViewTitleVariants = @[ @"LX Music" ];
  self.homeTemplate.emptyViewSubtitleVariants = @[ @"请先在手机端打开一次 LX Music 完成音乐库同步" ];

  __weak typeof(self) weakSelf = self;
  @try {
    [controller setRootTemplate:self.homeTemplate animated:NO completion:^(BOOL success, NSError *error) {
      __strong typeof(weakSelf) self = weakSelf;
      if (self == nil || self.interfaceController != controller) return;
      if (success) {
        NSLog(@"[LXCarPlay] V5 safe root active");
        [self scheduleEnhancedRootUpgradeForController:controller];
      } else {
        NSLog(@"[LXCarPlay] V5 safe root failed: %@", error);
        @try {
          [controller setRootTemplate:[self fallbackRootTemplate] animated:NO completion:nil];
        } @catch (__unused NSException *fallbackException) {}
      }
    }];
  } @catch (NSException *exception) {
    NSLog(@"[LXCarPlay] V5 safe root exception: %@", exception);
    @try {
      [controller setRootTemplate:[self fallbackRootTemplate] animated:NO completion:nil];
    } @catch (__unused NSException *fallbackException) {}
  }
}

'''
text = text[:root_start] + new_root + text[root_end:]

refresh_start = text.find('- (void)refreshVisibleLibrary {')
refresh_end = text.find('- (void)handleLibraryChanged:', refresh_start)
if refresh_start < 0 or refresh_end < 0:
    raise SystemExit('Unable to locate refresh block')

new_refresh = r'''- (void)refreshVisibleLibrary {
  dispatch_async(dispatch_get_main_queue(), ^{
    if (self.interfaceController == nil) return;
    if (self.homeTemplate == nil) {
      [self buildRootTemplate];
      return;
    }

    if (self.enhancedRootActive && self.tabBarTemplate != nil) {
      @try {
        NSArray<CPTemplate *> *templates = [self enhancedTabTemplates];
        if (templates.count >= 2) {
          [self.tabBarTemplate updateTemplates:templates];
          return;
        }
      } @catch (NSException *exception) {
        NSLog(@"[LXCarPlay] V5 tab refresh exception: %@", exception);
      }
    }

    @try {
      [self.homeTemplate updateSections:[self homeSections]];
    } @catch (NSException *exception) {
      NSLog(@"[LXCarPlay] V5 home refresh exception: %@", exception);
    }
  });
}

'''
text = text[:refresh_start] + new_refresh + text[refresh_end:]

connect_old = '''- (void)templateApplicationScene:(CPTemplateApplicationScene *)templateApplicationScene\n   didConnectInterfaceController:(CPInterfaceController *)interfaceController {\n  self.interfaceController = interfaceController;\n  [[NSNotificationCenter defaultCenter] removeObserver:self\n                                                  name:LXCarPlayLibraryDidChangeNotification\n                                                object:nil];\n  [[NSNotificationCenter defaultCenter] addObserver:self\n                                           selector:@selector(handleLibraryChanged:)\n                                               name:LXCarPlayLibraryDidChangeNotification\n                                             object:nil];\n  [self buildRootTemplate];\n\n  // Request a fresh snapshot from RN without making CarPlay wait for RN before showing UI.\n  [[LXCarPlayStore sharedStore] enqueueAction:@{ @"type": @"refresh-library" }];\n}\n\n- (void)templateApplicationScene:(CPTemplateApplicationScene *)templateApplicationScene\ndidDisconnectInterfaceController:(CPInterfaceController *)interfaceController {\n  [[NSNotificationCenter defaultCenter] removeObserver:self name:LXCarPlayLibraryDidChangeNotification object:nil];\n  self.interfaceController = nil;\n  self.tabBarTemplate = nil;\n  self.homeTemplate = nil;\n  self.libraryTemplate = nil;\n  self.playlistsTemplate = nil;\n}\n\n- (void)dealloc {\n  [[NSNotificationCenter defaultCenter] removeObserver:self];\n}\n'''
connect_new = '''- (void)templateApplicationScene:(CPTemplateApplicationScene *)templateApplicationScene\n   didConnectInterfaceController:(CPInterfaceController *)interfaceController {\n  self.interfaceController = interfaceController;\n  self.enhancedRootAttempted = NO;\n  self.enhancedRootActive = NO;\n  self.nowPlayingObserverInstalled = NO;\n  [[NSNotificationCenter defaultCenter] removeObserver:self\n                                                  name:LXCarPlayLibraryDidChangeNotification\n                                                object:nil];\n  [[NSNotificationCenter defaultCenter] addObserver:self\n                                           selector:@selector(handleLibraryChanged:)\n                                               name:LXCarPlayLibraryDidChangeNotification\n                                             object:nil];\n  [self configureNowPlayingTemplate];\n  [self buildRootTemplate];\n\n  [[LXCarPlayStore sharedStore] enqueueAction:@{ @"type": @"refresh-library" }];\n}\n\n- (void)templateApplicationScene:(CPTemplateApplicationScene *)templateApplicationScene\ndidDisconnectInterfaceController:(CPInterfaceController *)interfaceController {\n  [[NSNotificationCenter defaultCenter] removeObserver:self name:LXCarPlayLibraryDidChangeNotification object:nil];\n  if (self.nowPlayingObserverInstalled) {\n    @try { [CPNowPlayingTemplate.sharedTemplate removeObserver:self]; } @catch (__unused NSException *exception) {}\n  }\n  self.nowPlayingObserverInstalled = NO;\n  self.enhancedRootAttempted = NO;\n  self.enhancedRootActive = NO;\n  self.interfaceController = nil;\n  self.tabBarTemplate = nil;\n  self.homeTemplate = nil;\n  self.libraryTemplate = nil;\n  self.playlistsTemplate = nil;\n  self.recentTemplate = nil;\n  self.favoritesTemplate = nil;\n}\n\n- (void)dealloc {\n  if (self.nowPlayingObserverInstalled) {\n    @try { [CPNowPlayingTemplate.sharedTemplate removeObserver:self]; } @catch (__unused NSException *exception) {}\n  }\n  [[NSNotificationCenter defaultCenter] removeObserver:self];\n}\n'''
replace_once(connect_old, connect_new, 'connect/disconnect block')

path.write_text(text)
print('V5 patch applied')
