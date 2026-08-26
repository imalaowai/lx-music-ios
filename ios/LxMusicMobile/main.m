#import <UIKit/UIKit.h>
#import <MediaPlayer/MediaPlayer.h>
@import CarPlay;

#import "AppDelegate.h"

@interface LXCarPlaySceneDelegate : UIResponder <CPTemplateApplicationSceneDelegate>
@property (nonatomic, strong) CPInterfaceController *interfaceController;
@end

@implementation LXCarPlaySceneDelegate

- (NSString *)nowPlayingDetail {
  NSDictionary *info = [MPNowPlayingInfoCenter defaultCenter].nowPlayingInfo;
  NSString *title = [info[MPMediaItemPropertyTitle] isKindOfClass:[NSString class]] ? info[MPMediaItemPropertyTitle] : @"";
  NSString *artist = [info[MPMediaItemPropertyArtist] isKindOfClass:[NSString class]] ? info[MPMediaItemPropertyArtist] : @"";
  if (title.length == 0) return @"请先在手机端开始播放";
  return artist.length ? [NSString stringWithFormat:@"%@ · %@", title, artist] : title;
}

- (CPListTemplate *)rootTemplate {
  __weak typeof(self) weakSelf = self;
  CPListItem *nowPlaying = [[CPListItem alloc] initWithText:@"正在播放" detailText:[self nowPlayingDetail]];
  nowPlaying.handler = ^(id<CPSelectableListItem> selectedItem, dispatch_block_t completionBlock) {
    if (weakSelf.interfaceController != nil) {
      [weakSelf.interfaceController pushTemplate:[CPNowPlayingTemplate sharedTemplate]
                                        animated:YES
                                      completion:NULL];
    }
    if (completionBlock) completionBlock();
  };

  CPListItem *hint = [[CPListItem alloc] initWithText:@"手机端选择音乐"
                                           detailText:@"播放后可在 CarPlay、方向盘和锁屏统一控制"];
  hint.enabled = NO;

  CPListSection *section = [[CPListSection alloc] initWithItems:@[ nowPlaying, hint ]];
  return [[CPListTemplate alloc] initWithTitle:@"LX Music" sections:@[ section ]];
}

- (void)templateApplicationScene:(CPTemplateApplicationScene *)templateApplicationScene
   didConnectInterfaceController:(CPInterfaceController *)interfaceController {
  self.interfaceController = interfaceController;
  // Always provide a root template synchronously. No React Native bridge,
  // network request, database load, or playlist serialization is involved.
  [interfaceController setRootTemplate:[self rootTemplate] animated:NO completion:NULL];
}

- (void)templateApplicationScene:(CPTemplateApplicationScene *)templateApplicationScene
 didDisconnectInterfaceController:(CPInterfaceController *)interfaceController {
  self.interfaceController = nil;
}

@end

@implementation AppDelegate (LXCarPlaySceneConfiguration)

- (UISceneConfiguration *)application:(UIApplication *)application
 configurationForConnectingSceneSession:(UISceneSession *)connectingSceneSession
                              options:(UISceneConnectionOptions *)options API_AVAILABLE(ios(13.0)) {
  if ([connectingSceneSession.role isEqualToString:CPTemplateApplicationSceneSessionRoleApplication]) {
    UISceneConfiguration *configuration = [[UISceneConfiguration alloc] initWithName:@"LX Music CarPlay"
                                                                          sessionRole:connectingSceneSession.role];
    configuration.sceneClass = [CPTemplateApplicationScene class];
    configuration.delegateClass = [LXCarPlaySceneDelegate class];
    return configuration;
  }
  return nil;
}

@end

int main(int argc, char *argv[])
{
  @autoreleasepool {
    return UIApplicationMain(argc, argv, nil, NSStringFromClass([AppDelegate class]));
  }
}
