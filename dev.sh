#!/usr/bin/env bash
# Build and install using the Apple Development certificate configured in Xcode.
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DEVELOPMENT_TEAM="${DEVELOPMENT_TEAM:-WNF89D7V44}"
CONFIGURATION="${CONFIGURATION:-Release}"
BUILD_DIR="$ROOT_DIR/build/DerivedDataDev"
INSTALL_PATH="/Applications/GhostEdit.app"
RUN_APP=false

usage() {
    cat <<EOF
Usage: $0 [--run]

  --run       Launch after installing; an already-running app is always restarted.
  -h, --help  Show this help.

Environment:
  DEVELOPMENT_TEAM  Xcode development team (default: WNF89D7V44).
  CONFIGURATION     Release (default) or Debug.

Requires Xcode with an Apple Development certificate, xcodegen, and Rust.
EOF
}

while [ "$#" -gt 0 ]; do
    case "$1" in
        --run) RUN_APP=true ;;
        -h|--help) usage; exit 0 ;;
        *) echo "Unknown argument: $1" >&2; usage >&2; exit 1 ;;
    esac
    shift
done

case "$CONFIGURATION" in
    Debug|Release) ;;
    *) echo "CONFIGURATION must be Debug or Release." >&2; exit 1 ;;
esac

if [ -z "${DEVELOPER_DIR:-}" ] && [ -d /Applications/Xcode.app/Contents/Developer ]; then
    export DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer
fi
for tool in xcodebuild xcodegen codesign; do
    if ! command -v "$tool" >/dev/null 2>&1; then
        echo "Required tool not found: $tool" >&2
        exit 1
    fi
done

echo "Building GhostEdit ($CONFIGURATION), development team $DEVELOPMENT_TEAM..."
xcodegen generate --spec "$ROOT_DIR/project.yml" --project "$ROOT_DIR"
xcodebuild \
    -project "$ROOT_DIR/GhostEdit.xcodeproj" \
    -scheme GhostEdit \
    -configuration "$CONFIGURATION" \
    -derivedDataPath "$BUILD_DIR" \
    DEVELOPMENT_TEAM="$DEVELOPMENT_TEAM" \
    CODE_SIGN_STYLE=Automatic \
    CODE_SIGN_IDENTITY="Apple Development" \
    build

APP_PATH="$BUILD_DIR/Build/Products/$CONFIGURATION/GhostEdit.app"
codesign --verify --deep --strict "$APP_PATH"
SIGNING_INFO="$(codesign -dv --verbose=2 "$APP_PATH" 2>&1)"
if [[ "$SIGNING_INFO" != *"Authority=Apple Development:"* || "$SIGNING_INFO" != *"TeamIdentifier=$DEVELOPMENT_TEAM"* ]]; then
    echo "Expected an Apple Development signature for team $DEVELOPMENT_TEAM, not ad-hoc signing." >&2
    printf '%s\n' "$SIGNING_INFO" >&2
    exit 1
fi
printf '%s\n' "$SIGNING_INFO"

STAGING_DIR="$(mktemp -d /Applications/.ghostedit-dev.XXXXXX)"
cleanup() {
    if [ -d "$STAGING_DIR/previous.app" ] && [ ! -e "$INSTALL_PATH" ]; then
        mv "$STAGING_DIR/previous.app" "$INSTALL_PATH"
    fi
    rm -rf "$STAGING_DIR"
}
trap cleanup EXIT
ditto "$APP_PATH" "$STAGING_DIR/GhostEdit.app"
codesign --verify --deep --strict "$STAGING_DIR/GhostEdit.app"

WAS_RUNNING=false
if pgrep -x GhostEdit >/dev/null; then
    WAS_RUNNING=true
    echo "Stopping running GhostEdit..."
    pkill -x GhostEdit || true
    for _ in {1..50}; do
        if ! pgrep -x GhostEdit >/dev/null; then break; fi
        sleep 0.1
    done
    if pgrep -x GhostEdit >/dev/null; then
        echo "GhostEdit did not exit; installation cancelled. Quit it and retry." >&2
        exit 1
    fi
fi

if [ -e "$INSTALL_PATH" ]; then
    mv "$INSTALL_PATH" "$STAGING_DIR/previous.app"
fi
mv "$STAGING_DIR/GhostEdit.app" "$INSTALL_PATH"
echo "Installed: $INSTALL_PATH"
if [ "$RUN_APP" = true ] || [ "$WAS_RUNNING" = true ]; then
    open "$INSTALL_PATH"
fi
