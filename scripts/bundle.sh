#!/bin/zsh
# Builds Cartridge.app into Cartridge/dist. Usage: scripts/bundle.sh
set -euo pipefail
cd "$(dirname "$0")/.."
ROOT=$PWD
PY="${PYTHON:-python3}"

swift build -c release
APP="$ROOT/dist/Cartridge.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$(swift build -c release --show-bin-path)/Cartridge" "$APP/Contents/MacOS/Cartridge"
cp -R "$ROOT/Resources/Fonts" "$APP/Contents/Resources/Fonts"

# Icon
ICON_TMP=$(mktemp -d)
if "$PY" "$ROOT/scripts/make_icon.py" "$ICON_TMP/icon.png" 2>/dev/null; then
  mkdir -p "$ICON_TMP/AppIcon.iconset"
  for s in 16 32 128 256 512; do
    sips -z $s $s "$ICON_TMP/icon.png" --out "$ICON_TMP/AppIcon.iconset/icon_${s}x${s}.png" >/dev/null
    sips -z $((s*2)) $((s*2)) "$ICON_TMP/icon.png" --out "$ICON_TMP/AppIcon.iconset/icon_${s}x${s}@2x.png" >/dev/null
  done
  iconutil -c icns "$ICON_TMP/AppIcon.iconset" -o "$APP/Contents/Resources/AppIcon.icns"
else
  echo "Skipping app icon: needs Python 3 with Pillow (pip install pillow), or set PYTHON=/path/to/python"
fi
rm -rf "$ICON_TMP"

cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>CFBundleName</key><string>Cartridge</string>
  <key>CFBundleDisplayName</key><string>Cartridge</string>
  <key>CFBundleIdentifier</key><string>local.cartridge.miyoo</string>
  <key>CFBundleExecutable</key><string>Cartridge</string>
  <key>CFBundleIconFile</key><string>AppIcon</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>0.1</string>
  <key>CFBundleVersion</key><string>1</string>
  <key>LSMinimumSystemVersion</key><string>15.0</string>
  <key>NSHighResolutionCapable</key><true/>
  <key>LSApplicationCategoryType</key><string>public.app-category.utilities</string>
</dict></plist>
PLIST

codesign --force --deep --sign - "$APP" >/dev/null
echo "Built $APP"
