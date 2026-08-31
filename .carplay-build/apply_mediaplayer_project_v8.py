from pathlib import Path

path = Path('ios/LxMusicMobile.xcodeproj/project.pbxproj')
text = path.read_text()

build_id = '77D8A001B4A24A5E9B5B0001'
file_id = '77D8A000B4A24A5E9B5B0001'

build_line = f'\t\t{build_id} /* MediaPlayer.framework in Frameworks */ = {{isa = PBXBuildFile; fileRef = {file_id} /* MediaPlayer.framework */; }};'
file_line = f'\t\t{file_id} /* MediaPlayer.framework */ = {{isa = PBXFileReference; lastKnownFileType = wrapper.framework; name = MediaPlayer.framework; path = System/Library/Frameworks/MediaPlayer.framework; sourceTree = SDKROOT; }};'
phase_line = f'\t\t\t\t{build_id} /* MediaPlayer.framework in Frameworks */,'
group_line = f'\t\t\t\t{file_id} /* MediaPlayer.framework */,'

anchors = [
    (
        '\t\t11D2C601B4A24A5E9B5B0001 /* CoreMotion.framework in Frameworks */ = {isa = PBXBuildFile; fileRef = 11D2C600B4A24A5E9B5B0001 /* CoreMotion.framework */; };',
        build_line,
    ),
    (
        '\t\t11D2C600B4A24A5E9B5B0001 /* CoreMotion.framework */ = {isa = PBXFileReference; lastKnownFileType = wrapper.framework; name = CoreMotion.framework; path = System/Library/Frameworks/CoreMotion.framework; sourceTree = SDKROOT; };',
        file_line,
    ),
    (
        '\t\t\t\t11D2C601B4A24A5E9B5B0001 /* CoreMotion.framework in Frameworks */,',
        phase_line,
    ),
    (
        '\t\t\t\t11D2C600B4A24A5E9B5B0001 /* CoreMotion.framework */,',
        group_line,
    ),
]

for anchor, addition in anchors:
    if addition not in text:
        if anchor not in text:
            raise SystemExit(f'Missing Xcode project anchor: {anchor}')
        text = text.replace(anchor, anchor + '\n' + addition, 1)

if text.count('MediaPlayer.framework in Frameworks') != 2:
    raise SystemExit('Unexpected MediaPlayer PBX build references')
if text.count('System/Library/Frameworks/MediaPlayer.framework') != 1:
    raise SystemExit('Unexpected MediaPlayer framework file references')
if 'CarPlay.framework' in text:
    raise SystemExit('CarPlay.framework must not be linked in V8')

path.write_text(text)
