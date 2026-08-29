from pathlib import Path

path = Path('ios/LxMusicMobile.xcodeproj/project.pbxproj')
text = path.read_text()
insertions = [
    ('\t\t11D2C601B4A24A5E9B5B0001 /* CoreMotion.framework in Frameworks */ = {isa = PBXBuildFile; fileRef = 11D2C600B4A24A5E9B5B0001 /* CoreMotion.framework */; };', '\t\t77C4A001C4A24A5E9B5B0001 /* CarPlay.framework in Frameworks */ = {isa = PBXBuildFile; fileRef = 77C4A000C4A24A5E9B5B0001 /* CarPlay.framework */; };'),
    ('\t\t11D2C600B4A24A5E9B5B0001 /* CoreMotion.framework */ = {isa = PBXFileReference; lastKnownFileType = wrapper.framework; name = CoreMotion.framework; path = System/Library/Frameworks/CoreMotion.framework; sourceTree = SDKROOT; };', '\t\t77C4A000C4A24A5E9B5B0001 /* CarPlay.framework */ = {isa = PBXFileReference; lastKnownFileType = wrapper.framework; name = CarPlay.framework; path = System/Library/Frameworks/CarPlay.framework; sourceTree = SDKROOT; };'),
    ('\t\t\t\t11D2C601B4A24A5E9B5B0001 /* CoreMotion.framework in Frameworks */,', '\t\t\t\t77C4A001C4A24A5E9B5B0001 /* CarPlay.framework in Frameworks */,'),
    ('\t\t\t\t11D2C600B4A24A5E9B5B0001 /* CoreMotion.framework */,', '\t\t\t\t77C4A000C4A24A5E9B5B0001 /* CarPlay.framework */,'),
]
for anchor, addition in insertions:
    if addition not in text:
        if anchor not in text:
            raise SystemExit(f'Missing Xcode project anchor: {anchor}')
        text = text.replace(anchor, anchor + '\n' + addition, 1)
path.write_text(text)
