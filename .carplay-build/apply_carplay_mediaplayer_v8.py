from pathlib import Path
import plistlib
import re

main_path = Path('ios/LxMusicMobile/main.m')
project_path = Path('ios/LxMusicMobile.xcodeproj/project.pbxproj')
ent_path = Path('ios/LxMusicMobile/LxMusicMobile.entitlements')
plist_path = Path('ios/LxMusicMobile/Info.plist')

text = main_path.read_text()

# V8 deliberately does not use the CarPlay framework scene lifecycle at all.
text = text.replace('#import <CarPlay/CarPlay.h>\n', '')

scene_start = text.find('#pragma mark - Native CarPlay.framework UI (iOS 14+)')
bridge_start = text.find('#pragma mark - React Native bridge', scene_start)
if scene_start < 0 or bridge_start < 0:
    raise SystemExit('Unable to locate native CarPlay scene block')
text = text[:scene_start] + '#pragma mark - React Native bridge\n\n' + text[bridge_start + len('#pragma mark - React Native bridge'):]

# Install the MediaPlayer provider on every supported iOS version. Apple documents that
# MediaPlayer audio CarPlay apps continue to work on iOS 14+.
text = re.sub(
    r'if \(@available\(iOS 14\.0, \*\)\) \{\n\s*// iOS 14\+ is served by CarPlay\.framework / LXCarPlaySceneDelegate\.\n\s*\} else \{\n\s*dispatch_async\(dispatch_get_main_queue\(\), \^\{\n\s*\[\[LXPlayableContentCoordinator sharedCoordinator\] installIfNeeded\];\n\s*\}\);\n\s*\}',
    'dispatch_async(dispatch_get_main_queue(), ^{\n      [[LXPlayableContentCoordinator sharedCoordinator] installIfNeeded];\n    });',
    text,
    count=1,
)

text = re.sub(
    r'if \(@available\(iOS 14\.0, \*\)\) \{\n\s*// The native scene observes LXCarPlayLibraryDidChangeNotification and updates its templates\.\n\s*\} else \{\n\s*dispatch_async\(dispatch_get_main_queue\(\), \^\{\n\s*\[\[LXPlayableContentCoordinator sharedCoordinator\] installIfNeeded\];\n\s*\[\[LXPlayableContentCoordinator sharedCoordinator\] reloadLibrary\];\n\s*\}\);\n\s*\}',
    'dispatch_async(dispatch_get_main_queue(), ^{\n    [[LXPlayableContentCoordinator sharedCoordinator] installIfNeeded];\n    [[LXPlayableContentCoordinator sharedCoordinator] reloadLibrary];\n  });',
    text,
    count=1,
)

constructor_pattern = re.compile(
    r'// Keep the legacy MediaPlayer provider only for iOS 13\.x\. iOS 14\+ uses CarPlay\.framework\.\n'
    r'__attribute__\(\(constructor\)\)\n'
    r'static void LXInstallMediaPlayerCarPlayProvider\(void\) \{\n'
    r'\s*if \(@available\(iOS 14\.0, \*\)\) return;\n'
    r'\s*dispatch_async\(dispatch_get_main_queue\(\), \^\{\n'
    r'\s*\[\[LXPlayableContentCoordinator sharedCoordinator\] installIfNeeded\];\n'
    r'\s*\}\);\n'
    r'\}',
    re.M,
)
text, n = constructor_pattern.subn(
    '// V8: MediaPlayer-only CarPlay provider. No UIScene / CPTemplateApplicationScene.\n'
    '__attribute__((constructor))\n'
    'static void LXInstallMediaPlayerCarPlayProvider(void) {\n'
    '  dispatch_async(dispatch_get_main_queue(), ^{\n'
    '    [[LXPlayableContentCoordinator sharedCoordinator] installIfNeeded];\n'
    '  });\n'
    '}',
    text,
    count=1,
)
if n != 1:
    raise SystemExit('Unable to replace MediaPlayer constructor')

