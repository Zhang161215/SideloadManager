#!/bin/zsh
set -euo pipefail

SCRIPT_DIR="${0:A:h}"
PROJECT_ROOT="${SCRIPT_DIR:h}"
DIST_DIR="${SIDELOAD_DIST_DIR:-$PROJECT_ROOT/dist}"
INSTALL_DIR="${SIDELOAD_INSTALL_DIR:-$HOME/Applications}"

if [[ ! -d "$DIST_DIR/xtool-fixed.app" ]]; then
    "$SCRIPT_DIR/build-xtool.sh"
fi
if [[ ! -d "$DIST_DIR/SideloadManager.app" ]]; then
    "$SCRIPT_DIR/build-app.sh"
fi

mkdir -p "$INSTALL_DIR"
for name in xtool-fixed.app SideloadManager.app; do
    source="$DIST_DIR/$name"
    destination="$INSTALL_DIR/$name"
    staging="$INSTALL_DIR/.${name}.installing.$$"

    /usr/bin/codesign --verify --deep --strict "$source"
    rm -rf -- "$staging"
    /usr/bin/ditto "$source" "$staging"
    /usr/bin/codesign --verify --deep --strict "$staging"

    rm -rf -- "$destination"
    /bin/mv "$staging" "$destination"
done

/usr/bin/codesign --verify --deep --strict "$INSTALL_DIR/xtool-fixed.app"
/usr/bin/codesign --verify --deep --strict "$INSTALL_DIR/SideloadManager.app"
print "Installed: $INSTALL_DIR/xtool-fixed.app"
print "Installed: $INSTALL_DIR/SideloadManager.app"
