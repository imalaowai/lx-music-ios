#!/bin/bash
set -euo pipefail
ROOT_DIR="$(cd "$(dirname "$0")/../.." && pwd)"
cd "$ROOT_DIR"
python3 OwnUI/scripts/prepare.py
python3 -m venv build/own-ui/brand-venv
build/own-ui/brand-venv/bin/pip install --quiet Pillow==11.3.0
build/own-ui/brand-venv/bin/python OwnUI/Brand/generate.py
mkdir -p build/own-ui/brand
xcrun actool OwnUI/Brand/Images.xcassets --compile build/own-ui/brand --platform iphoneos --minimum-deployment-target 15.0 --target-device iphone --target-device ipad --app-icon AppIcon --output-partial-info-plist build/own-ui/brand/BrandInfo.plist --output-format human-readable-text
mkdir -p build/own-ui/include/React build/own-ui/objects
python3 - <<'PY'
import pathlib
dest=pathlib.Path('build/own-ui/include/React')
for p in pathlib.Path('node_modules/react-native/React').rglob('*.h'):
    target=dest/p.name
    if not target.exists():target.symlink_to(p.resolve())
PY
SDK=$(xcrun --sdk iphoneos --show-sdk-path)
for SOURCE_PATH in FullReference/Sources/LXFullLibrary.m FullReference/Sources/LXFullCarPlay.m OwnUI/Sources/LXOwnUIBridge.m OwnUI/Sources/LXAudioRouteSafety.m OwnUI/Sources/LXNowPlayingCoordinator.m; do
  OBJECT_NAME="$(basename "$SOURCE_PATH" .m)"
  xcrun clang -c -arch arm64 -isysroot "$SDK" -miphoneos-version-min=15.0 -fobjc-arc -fblocks -DLX_OWN_UI=1 -I build/own-ui/include -I FullReference/Sources -I node_modules/react-native/ReactCommon/yoga "$SOURCE_PATH" -o "build/own-ui/objects/$OBJECT_NAME.o"
done
xcrun swiftc -emit-library -O -whole-module-optimization -module-name LXOwnUI -target arm64-apple-ios15.0 -sdk "$SDK" -D LX_OWN_UI \
  NativeCompanion/Sources/Core.swift NativeCompanion/Sources/API.swift NativeCompanion/Sources/Room.swift NativeCompanion/Sources/LocalEngine.swift NativeCompanion/Sources/MusicLibrary.swift NativeCompanion/Sources/WebController.swift \
  OwnUI/Sources/Player.swift OwnUI/Sources/ReferenceAudio.swift OwnUI/Sources/OwnUIRoot.swift build/own-ui/objects/*.o \
  -framework Foundation -framework UIKit -framework WebKit -framework AVFoundation -framework MediaPlayer -framework CarPlay -framework JavaScriptCore -framework Security -framework UniformTypeIdentifiers -framework ImageIO \
  -Xlinker -undefined -Xlinker dynamic_lookup -Xlinker -install_name -Xlinker @executable_path/Frameworks/LXFullCarPlay.dylib -o build/own-ui/LXFullCarPlay.dylib
codesign --force --sign - build/own-ui/LXFullCarPlay.dylib
node node_modules/react-native/cli.js bundle --platform ios --dev false --entry-file OwnUI/index.js --bundle-output build/own-ui/main.js --assets-dest build/own-ui --reset-cache
node_modules/react-native/sdks/hermesc/osx-bin/hermesc -O -emit-binary -out build/own-ui/main.jsbundle build/own-ui/main.js
python3 - <<'PY'
import hashlib,json,pathlib,struct,zipfile
d=pathlib.Path('build/own-ui');b=(d/'main.jsbundle').read_bytes()
assert struct.unpack_from('<I',b,8)[0]==96
metadata={'source':'Own local UI, rooms and chat with reference native audio','ownUI':True,'hermesVersion':96,'jsSha256':hashlib.sha256(b).hexdigest(),'version':'1.9.8','build':'91','minimumOS':'15.0','sourceCommit':__import__('subprocess').check_output(['git','rev-parse','HEAD'],text=True).strip()}
(d/'components.json').write_text(json.dumps(metadata,indent=2)+'\n')
with zipfile.ZipFile(d/'LX-OwnUI-Native-Components.zip','w',compression=zipfile.ZIP_DEFLATED,compresslevel=9) as z:
    for name in ['main.jsbundle','LXFullCarPlay.dylib','components.json']:z.write(d/name,name)
    for p in (d/'brand').iterdir():
        if p.is_file():z.write(p,'OwnUIBrand/'+p.name)
    for p in (d/'resources').iterdir():z.write(p,'OwnUIResources/'+p.name)
    for p in (d/'assets').rglob('*') if (d/'assets').is_dir() else []:
        if p.is_file():z.write(p,p.relative_to(d).as_posix())
print(json.dumps({'componentBytes':(d/'LX-OwnUI-Native-Components.zip').stat().st_size,'javascriptBytes':len(b),'nativeModuleBytes':(d/'LXFullCarPlay.dylib').stat().st_size}))
PY
