from pathlib import Path
import plistlib

main_path = Path('ios/LxMusicMobile/main.m')
plist_path = Path('ios/LxMusicMobile/Info.plist')
text = main_path.read_text()

# V6 intentionally preserves the original ReactNativeNavigation phone lifecycle.
marker = '// Dynamically return a scene configuration only for the CarPlay scene role.'
start = text.find(marker)
main_fn = text.find('int main(int argc, char *argv[])', start)
if start < 0 or main_fn < 0:
    raise SystemExit('Unable to locate V4 phone-scene compatibility block')
text = text[:start] + '// V6: phone UI remains on the original UIApplication/AppDelegate lifecycle.\n\n' + text[main_fn:]

# Replace the CarPlay startup root with a static CPListTemplate that does not depend on RN or cached data.
root_start = text.find('- (void)buildRootTemplate {')
root_end = text.find('- (void)refreshVisibleLibrary {', root_start)
if root_start < 0 or root_end < 0:
    raise SystemExit('Unable to locate V4 root block')

new_root = r'''- (CPListTemplate *)v6SafeRootTemplate {
  __weak typeof(self) weakSelf = self;

  CPListItem *statusItem = [[CPListItem alloc] initWithText:@"LX Music"
                                                detailText:@"CarPlay 已连接"
                                                     image:nil];

  CPListItem *nowPlayingItem = [[CPListItem alloc] initWithText:@"正在播放"
                                                    detailText:@"打开系统播放界面"
                                                         image:nil];
  nowPlayingItem.handler = ^(id<CPSelectableListItem> selectableItem, void (^completionHandler)(void)) {
    __strong typeof(weakSelf) self = weakSelf;
    if (self != nil) [self showNowPlaying];
    if (completionHandler) completionHandler();
  };

  CPListItem *libraryItem = [[CPListItem alloc] initWithText:@"音乐库"
                                                 detailText:@"歌单与最近播放"
                                                      image:nil];
  libraryItem.handler = ^(id<CPSelectableListItem> selectableItem, void (^completionHandler)(void)) {
    __strong typeof(weakSelf) self = weakSelf;
    if (self != nil) {
      CPListTemplate *template = [[CPListTemplate alloc] initWithTitle:@"音乐库"
                                                              sections:[self librarySections]];
      template.emptyViewTitleVariants = @[ @"LX Music" ];
      template.emptyViewSubtitleVariants = @[ @"请先在手机端打开一次 LX Music 完成音乐库同步" ];
      [self pushTemplate:template];
    }
    if (completionHandler) completionHandler();
  };

  CPListItem *refreshItem = [[CPListItem alloc] initWithText:@"刷新音乐库"
                                                 detailText:@"从手机端重新同步"
                                                      image:nil];
  refreshItem.handler = ^(id<CPSelectableListItem> selectableItem, void (^completionHandler)(void)) {
    [[LXCarPlayStore sharedStore] enqueueAction:@{ @"type": @"refresh-library" }];
    if (completionHandler) completionHandler();
  };

  CPListSection *section = [[CPListSection alloc] initWithItems:@[
    statusItem,
    nowPlayingItem,
    libraryItem,
    refreshItem,
  ]];
  return [[CPListTemplate alloc] initWithTitle:@"LX Music" sections:@[ section ]];
}

- (void)buildRootTemplate {
  CPInterfaceController *controller = self.interfaceController;
  if (controller == nil) return;

  self.tabBarTemplate = nil;
  self.libraryTemplate = nil;
  self.playlistsTemplate = nil;
  self.homeTemplate = [self v6SafeRootTemplate];

  @try {
    [controller setRootTemplate:self.homeTemplate animated:NO completion:^(BOOL success, NSError *error) {
      if (success) {
        NSLog(@"[LXCarPlay] V6 safe root active");
      } else {
        NSLog(@"[LXCarPlay] V6 safe root failed: %@", error);
      }
    }];
  } @catch (NSException *exception) {
    NSLog(@"[LXCarPlay] V6 safe root exception: %@", exception);
  }
}

'''
text = text[:root_start] + new_root + text[root_end:]

# Never replace/update the root automatically while RN is starting or refreshing its snapshot.
refresh_start = text.find('- (void)refreshVisibleLibrary {')
refresh_end = text.find('- (void)handleLibraryChanged:', refresh_start)
if refresh_start < 0 or refresh_end < 0:
    raise SystemExit('Unable to locate V4 refresh block')
new_refresh = r'''- (void)refreshVisibleLibrary {
  NSLog(@"[LXCarPlay] V6 library snapshot updated");
}

'''
text = text[:refresh_start] + new_refresh + text[refresh_end:]

# Make the connection callback do only one UI operation: set the static root immediately.
connect_start = text.find('- (void)templateApplicationScene:(CPTemplateApplicationScene *)templateApplicationScene\n   didConnectInterfaceController:')
connect_end = text.find('- (void)templateApplicationScene:(CPTemplateApplicationScene *)templateApplicationScene\ndidDisconnectInterfaceController:', connect_start)
if connect_start < 0 or connect_end < 0:
    raise SystemExit('Unable to locate V4 CarPlay connect block')
new_connect = r'''- (void)templateApplicationScene:(CPTemplateApplicationScene *)templateApplicationScene
   didConnectInterfaceController:(CPInterfaceController *)interfaceController {
  NSLog(@"[LXCarPlay] V6 scene connected");
  self.interfaceController = interfaceController;

  [[NSNotificationCenter defaultCenter] removeObserver:self
                                                  name:LXCarPlayLibraryDidChangeNotification
                                                object:nil];
  [[NSNotificationCenter defaultCenter] addObserver:self
                                           selector:@selector(handleLibraryChanged:)
                                               name:LXCarPlayLibraryDidChangeNotification
                                             object:nil];

  // Do not wait for React Native, cached library data, Now Playing or a TabBar.
  [self buildRootTemplate];

  dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(1000 * NSEC_PER_MSEC)),
                 dispatch_get_main_queue(), ^{
    if (self.interfaceController == interfaceController) {
      [[LXCarPlayStore sharedStore] enqueueAction:@{ @"type": @"refresh-library" }];
    }
  });
}

'''
text = text[:connect_start] + new_connect + text[connect_end:]
main_path.write_text(text)

# Keep only Apple's CarPlay scene role. Do not opt the phone UI into UIWindowScene.
plist = plistlib.loads(plist_path.read_bytes())
manifest = plist.setdefault('UIApplicationSceneManifest', {})
manifest['UIApplicationSupportsMultipleScenes'] = True
configs = manifest.setdefault('UISceneConfigurations', {})
configs.pop('UIWindowSceneSessionRoleApplication', None)
configs['CPTemplateApplicationSceneSessionRoleApplication'] = [{
    'UISceneClassName': 'CPTemplateApplicationScene',
    'UISceneConfigurationName': 'LX Music CarPlay',
    'UISceneDelegateClassName': 'LXCarPlaySceneDelegate',
}]
manifest['UISceneConfigurations'] = configs
plist['UIApplicationSceneManifest'] = manifest
plist_path.write_bytes(plistlib.dumps(plist, fmt=plistlib.FMT_XML, sort_keys=False))
