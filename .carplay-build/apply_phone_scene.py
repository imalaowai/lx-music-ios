from pathlib import Path

path = Path('ios/LxMusicMobile/main.m')
text = path.read_text()
marker = '@implementation AppDelegate (LXCarPlaySceneConfiguration)\n'
phone_scene = '''@interface LXPhoneSceneDelegate : UIResponder <UIWindowSceneDelegate>\n@property (nonatomic, strong, nullable) UIWindow *window;\n@end\n\n@implementation LXPhoneSceneDelegate\n\n- (void)scene:(UIScene *)scene\nwillConnectToSession:(UISceneSession *)session\n        options:(UISceneConnectionOptions *)connectionOptions API_AVAILABLE(ios(13.0)) {\n  if (![scene isKindOfClass:[UIWindowScene class]]) return;\n\n  AppDelegate *appDelegate = (AppDelegate *)UIApplication.sharedApplication.delegate;\n  UIWindowScene *windowScene = (UIWindowScene *)scene;\n\n  UIWindow *window = appDelegate.window;\n  if (window == nil) {\n    window = [[UIWindow alloc] initWithWindowScene:windowScene];\n    appDelegate.window = window;\n  } else if (window.windowScene != windowScene) {\n    window.windowScene = windowScene;\n  }\n\n  self.window = window;\n  [window makeKeyAndVisible];\n}\n\n- (void)sceneDidBecomeActive:(UIScene *)scene API_AVAILABLE(ios(13.0)) {\n  [self.window makeKeyAndVisible];\n}\n\n@end\n\n'''
if phone_scene not in text:
    if marker not in text:
        raise SystemExit('Missing AppDelegate CarPlay scene category marker')
    text = text.replace(marker, phone_scene + marker, 1)

old = '''  // A normal phone scene is never requested because this project intentionally has no phone\n  // UIApplicationSceneManifest. Returning a plain configuration here is a defensive fallback.\n  return [[UISceneConfiguration alloc] initWithName:@"LX Music Legacy Phone"\n                                        sessionRole:connectingSceneSession.role];\n'''
new = '''  if ([connectingSceneSession.role isEqualToString:UIWindowSceneSessionRoleApplication]) {\n    UISceneConfiguration *configuration = [[UISceneConfiguration alloc] initWithName:@"LX Music Phone"\n                                                                         sessionRole:connectingSceneSession.role];\n    configuration.sceneClass = UIWindowScene.class;\n    configuration.delegateClass = LXPhoneSceneDelegate.class;\n    return configuration;\n  }\n\n  return [[UISceneConfiguration alloc] initWithName:@"LX Music Fallback"\n                                        sessionRole:connectingSceneSession.role];\n'''
if old in text:
    text = text.replace(old, new, 1)
elif new not in text:
    raise SystemExit('Missing legacy phone scene fallback block')

path.write_text(text)
