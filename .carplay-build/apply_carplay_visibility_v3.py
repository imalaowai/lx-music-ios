from pathlib import Path

path = Path('ios/LxMusicMobile/main.m')
text = path.read_text()

old_init = '''    if (@available(iOS 14.0, *)) {\n      // iOS 14+ is served by CarPlay.framework / LXCarPlaySceneDelegate.\n    } else {\n      dispatch_async(dispatch_get_main_queue(), ^{\n        [[LXPlayableContentCoordinator sharedCoordinator] installIfNeeded];\n      });\n    }\n'''
new_init = '''    // Register the legacy MediaPlayer CarPlay provider on every supported iOS version.\n    // Apple explicitly allows audio apps to use CarPlay.framework, MediaPlayer, or both.\n    // Keeping both paths active improves compatibility with vehicle/head-unit profiles that\n    // do not reliably surface the modern CPTemplateApplicationScene catalog entry.\n    dispatch_async(dispatch_get_main_queue(), ^{\n      [[LXPlayableContentCoordinator sharedCoordinator] installIfNeeded];\n    });\n'''
if new_init not in text:
    if old_init not in text:
        raise SystemExit('Missing CarPlayModule init compatibility anchor')
    text = text.replace(old_init, new_init, 1)

old_update = '''  [[LXCarPlayStore sharedStore] updateSnapshot:snapshot];\n  if (@available(iOS 14.0, *)) {\n    // The native scene observes LXCarPlayLibraryDidChangeNotification and updates its templates.\n  } else {\n    dispatch_async(dispatch_get_main_queue(), ^{\n      [[LXPlayableContentCoordinator sharedCoordinator] installIfNeeded];\n      [[LXPlayableContentCoordinator sharedCoordinator] reloadLibrary];\n    });\n  }\n  resolve(nil);\n'''
new_update = '''  [[LXCarPlayStore sharedStore] updateSnapshot:snapshot];\n  // Keep the MediaPlayer catalog synchronized even when the modern CarPlay scene is active.\n  // The CPTemplateApplicationScene also observes LXCarPlayLibraryDidChangeNotification, so\n  // both native entry points see the same snapshot without creating a second player.\n  dispatch_async(dispatch_get_main_queue(), ^{\n    [[LXPlayableContentCoordinator sharedCoordinator] installIfNeeded];\n    [[LXPlayableContentCoordinator sharedCoordinator] reloadLibrary];\n  });\n  resolve(nil);\n'''
if new_update not in text:
    if old_update not in text:
        raise SystemExit('Missing updateLibrary compatibility anchor')
    text = text.replace(old_update, new_update, 1)

old_constructor = '''// Keep the legacy MediaPlayer provider only for iOS 13.x. iOS 14+ uses CarPlay.framework.\n__attribute__((constructor))\nstatic void LXInstallMediaPlayerCarPlayProvider(void) {\n  if (@available(iOS 14.0, *)) return;\n  dispatch_async(dispatch_get_main_queue(), ^{\n    [[LXPlayableContentCoordinator sharedCoordinator] installIfNeeded];\n  });\n}\n'''
new_constructor = '''// Register the legacy MediaPlayer provider on all supported iOS versions as a compatibility\n// companion to the modern CarPlay.framework scene. It only publishes the same audio library\n// and forwards playback into the existing React Native player.\n__attribute__((constructor))\nstatic void LXInstallMediaPlayerCarPlayProvider(void) {\n  dispatch_async(dispatch_get_main_queue(), ^{\n    [[LXPlayableContentCoordinator sharedCoordinator] installIfNeeded];\n  });\n}\n'''
if new_constructor not in text:
    if old_constructor not in text:
        raise SystemExit('Missing MediaPlayer constructor compatibility anchor')
    text = text.replace(old_constructor, new_constructor, 1)

path.write_text(text)
