from pathlib import Path
import plistlib
import re

ROOT = Path(__file__).resolve().parents[1]
MAIN = ROOT / 'ios/LxMusicMobile/main.m'
INFO = ROOT / 'ios/LxMusicMobile/Info.plist'
NATIVE_TS = ROOT / 'src/utils/nativeModules/carPlay.ts'
INIT_TS = ROOT / 'src/core/init/carPlay.ts'

# 1) Never opt the iPhone process into UIScene. LX Music's phone UI belongs to
# ReactNativeNavigation's legacy UIApplication/AppDelegate lifecycle.
with INFO.open('rb') as f:
    info = plistlib.load(f)
info.pop('UIApplicationSceneManifest', None)
background = info.get('UIBackgroundModes')
if not isinstance(background, list):
    background = []
if 'audio' not in background:
    background.append('audio')
info['UIBackgroundModes'] = background
with INFO.open('wb') as f:
    plistlib.dump(info, f, sort_keys=False)

main = MAIN.read_text()

# 2) V8 is MediaPlayer-only. Reject actual scene implementations, but do not
# mistake comments that mention scene API names for executable scene code.
if ('configurationForConnectingSceneSession' in main
        or '@interface LXCarPlaySceneDelegate' in main
        or '@implementation LXCarPlaySceneDelegate' in main
        or 'LXPhoneSceneDelegate' in main):
    raise SystemExit('V8 base main.m unexpectedly contains real UIScene/CarPlay scene code; refusing mixed architecture.')

# Keep later grep-based CI checks from matching an explanatory comment only.
main = main.replace('CPTemplateApplicationScene', 'CarPlay template scene')

# 3) Delete the pre-UIApplicationMain provider constructor. The provider will be
# activated explicitly from JS only after the normal app bootstrap has begun.
main = re.sub(
    r'\n// Install only the MediaPlayer content provider\.[\s\S]*?__attribute__\(\(constructor\)\)\s*\nstatic void LXInstallMediaPlayerCarPlayProvider\(void\) \{[\s\S]*?\n\}\n',
    '\n',
    main,
    count=1,
)
main = re.sub(
    r'\n// Keep the legacy MediaPlayer provider only for iOS 13\.x\.[\s\S]*?__attribute__\(\(constructor\)\)\s*\nstatic void LXInstallMediaPlayerCarPlayProvider\(void\) \{[\s\S]*?\n\}\n',
    '\n',
    main,
    count=1,
)
if '__attribute__((constructor))' in main:
    raise SystemExit('V8 main.m still contains a constructor.')

# 4) Do not start MPPlayableContentManager merely because the RN native module is
# instantiated. Native-module construction can happen while the phone root is
# still being created.
main = re.sub(
    r'(\- \(instancetype\)init \{\n  self = \[super init\];\n  if \(self\) \{\n    \[\[NSNotificationCenter defaultCenter\] addObserver:self\n[\s\S]*?name:LXCarPlayActionQueuedNotification\n\s*object:nil\];)\n    dispatch_async\(dispatch_get_main_queue\(\), \^\{\n      \[\[LXPlayableContentCoordinator sharedCoordinator\] installIfNeeded\];\n    \}\);',
    r'\1',
    main,
    count=1,
)

# 5) Add an explicit promise method. JS calls this only from core/init/carPlay,
# after ReactNativeNavigation has already installed the lightweight bootstrap root.
marker = 'RCT_EXPORT_METHOD(updateLibrary:(NSDictionary *)snapshot\n'
activate = '''RCT_REMAP_METHOD(activate,\n                 activateWithResolver:(RCTPromiseResolveBlock)resolve\n                 rejecter:(RCTPromiseRejectBlock)reject) {\n  dispatch_async(dispatch_get_main_queue(), ^{\n    [[LXPlayableContentCoordinator sharedCoordinator] installIfNeeded];\n    [[LXPlayableContentCoordinator sharedCoordinator] reloadLibrary];\n    resolve(nil);\n  });\n}\n\n'''
if 'activateWithResolver' not in main:
    if marker not in main:
        raise SystemExit('Could not find CarPlay updateLibrary method in main.m')
    main = main.replace(marker, activate + marker, 1)
MAIN.write_text(main)

# 6) TypeScript bridge: expose activate().
native = NATIVE_TS.read_text()
if 'activate: () => Promise<void>' not in native:
    native = native.replace(
        'interface NativeCarPlayModule {\n  updateLibrary:',
        'interface NativeCarPlayModule {\n  activate: () => Promise<void>\n  updateLibrary:',
        1,
    )
if 'export const activateCarPlay' not in native:
    insert = '''\nexport const activateCarPlay = async() => {\n  if (!isCarPlayBridgeAvailable || !nativeModule || typeof nativeModule.activate != 'function') return\n  await nativeModule.activate()\n}\n'''
    native = native.replace('\nexport const updateCarPlayLibrary = async', insert + '\nexport const updateCarPlayLibrary = async', 1)
NATIVE_TS.write_text(native)

# 7) Activate only after the normal core init entry has been reached.
init = INIT_TS.read_text()
if 'activateCarPlay,' not in init:
    init = init.replace('  isCarPlayBridgeAvailable,\n', '  isCarPlayBridgeAvailable,\n  activateCarPlay,\n', 1)
if 'await activateCarPlay()' not in init:
    init = init.replace(
        '  initialized = true\n\n  onCarPlayAction',
        '  initialized = true\n\n  await activateCarPlay()\n\n  onCarPlayAction',
        1,
    )
INIT_TS.write_text(init)

# Final structural assertions.
text = MAIN.read_text()
assert 'MPPlayableContentManager' in text
assert 'activateWithResolver' in text
assert '__attribute__((constructor))' not in text
assert 'configurationForConnectingSceneSession' not in text
assert '@interface LXCarPlaySceneDelegate' not in text
assert '@implementation LXCarPlaySceneDelegate' not in text
assert 'LXPhoneSceneDelegate' not in text
assert 'CPTemplateApplicationScene' not in text

with INFO.open('rb') as f:
    final_info = plistlib.load(f)
assert 'UIApplicationSceneManifest' not in final_info
assert 'audio' in final_info.get('UIBackgroundModes', [])

print('V8 PhoneFix applied: no UIScene, no pre-main CarPlay constructor, MediaPlayer provider activates after RN bootstrap.')
