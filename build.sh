#!/bin/zsh
# Builds Waver.app and the Waver.component Audio Unit into ./build.
#   ./build.sh            build both
#   ./build.sh --install  also install the app to /Applications and the AU to ~/Library/Audio/Plug-Ins/Components
set -euo pipefail
cd "$(dirname "$0")"

APP="build/Waver.app"
AU="build/Waver.component"
ARCHS=(--arch arm64 --arch x86_64)   # universal, so the AU also loads in Live under Rosetta

echo "› Compiling (release, universal)…"
swift build -c release "${ARCHS[@]}" --product Waver
swift build -c release "${ARCHS[@]}" --product WaverAU
BIN="$(swift build -c release "${ARCHS[@]}" --show-bin-path)"

if [[ ! -f build/AppIcon.icns || scripts/make_icon.swift -nt build/AppIcon.icns ]]; then
  echo "› Rendering icon…"
  rm -rf build/AppIcon.iconset
  swift scripts/make_icon.swift build/AppIcon.iconset
  iconutil -c icns build/AppIcon.iconset -o build/AppIcon.icns
fi

echo "› Assembling ${APP}…"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN/Waver" "$APP/Contents/MacOS/Waver"
cp Resources/Info.plist "$APP/Contents/Info.plist"
cp build/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"

echo "› Assembling ${AU}…"
rm -rf "$AU"
mkdir -p "$AU/Contents/MacOS" "$AU/Contents/Resources"
cp "$BIN/libWaverAU.dylib" "$AU/Contents/MacOS/Waver"
install_name_tool -id "@loader_path/Waver" "$AU/Contents/MacOS/Waver" 2>/dev/null || true
cp Resources/AU-Info.plist "$AU/Contents/Info.plist"
cp build/AppIcon.icns "$AU/Contents/Resources/AppIcon.icns"

echo "› Signing (ad-hoc)…"
xattr -cr "$APP" "$AU"
codesign --force --deep --sign - "$APP"
codesign --force --deep --sign - "$AU"

if [[ "${1:-}" == "--install" ]]; then
  rm -rf /Applications/Waver.app
  cp -R "$APP" /Applications/
  echo "✓ Installed /Applications/Waver.app"

  COMPONENTS="$HOME/Library/Audio/Plug-Ins/Components"
  mkdir -p "$COMPONENTS"
  rm -rf "$COMPONENTS/Waver.component"
  cp -R "$AU" "$COMPONENTS/"
  # Make the system re-scan Audio Units so the new build is picked up.
  killall -9 AudioComponentRegistrar 2>/dev/null || true
  echo "✓ Installed $COMPONENTS/Waver.component"
else
  echo "✓ Built $APP and $AU"
fi
