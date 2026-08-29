from pathlib import Path

path = Path('ios/LxMusicMobile/main.m')
text = path.read_text()

# 1) NativeEventEmitter invokes startObserving while JS is still installing the
# listener. Flushing synchronously can drain a cold-start CarPlay play action
# before JavaScript can receive it. Defer one main-queue turn.
old_observing = '''- (void)startObserving {\n  self.hasJSListeners = YES;\n  [self flushQueuedActions];\n}\n'''
new_observing = '''- (void)startObserving {\n  self.hasJSListeners = YES;\n  __weak typeof(self) weakSelf = self;\n  dispatch_async(dispatch_get_main_queue(), ^{\n    __strong typeof(weakSelf) self = weakSelf;\n    if (self == nil || !self.hasJSListeners) return;\n    [self flushQueuedActions];\n  });\n}\n'''
if new_observing not in text:
    if old_observing not in text:
        raise SystemExit('Missing CarPlay startObserving anchor')
    text = text.replace(old_observing, new_observing, 1)

# 2) A phone UIWindowScene can be connected before ReactNativeNavigation has
# installed its root controller. Never expose a key/visible rootless UIWindow;
# use a system-background placeholder which RNN can replace normally.
old_connect = '''  self.window = window;\n  [window makeKeyAndVisible];\n}\n\n- (void)sceneDidBecomeActive:(UIScene *)scene API_AVAILABLE(ios(13.0)) {\n  [self.window makeKeyAndVisible];\n}\n'''
new_connect = '''  self.window = window;\n  if (window.rootViewController == nil) {\n    UIViewController *placeholder = [[UIViewController alloc] init];\n    placeholder.view.backgroundColor = UIColor.systemBackgroundColor;\n    window.rootViewController = placeholder;\n  }\n  [window makeKeyAndVisible];\n}\n\n- (void)sceneDidBecomeActive:(UIScene *)scene API_AVAILABLE(ios(13.0)) {\n  if (self.window.rootViewController == nil) {\n    UIViewController *placeholder = [[UIViewController alloc] init];\n    placeholder.view.backgroundColor = UIColor.systemBackgroundColor;\n    self.window.rootViewController = placeholder;\n  }\n  [self.window makeKeyAndVisible];\n}\n'''
if new_connect not in text:
    if old_connect not in text:
        raise SystemExit('Missing LXPhoneSceneDelegate window anchor')
    text = text.replace(old_connect, new_connect, 1)

path.write_text(text)