# Remove every AppDelegate scene-configuration category that follows the constructor.
category_start = text.find('// Dynamically return a scene configuration only for the CarPlay scene role.')
if category_start < 0:
    category_start = text.find('#pragma mark - V7 dynamic CarPlay-only scene configuration')
main_fn = text.find('int main(int argc, char *argv[])', category_start)
if category_start < 0 or main_fn < 0:
    raise SystemExit('Unable to locate scene configuration category')
text = text[:category_start] + '// V8: no UIScene configuration method is implemented anywhere.\n\n' + text[main_fn:]

# Make sure the root content tree is never empty before React Native sends its snapshot.
old_root = '''- (NSArray<NSDictionary *> *)rootEntries {\n  NSDictionary *snapshot = [[LXCarPlayStore sharedStore] snapshotCopy];\n  NSMutableArray<NSDictionary *> *entries = [NSMutableArray array];\n\n  NSArray *recent = [snapshot[@"recent"] isKindOfClass:[NSArray class]] ? snapshot[@"recent"] : @[];\n  if (recent.count > 0) {\n    [entries addObject:@{\n      @"id": @"__recent__",\n      @"name": @"最近播放",\n      @"kind": @"recent",\n      @"musics": recent,\n    }];\n  }\n\n  NSArray *lists = [snapshot[@"lists"] isKindOfClass:[NSArray class]] ? snapshot[@"lists"] : @[];\n  for (id value in lists) {\n    if ([value isKindOfClass:[NSDictionary class]]) [entries addObject:value];\n  }\n  return entries;\n}\n'''
new_root = '''- (NSArray<NSDictionary *> *)rootEntries {\n  NSDictionary *snapshot = [[LXCarPlayStore sharedStore] snapshotCopy];\n  NSMutableArray<NSDictionary *> *entries = [NSMutableArray array];\n\n  NSArray *recent = [snapshot[@"recent"] isKindOfClass:[NSArray class]] ? snapshot[@"recent"] : @[];\n  if (recent.count > 0) {\n    [entries addObject:@{\n      @"id": @"__recent__",\n      @"name": @"最近播放",\n      @"kind": @"recent",\n      @"musics": recent,\n    }];\n  }\n\n  NSArray *lists = [snapshot[@"lists"] isKindOfClass:[NSArray class]] ? snapshot[@"lists"] : @[];\n  for (id value in lists) {\n    if ([value isKindOfClass:[NSDictionary class]]) [entries addObject:value];\n  }\n\n  if (entries.count == 0) {\n    [entries addObject:@{\n      @"id": @"__loading__",\n      @"name": @"LX Music",\n      @"kind": @"loading",\n      @"musics": @[ @{\n        @"id": @"__loading_message__",\n        @"listId": @"__loading__",\n        @"name": @"正在加载音乐库",\n        @"singer": @"请先在手机端打开 LX Music",\n        @"disabled": @YES,\n      } ],\n    }];\n  }\n  return entries;\n}\n'''
if old_root not in text:
    raise SystemExit('Unable to locate rootEntries')
text = text.replace(old_root, new_root, 1)

# Loading placeholder must not trigger JS playback.
needle = '''  NSDictionary *entry = nil;\n  NSDictionary *music = [self musicAtIndexPath:indexPath rootEntry:&entry];\n  if (music == nil || entry == nil) {\n'''
replacement = '''  NSDictionary *entry = nil;\n  NSDictionary *music = [self musicAtIndexPath:indexPath rootEntry:&entry];\n  if ([music[@"disabled"] boolValue]) {\n    if (completionHandler) completionHandler(nil);\n    return;\n  }\n  if (music == nil || entry == nil) {\n'''
if needle not in text:
    raise SystemExit('Unable to locate playback handler')
text = text.replace(needle, replacement, 1)

