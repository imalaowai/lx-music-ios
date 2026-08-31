from pathlib import Path
import plistlib

main_path = Path('ios/LxMusicMobile/main.m')
plist_path = Path('ios/LxMusicMobile/Info.plist')

text = main_path.read_text()

# V7 fixes the phone black screen by keeping the iPhone UI entirely on the legacy
# UIApplication/AppDelegate lifecycle used by ReactNativeNavigation.  CarPlay receives
# its UISceneConfiguration dynamically from AppDelegate only when a CarPlay session is requested.
# Apple explicitly supports returning CPTemplateApplicationScene configuration from
# application:configurationForConnectingSceneSession:options: instead of Info.plist.

# Remove any stale copy of our dynamic category first so the patch is idempotent.
category_marker = '#pragma mark - V7 dynamic CarPlay-only scene configuration'
if category_marker in text:
    category_start = text.index(category_marker)
    main_start = text.index('int main(int argc, char *argv[])', category_start)
    text = text[:category_start] + text[main_start:]

main_start = text.find('int main(int argc, char *argv[])')
if main_start < 0:
    raise SystemExit('Unable to locate main()')

category = r'''#pragma mark - V7 dynamic CarPlay-only scene configuration

// IMPORTANT: Do not add UIApplicationSceneManifest to Info.plist for this app.
// ReactNativeNavigation owns the iPhone UIWindow through the legacy AppDelegate lifecycle.
// The system asks this method for a configuration only when a UIScene session is requested;
// CarPlay gets CPTemplateApplicationScene while normal iPhone launch remains untouched.
@implementation AppDelegate (LXCarPlaySceneConfigurationV7)

- (UISceneConfiguration *)application:(UIApplication *)application
 configurationForConnectingSceneSession:(UISceneSession *)connectingSceneSession
                               options:(UISceneConnectionOptions *)options API_AVAILABLE(ios(13.0)) {
  if (@available(iOS 14.0, *)) {
    if ([connectingSceneSession.role isEqualToString:CPTemplateApplicationSceneSessionRoleApplication]) {
      NSLog(@"[LXCarPlay] V7 returning dynamic CarPlay scene configuration");
      UISceneConfiguration *configuration = [[UISceneConfiguration alloc]
        initWithName:@"LX Music CarPlay"
        sessionRole:connectingSceneSession.role];
      configuration.sceneClass = CPTemplateApplicationScene.class;
      configuration.delegateClass = LXCarPlaySceneDelegate.class;
      return configuration;
    }
  }

  // Defensive fallback. The phone app should not request a UIWindowScene because there is no
  // UIApplicationSceneManifest. If UIKit ever asks for another role, return a plain configuration
  // without attaching a phone Scene delegate or replacing the existing RNN window.
  return [[UISceneConfiguration alloc] initWithName:@"LX Music Legacy Phone"
                                        sessionRole:connectingSceneSession.role];
}

@end

'''
text = text[:main_start] + category + text[main_start:]
main_path.write_text(text)

# Completely remove UIApplicationSceneManifest. Merely leaving a CarPlay-only manifest can opt
# this legacy ReactNativeNavigation app into UIScene handling and produce a black iPhone window.
plist = plistlib.loads(plist_path.read_bytes())
plist.pop('UIApplicationSceneManifest', None)
plist_path.write_bytes(plistlib.dumps(plist, fmt=plistlib.FMT_XML, sort_keys=False))
