from pathlib import Path

main_path = Path('ios/LxMusicMobile/main.m')
text = main_path.read_text()

home_start = text.find('- (NSArray<CPListSection *> *)homeSections {')
home_end = text.find('- (NSArray<CPListSection *> *)librarySections {', home_start)
if home_start < 0 or home_end < 0:
    raise SystemExit('Unable to locate homeSections')

new_home = r'''- (NSArray<CPListSection *> *)homeSections {
  NSMutableArray<CPListItem *> *items = [NSMutableArray array];
  __weak typeof(self) weakSelf = self;

  [items addObject:[self actionItemWithText:@"正在播放"
                                 detailText:@"查看当前歌曲和系统播放控制"
                                     symbol:@"play.circle.fill"
                                    handler:^{
    __strong typeof(weakSelf) self = weakSelf;
    if (self != nil) [self showNowPlaying];
  }]];

  [items addObject:[self recentContainerItem]];

  [items addObject:[self actionItemWithText:@"音乐库"
                                 detailText:@"收藏、试听列表和最近播放"
                                     symbol:@"music.note.list"
                                    handler:^{
    __strong typeof(weakSelf) self = weakSelf;
    if (self == nil) return;
    CPListTemplate *template = [[CPListTemplate alloc] initWithTitle:@"音乐库"
                                                            sections:[self librarySections]];
    template.emptyViewTitleVariants = @[ @"LX Music" ];
    template.emptyViewSubtitleVariants = @[ @"请先在手机端打开一次 LX Music 完成音乐库同步" ];
    [self pushTemplate:template];
  }]];

  [items addObject:[self actionItemWithText:@"我的歌单"
                                 detailText:@"浏览手机端创建的歌单"
                                     symbol:@"rectangle.stack.fill"
                                    handler:^{
    __strong typeof(weakSelf) self = weakSelf;
    if (self == nil) return;
    CPListTemplate *template = [[CPListTemplate alloc] initWithTitle:@"我的歌单"
                                                            sections:[self playlistSectionsFromOffset:0]];
    template.emptyViewTitleVariants = @[ @"暂无自建歌单" ];
    template.emptyViewSubtitleVariants = @[ @"可先在手机端创建歌单" ];
    [self pushTemplate:template];
  }]];

  [items addObject:[self actionItemWithText:@"刷新音乐库"
                                 detailText:@"从手机端重新同步歌单与最近播放"
                                     symbol:@"arrow.clockwise"
                                    handler:^{
    [[LXCarPlayStore sharedStore] enqueueAction:@{ @"type": @"refresh-library" }];
  }]];

  NSUInteger maximum = [self maximumListItems];
  if (items.count > maximum) [items removeObjectsInRange:NSMakeRange(maximum, items.count - maximum)];
  return @[ [[CPListSection alloc] initWithItems:items] ];
}

'''
text = text[:home_start] + new_home + text[home_end:]

root_start = text.find('- (void)buildRootTemplate {')
root_end = text.find('- (void)refreshVisibleLibrary {', root_start)
if root_start < 0 or root_end < 0:
    raise SystemExit('Unable to locate buildRootTemplate')

new_root = r'''- (void)buildRootTemplate {
  CPInterfaceController *controller = self.interfaceController;
  if (controller == nil) return;

  // Keep the first CarPlay screen intentionally simple. A single CPListTemplate is the
  // most broadly compatible audio-app root and avoids CPTabBarTemplate related black screens
  // seen on some head units. Library and playlists are pushed lazily from this root.
  self.homeTemplate = [[CPListTemplate alloc] initWithTitle:@"LX Music" sections:[self homeSections]];
  self.homeTemplate.emptyViewTitleVariants = @[ @"LX Music" ];
  self.homeTemplate.emptyViewSubtitleVariants = @[ @"请先在手机端打开一次 LX Music 完成音乐库同步" ];
  self.tabBarTemplate = nil;
  self.libraryTemplate = nil;
  self.playlistsTemplate = nil;

  @try {
    [controller setRootTemplate:self.homeTemplate animated:NO completion:^(BOOL success, NSError *error) {
      if (!success) {
        NSLog(@"[LXCarPlay] simple root set failed: %@", error);
      }
    }];
  } @catch (NSException *exception) {
    NSLog(@"[LXCarPlay] simple root exception: %@", exception);
    @try {
      CPListItem *fallbackItem = [[CPListItem alloc] initWithText:@"LX Music"
                                                      detailText:@"CarPlay 已连接"
                                                           image:nil
                                                  accessoryImage:nil
                                                   accessoryType:CPListItemAccessoryTypeNone];
      CPListSection *fallbackSection = [[CPListSection alloc] initWithItems:@[ fallbackItem ]];
      CPListTemplate *fallback = [[CPListTemplate alloc] initWithTitle:@"LX Music"
                                                               sections:@[ fallbackSection ]];
      [controller setRootTemplate:fallback animated:NO completion:^(BOOL success, NSError *error) {
        if (!success) NSLog(@"[LXCarPlay] fallback root failed: %@", error);
      }];
    } @catch (NSException *fallbackException) {
      NSLog(@"[LXCarPlay] fallback root exception: %@", fallbackException);
    }
  }
}

'''
text = text[:root_start] + new_root + text[root_end:]

refresh_start = text.find('- (void)refreshVisibleLibrary {')
refresh_end = text.find('- (void)handleLibraryChanged:', refresh_start)
if refresh_start < 0 or refresh_end < 0:
    raise SystemExit('Unable to locate refreshVisibleLibrary')

new_refresh = r'''- (void)refreshVisibleLibrary {
  dispatch_async(dispatch_get_main_queue(), ^{
    if (self.interfaceController == nil) return;
    if (self.homeTemplate == nil) {
      [self buildRootTemplate];
      return;
    }
    @try {
      [self.homeTemplate updateSections:[self homeSections]];
    } @catch (NSException *exception) {
      NSLog(@"[LXCarPlay] home refresh exception: %@", exception);
    }
  });
}

'''
text = text[:refresh_start] + new_refresh + text[refresh_end:]

main_path.write_text(text)

# TrollStore 2.x only exists on iOS 14+, so use the modern Audio CarPlay entitlement only.
# This exactly matches the public CarPlayify/carplay-enabler entitlement model and avoids
# carrying the pre-iOS-14 playable-content entitlement into the modern scene registration.
entitlements_path = Path('ios/LxMusicMobile/LxMusicMobile.entitlements')
entitlements_path.write_text('''<?xml version="1.0" encoding="UTF-8"?>\n<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">\n<plist version="1.0">\n<dict>\n\t<key>com.apple.developer.carplay-audio</key>\n\t<true/>\n</dict>\n</plist>\n''')
