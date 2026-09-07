#!/bin/zsh
set -euo pipefail

SCRIPT_DIR="${0:A:h}"
PROJECT_ROOT="${SCRIPT_DIR:h}"
DIST_DIR="${SIDELOAD_DIST_DIR:-$PROJECT_ROOT/dist}"

cd "$PROJECT_ROOT"
BIN_DIR="$(swift build -c release --product SideloadManager --show-bin-path)"
APP_PATH="$DIST_DIR/SideloadManager.app"

mkdir -p "$DIST_DIR"
rm -rf -- "$APP_PATH"
mkdir -p "$APP_PATH/Contents/MacOS" "$APP_PATH/Contents/Resources"

/usr/bin/ditto "$BIN_DIR/SideloadManager" "$APP_PATH/Contents/MacOS/SideloadManager"
/usr/bin/ditto "$PROJECT_ROOT/Resources/SideloadManager-Info.plist" "$APP_PATH/Contents/Info.plist"
/usr/bin/ditto "$PROJECT_ROOT/Resources/AppIcon.icns" "$APP_PATH/Contents/Resources/AppIcon.icns"
/usr/bin/printf 'APPL????' > "$APP_PATH/Contents/PkgInfo"

/usr/bin/plutil -lint "$APP_PATH/Contents/Info.plist"
/usr/bin/codesign --force --deep --sign - --timestamp=none "$APP_PATH"
/usr/bin/codesign --verify --deep --strict "$APP_PATH"

print "Built: $APP_PATH"
