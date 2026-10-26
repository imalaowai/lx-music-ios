#!/bin/bash
set -euo pipefail
ROOT_DIR="$(cd "$(dirname "$0")/../.." && pwd)"
cd "$ROOT_DIR"
SDK=$(xcrun --sdk iphonesimulator --show-sdk-path)
HOST_DIR=build/own-ui/LXOwnHost.app
mkdir -p "$HOST_DIR"
cp build/own-ui/resources/* "$HOST_DIR/"
python3 -c "import base64,pathlib;pathlib.Path('build/own-ui/LXOwnHost.app/local-audio.flac').write_bytes(base64.b64decode(pathlib.Path('OwnUI/Tests/local-audio.flac.base64').read_text()))"
python3 - <<'PY'
import pathlib,plistlib
info={'CFBundleIdentifier':'net.minyue.lxownui.verify','CFBundleExecutable':'LXOwnHost','CFBundleName':'LXOwnHost','CFBundleDisplayName':'栖页音乐验证','CFBundlePackageType':'APPL','CFBundleVersion':'90','CFBundleShortVersionString':'1.9.7','MinimumOSVersion':'15.0','LSRequiresIPhoneOS':True,'UIDeviceFamily':[1,2],'UILaunchScreen':{},'UIApplicationSceneManifest':{'UIApplicationSupportsMultipleScenes':False,'UISceneConfigurations':{'UIWindowSceneSessionRoleApplication':[{'UISceneConfigurationName':'Phone'}]}},'NSAppTransportSecurity':{'NSAllowsLocalNetworking':True}}
pathlib.Path('build/own-ui/LXOwnHost.app/Info.plist').write_bytes(plistlib.dumps(info))
PY
xcrun clang -c -arch "$(uname -m)" -isysroot "$SDK" -mios-simulator-version-min=15.0 -fobjc-arc OwnUI/Tests/PhoneLookup.m -o build/own-ui/phone-lookup.o
xcrun clang -c -target "$(uname -m)-apple-ios15.0-simulator" -isysroot "$SDK" -fobjc-arc -fblocks OwnUI/Sources/LXAudioRouteSafety.m -o build/own-ui/audio-route-safety.o
xcrun clang -c -target "$(uname -m)-apple-ios15.0-simulator" -isysroot "$SDK" -fobjc-arc -fblocks OwnUI/Sources/LXNowPlayingCoordinator.m -o build/own-ui/now-playing.o
xcrun swiftc -emit-executable -O -module-name LXOwnHost -target "$(uname -m)-apple-ios15.0-simulator" -sdk "$SDK" -D LX_OWN_UI -import-objc-header OwnUI/Tests/PhoneLookup.h \
  NativeCompanion/Sources/Core.swift NativeCompanion/Sources/API.swift NativeCompanion/Sources/Room.swift NativeCompanion/Sources/LocalEngine.swift NativeCompanion/Sources/MusicLibrary.swift NativeCompanion/Sources/WebController.swift \
  OwnUI/Sources/Player.swift OwnUI/Sources/ReferenceAudio.swift OwnUI/Sources/OwnUIRoot.swift OwnUI/Tests/PhoneHost.swift OwnUI/Tests/OfflinePlayback.swift OwnUI/Tests/PlayerRouteTests.swift build/own-ui/phone-lookup.o build/own-ui/audio-route-safety.o build/own-ui/now-playing.o \
  -framework Foundation -framework UIKit -framework WebKit -framework AVFoundation -framework MediaPlayer -framework CarPlay -framework JavaScriptCore -framework Security -framework UniformTypeIdentifiers -framework ImageIO -o "$HOST_DIR/LXOwnHost"
codesign --force --sign - "$HOST_DIR"
DEVICE_ID=$(xcrun simctl list devices available --json | python3 -c 'import json,sys;d=json.load(sys.stdin);print(next(v["udid"] for group in d["devices"].values() for v in group if v["name"].startswith("iPhone")))')
xcrun simctl boot "$DEVICE_ID" || true
xcrun simctl bootstatus "$DEVICE_ID" -b
xcrun simctl install "$DEVICE_ID" "$HOST_DIR"
xcrun simctl launch "$DEVICE_ID" net.minyue.lxownui.verify
CONTAINER_DIR=$(xcrun simctl get_app_container "$DEVICE_ID" net.minyue.lxownui.verify data)
for attempt in $(seq 1 30); do
  if test -f "$CONTAINER_DIR/Documents/LX-OwnUI-Ready.json" && test -f "$CONTAINER_DIR/Documents/LX-Offline-Playback.json" && test -f "$CONTAINER_DIR/Documents/LX-Player-Route-Checks.json"; then break; fi
  sleep 2
done
xcrun simctl io "$DEVICE_ID" screenshot build/own-ui/own-phone-launch.png
if test -f "$CONTAINER_DIR/Documents/LX-OwnUI-Handshake.json"; then
  cat "$CONTAINER_DIR/Documents/LX-OwnUI-Handshake.json"
  cp "$CONTAINER_DIR/Documents/LX-OwnUI-Handshake.json" build/own-ui/own-phone-handshake.json
fi
if ! test -f "$CONTAINER_DIR/Documents/LX-OwnUI-Ready.json"; then
  xcrun simctl spawn "$DEVICE_ID" log show --last 2m --style compact --predicate 'process == "LXOwnHost"' > build/own-ui/own-phone-runtime.log || true
fi
if test -f "$CONTAINER_DIR/Documents/LX-Offline-Checkpoint.json"; then
  cat "$CONTAINER_DIR/Documents/LX-Offline-Checkpoint.json"
  cp "$CONTAINER_DIR/Documents/LX-Offline-Checkpoint.json" build/own-ui/offline-checkpoint.json
fi
cat "$CONTAINER_DIR/Documents/LX-OwnUI-Ready.json"
cp "$CONTAINER_DIR/Documents/LX-OwnUI-Ready.json" build/own-ui/own-phone-ready.json
cp "$CONTAINER_DIR/Documents/LX-Offline-Playback.json" build/own-ui/offline-playback.json
cp "$CONTAINER_DIR/Documents/LX-Player-Route-Checks.json" build/own-ui/player-route-checks.json
cat build/own-ui/player-route-checks.json
python3 - <<'PY'
import json,pathlib
d=json.loads(pathlib.Path('build/own-ui/own-phone-ready.json').read_text())
assert d['ready'] and d['phoneUI']=='own-local-ui'
assert d['navigation']==['首页','我的歌单','一起听','我的']
assert d['roomChat'] and d['mine'] and d['downloads']
offline=json.loads(pathlib.Path('build/own-ui/offline-playback.json').read_text());assert all(offline.values()),offline
routes=json.loads(pathlib.Path('build/own-ui/player-route-checks.json').read_text());assert all(value is True for value in routes.values()),routes
PY
