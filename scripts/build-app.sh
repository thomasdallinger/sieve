#!/usr/bin/env bash
# Builds dist/<App>.app (release) with icon, Info.plist and a stable signature.
set -euo pipefail
cd "$(dirname "$0")/.."
source scripts/app.env

VERSION="${VERSION:-1.0.0}"
BUILD="${BUILD:-$(git rev-list --count HEAD 2>/dev/null || echo 1)}"
APP="dist/$APP_NAME.app"
KEYCHAIN="$HOME/Library/Keychains/local-codesign.keychain-db"
IDENTITY="Local Code Signing"

swift build -c release 2>&1 | grep -v "xcrun: error: unable to lookup item 'PlatformPath'" || true
BIN="$(swift build -c release --show-bin-path 2>/dev/null)/$EXECUTABLE"
[[ -x "$BIN" ]] || { echo "build failed"; exit 1; }

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN" "$APP/Contents/MacOS/$APP_NAME"

# Icon (cached in .build so it is only rendered once).
ICNS=".build/AppIcon.icns"
if [[ ! -f "$ICNS" || scripts/make-icon.swift -nt "$ICNS" ]]; then
  ICONSET=".build/AppIcon.iconset"
  rm -rf "$ICONSET" && mkdir -p "$ICONSET"
  swift scripts/make-icon.swift ".build/AppIcon-1024.png" >/dev/null
  for s in 16 32 128 256 512; do
    sips -z $s $s ".build/AppIcon-1024.png" --out "$ICONSET/icon_${s}x${s}.png" >/dev/null
    sips -z $((s*2)) $((s*2)) ".build/AppIcon-1024.png" --out "$ICONSET/icon_${s}x${s}@2x.png" >/dev/null
  done
  iconutil -c icns "$ICONSET" -o "$ICNS"
fi
cp "$ICNS" "$APP/Contents/Resources/AppIcon.icns"

cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleDevelopmentRegion</key><string>en</string>
  <key>CFBundleDisplayName</key><string>${APP_NAME}</string>
  <key>CFBundleExecutable</key><string>${APP_NAME}</string>
  <key>CFBundleIconFile</key><string>AppIcon</string>
  <key>CFBundleIdentifier</key><string>${BUNDLE_ID}</string>
  <key>CFBundleInfoDictionaryVersion</key><string>6.0</string>
  <key>CFBundleName</key><string>${APP_NAME}</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>${VERSION}</string>
  <key>CFBundleVersion</key><string>${BUILD}</string>
  <key>LSMinimumSystemVersion</key><string>14.0</string>
  <key>NSHighResolutionCapable</key><true/>
  <key>NSHumanReadableCopyright</key><string>MIT License</string>
  <key>NSPrincipalClass</key><string>NSApplication</string>
  <key>NSDesktopFolderUsageDescription</key><string>${APP_NAME} shows and searches the files on your Desktop.</string>
  <key>NSDocumentsFolderUsageDescription</key><string>${APP_NAME} shows and searches the files in your Documents folder.</string>
  <key>NSDownloadsFolderUsageDescription</key><string>${APP_NAME} shows and searches the files in your Downloads folder.</string>
  <key>NSRemovableVolumesUsageDescription</key><string>${APP_NAME} shows the files on removable drives you open.</string>
  <key>NSNetworkVolumesUsageDescription</key><string>${APP_NAME} shows the files on network drives you open.</string>
  <key>NSAppTransportSecurity</key><dict><key>NSAllowsLocalNetworking</key><true/></dict>
</dict>
</plist>
PLIST

if [[ -f "$KEYCHAIN" ]]; then
  security unlock-keychain -p "local-codesign" "$KEYCHAIN"
  HASH="$(security find-identity -p codesigning "$KEYCHAIN" | awk -v n="$IDENTITY" '$0 ~ n {print $2; exit}')"
  # codesign only looks up identities on the search list; add the keychain just for this call.
  ORIG_KEYCHAINS=()
  while IFS= read -r k; do ORIG_KEYCHAINS+=("$(echo "$k" | tr -d '" ')"); done < <(security list-keychains -d user)
  security list-keychains -d user -s "${ORIG_KEYCHAINS[@]}" "$KEYCHAIN"
  trap 'security list-keychains -d user -s "${ORIG_KEYCHAINS[@]}"' EXIT
  codesign --force --timestamp=none --sign "$HASH" "$APP"
  security list-keychains -d user -s "${ORIG_KEYCHAINS[@]}"
  trap - EXIT
  echo "Signed with '$IDENTITY'"
else
  codesign --force --sign - "$APP"
  echo "Signed ad-hoc (run scripts/setup-signing.sh for a stable identity that keeps permissions across rebuilds)"
fi
codesign --verify --verbose=1 "$APP" 2>&1 | tail -1
echo "Built $APP"
