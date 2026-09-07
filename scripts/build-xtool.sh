#!/bin/zsh
set -euo pipefail

SCRIPT_DIR="${0:A:h}"
PROJECT_ROOT="${SCRIPT_DIR:h}"
DIST_DIR="${SIDELOAD_DIST_DIR:-$PROJECT_ROOT/dist}"
SOURCE_DIR="$PROJECT_ROOT/.build/xtool-src"
INSTALL_ROOT="$SOURCE_DIR/macOS/Build/XcodeInstall"
PATCH_FILE="$PROJECT_ROOT/patches/xtool-1.19.0-grandslam-retry.patch"
XTOOL_REPOSITORY="https://github.com/xtool-org/xtool.git"
XTOOL_REVISION="893cf4f8f916673922a47bb94601ead6efc7669f"

if [[ "$(uname -s)" != "Darwin" ]]; then
    print -u2 "This script builds the macOS xtool.app and must run on macOS."
    exit 1
fi

for command in git xcodebuild xcodegen; do
    if ! command -v "$command" >/dev/null 2>&1; then
        print -u2 "Missing required command: $command"
        if [[ "$command" == "xcodegen" ]]; then
            print -u2 "Install XcodeGen first: brew install xcodegen"
        fi
        exit 1
    fi
done

rm -rf -- "$SOURCE_DIR"
git clone --filter=blob:none "$XTOOL_REPOSITORY" "$SOURCE_DIR"
git -C "$SOURCE_DIR" checkout --detach "$XTOOL_REVISION"
git -C "$SOURCE_DIR" apply --check "$PATCH_FILE"
git -C "$SOURCE_DIR" apply "$PATCH_FILE"

(
    cd "$SOURCE_DIR/macOS"
    xcodegen
    xcodebuild install \
        -skipMacroValidation \
        -skipPackagePluginValidation \
        -scheme XToolMac \
        -destination generic/platform=macOS \
        -derivedDataPath Build/DerivedData \
        -configuration Release \
        DSTROOT="$INSTALL_ROOT" \
        INSTALL_PATH=/ \
        CODE_SIGNING_ALLOWED=NO \
        CODE_SIGNING_REQUIRED=NO
)

SOURCE_APP="$INSTALL_ROOT/xtool.app"
OUTPUT_APP="$DIST_DIR/xtool-fixed.app"
if [[ ! -d "$SOURCE_APP" ]]; then
    print -u2 "xtool.app was not produced at $SOURCE_APP"
    exit 1
fi

mkdir -p "$DIST_DIR"
rm -rf -- "$OUTPUT_APP"
/usr/bin/ditto "$SOURCE_APP" "$OUTPUT_APP"
rm -rf -- "$OUTPUT_APP/Contents/_CodeSignature"
rm -f -- "$OUTPUT_APP/Contents/embedded.provisionprofile"
/usr/bin/codesign --force --deep --sign - --timestamp=none "$OUTPUT_APP"
/usr/bin/codesign --verify --deep --strict "$OUTPUT_APP"

"$OUTPUT_APP/Contents/Resources/bin/xtool" --version
print "Built: $OUTPUT_APP"
