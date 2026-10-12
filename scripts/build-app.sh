#!/bin/zsh
# Builds build/ClaudeBar.app.
#   --install     copy it to ~/Applications and launch it
#   UNIVERSAL=1   build for Apple silicon and Intel (used for releases)
set -euo pipefail
cd "$(dirname "$0")/.."

flags=(-c release)
[[ "${UNIVERSAL:-0}" == "1" ]] && flags+=(--arch arm64 --arch x86_64)

swift build "${flags[@]}"
BIN="$(swift build "${flags[@]}" --show-bin-path)/ClaudeBar"

APP=build/ClaudeBar.app
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN" "$APP/Contents/MacOS/ClaudeBar"
cp Resources/Info.plist "$APP/Contents/Info.plist"
cp Resources/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"
codesign --force --sign - "$APP"
echo "Built $APP ($(lipo -archs "$APP/Contents/MacOS/ClaudeBar"))"

if [[ "${1:-}" == "--install" ]]; then
    pkill -x ClaudeBar || true
    mkdir -p ~/Applications
    rm -rf ~/Applications/ClaudeBar.app
    cp -R "$APP" ~/Applications/
    open ~/Applications/ClaudeBar.app
    echo "Installed to ~/Applications/ClaudeBar.app"
fi
