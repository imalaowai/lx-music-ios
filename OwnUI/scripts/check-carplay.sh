#!/bin/bash
set -euo pipefail
ROOT_DIR="$(cd "$(dirname "$0")/../.." && pwd)"
cd "$ROOT_DIR"
SDK=$(xcrun --sdk iphonesimulator --show-sdk-path)
HOST_DIR=build/own-ui/LXCarPlayTests.app
mkdir -p "$HOST_DIR"
python3 - <<'PY'
import pathlib,plistlib
info={'CFBundleIdentifier':'net.minyue.lxcarplay.verify','CFBundleExecutable':'LXCarPlayTests','CFBundleName':'LXCarPlayTests','CFBundlePackageType':'APPL','CFBundleVersion':'91','CFBundleShortVersionString':'1.9.8','MinimumOSVersion':'15.0','LSRequiresIPhoneOS':True,'UIDeviceFamily':[1,2],'UILaunchScreen':{}}
pathlib.Path('build/own-ui/LXCarPlayTests.app/Info.plist').write_bytes(plistlib.dumps(info))
PY
xcrun clang -target "$(uname -m)-apple-ios15.0-simulator" -isysroot "$SDK" -fobjc-arc -fblocks -DLX_OWN_UI=1 -I FullReference/Sources \
  FullReference/Tests/carplay.m FullReference/Sources/LXFullLibrary.m -framework Foundation -framework UIKit -framework CarPlay -framework MediaPlayer -framework ImageIO -framework CoreGraphics -o "$HOST_DIR/LXCarPlayTests"
codesign --force --sign - "$HOST_DIR"
DEVICE_ID=$(xcrun simctl list devices available --json | python3 -c 'import json,sys;d=json.load(sys.stdin);print(next(v["udid"] for g in d["devices"].values() for v in g if v["name"].startswith("iPhone")))')
xcrun simctl boot "$DEVICE_ID" || true
xcrun simctl bootstatus "$DEVICE_ID" -b
xcrun simctl install "$DEVICE_ID" "$HOST_DIR"
xcrun simctl launch "$DEVICE_ID" net.minyue.lxcarplay.verify
CONTAINER_DIR=$(xcrun simctl get_app_container "$DEVICE_ID" net.minyue.lxcarplay.verify data)
for attempt in $(seq 1 20); do
  if test -f "$CONTAINER_DIR/Documents/carplay-lifecycle.json"; then break; fi
  sleep 1
done
cp "$CONTAINER_DIR/Documents/carplay-lifecycle.json" build/own-ui/carplay-lifecycle.json
cat build/own-ui/carplay-lifecycle.json
python3 - <<'PY'
import json,pathlib
value=json.loads(pathlib.Path('build/own-ui/carplay-lifecycle.json').read_text())
assert len(value)>=19 and all(v is True for v in value.values()),value
PY
xcrun simctl terminate "$DEVICE_ID" net.minyue.lxcarplay.verify