text = text.replace('// iOS 13.x compatibility provider. iOS 14+ uses the native CarPlay.framework scene below.\n// Keeping this implementation preserves compatibility with older CarPlay systems while the phone\n// continues to use ReactNativeNavigation\'s legacy UIApplication/AppDelegate lifecycle.\n',
                    '// V8 uses the system MediaPlayer CarPlay content provider on all supported iOS versions.\n// It never opts the phone process into UIScene, preserving ReactNativeNavigation\'s original lifecycle.\n')
main_path.write_text(text)

# Remove static scene manifest entirely.
plist = plistlib.loads(plist_path.read_bytes())
plist.pop('UIApplicationSceneManifest', None)
plist_path.write_bytes(plistlib.dumps(plist, fmt=plistlib.FMT_XML, sort_keys=False))

# Preserve the original LX identity and use only the entitlement required by MediaPlayer CarPlay.
ent_path.write_text('''<?xml version="1.0" encoding="UTF-8"?>\n<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">\n<plist version="1.0">\n<dict>\n  <key>application-identifier</key>\n  <string>63VNAMT4FN.com.klxmc.music.mobile</string>\n  <key>com.apple.developer.team-identifier</key>\n  <string>63VNAMT4FN</string>\n  <key>get-task-allow</key>\n  <true/>\n  <key>com.apple.developer.playable-content</key>\n  <true/>\n</dict>\n</plist>\n''')

# Remove CarPlay.framework completely, then explicitly add MediaPlayer.framework to the app target.
project = project_path.read_text()
project = '\n'.join(line for line in project.splitlines() if 'CarPlay.framework' not in line) + '\n'

build_id = '77D8A001B4A24A5E9B5B0001'
file_id = '77D8A000B4A24A5E9B5B0001'
build_line = f'\t\t{build_id} /* MediaPlayer.framework in Frameworks */ = {{isa = PBXBuildFile; fileRef = {file_id} /* MediaPlayer.framework */; }};'
file_line = f'\t\t{file_id} /* MediaPlayer.framework */ = {{isa = PBXFileReference; lastKnownFileType = wrapper.framework; name = MediaPlayer.framework; path = System/Library/Frameworks/MediaPlayer.framework; sourceTree = SDKROOT; }};'
phase_line = f'\t\t\t\t{build_id} /* MediaPlayer.framework in Frameworks */,'
group_line = f'\t\t\t\t{file_id} /* MediaPlayer.framework */,'

anchors = [
    ('\t\t11D2C601B4A24A5E9B5B0001 /* CoreMotion.framework in Frameworks */ = {isa = PBXBuildFile; fileRef = 11D2C600B4A24A5E9B5B0001 /* CoreMotion.framework */; };', build_line),
    ('\t\t11D2C600B4A24A5E9B5B0001 /* CoreMotion.framework */ = {isa = PBXFileReference; lastKnownFileType = wrapper.framework; name = CoreMotion.framework; path = System/Library/Frameworks/CoreMotion.framework; sourceTree = SDKROOT; };', file_line),
    ('\t\t\t\t11D2C601B4A24A5E9B5B0001 /* CoreMotion.framework in Frameworks */,', phase_line),
    ('\t\t\t\t11D2C600B4A24A5E9B5B0001 /* CoreMotion.framework */,', group_line),
]
for anchor, addition in anchors:
    if addition not in project:
        if anchor not in project:
            raise SystemExit(f'Missing Xcode project anchor: {anchor}')
        project = project.replace(anchor, anchor + '\n' + addition, 1)

if project.count('MediaPlayer.framework in Frameworks') != 2:
    raise SystemExit('Unexpected MediaPlayer PBX build references')
if project.count('System/Library/Frameworks/MediaPlayer.framework') != 1:
    raise SystemExit('Unexpected MediaPlayer framework file references')
if 'CarPlay.framework' in project:
    raise SystemExit('CarPlay.framework must not be linked in V8')

project_path.write_text(project)
