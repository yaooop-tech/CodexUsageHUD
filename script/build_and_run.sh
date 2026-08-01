#!/usr/bin/env bash
set -euo pipefail

MODE="${1:-run}"
APP_NAME="CodexUsageHUD"
DISPLAY_NAME="Codex Usage HUD"
BUNDLE_ID="io.github.yaooop-tech.codexusagehud"
MIN_SYSTEM_VERSION="14.0"

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
DIST_DIR="$ROOT_DIR/dist"
APP_BUNDLE="$DIST_DIR/$DISPLAY_NAME.app"
APP_CONTENTS="$APP_BUNDLE/Contents"
APP_MACOS="$APP_CONTENTS/MacOS"
APP_RESOURCES="$APP_CONTENTS/Resources"
APP_BINARY="$APP_MACOS/$APP_NAME"
BRIDGE_NAME="ClaudeUsageBridge"
BRIDGE_BINARY="$APP_RESOURCES/$BRIDGE_NAME"
INFO_PLIST="$APP_CONTENTS/Info.plist"
ICON_FILE="CodexUsageHUD.icns"
ICON_SOURCE="$ROOT_DIR/Resources/$ICON_FILE"

usage() {
  echo "usage: $0 [run|--debug|--logs|--telemetry|--verify|--no-run|--export <dir>|--package <dir>|--install]" >&2
}

kill_running() {
  pkill -x "$APP_NAME" >/dev/null 2>&1 || true
}

build_bundle() {
  cd "$ROOT_DIR"
  swift build -c release
  BUILD_DIR="$(swift build -c release --show-bin-path)"
  BUILD_BINARY="$BUILD_DIR/$APP_NAME"

  rm -rf "$APP_BUNDLE"
  mkdir -p "$APP_MACOS" "$APP_RESOURCES"
  cp "$BUILD_BINARY" "$APP_BINARY"
  chmod +x "$APP_BINARY"
  cp "$BUILD_DIR/$BRIDGE_NAME" "$BRIDGE_BINARY"
  chmod +x "$BRIDGE_BINARY"
  cp "$ICON_SOURCE" "$APP_RESOURCES/$ICON_FILE"

  cat >"$INFO_PLIST" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleExecutable</key>
  <string>$APP_NAME</string>
  <key>CFBundleIdentifier</key>
  <string>$BUNDLE_ID</string>
  <key>CFBundleName</key>
  <string>$DISPLAY_NAME</string>
  <key>CFBundleDisplayName</key>
  <string>$DISPLAY_NAME</string>
  <key>CFBundleIconFile</key>
  <string>$ICON_FILE</string>
  <key>CFBundlePackageType</key>
  <string>APPL</string>
  <key>CFBundleShortVersionString</key>
  <string>1.8.4</string>
  <key>CFBundleVersion</key>
  <string>12</string>
  <key>LSMinimumSystemVersion</key>
  <string>$MIN_SYSTEM_VERSION</string>
  <key>LSUIElement</key>
  <true/>
  <key>LSApplicationCategoryType</key>
  <string>public.app-category.developer-tools</string>
  <key>NSPrincipalClass</key>
  <string>NSApplication</string>
</dict>
</plist>
PLIST

  /usr/bin/codesign --force --sign - "$BRIDGE_BINARY" >/dev/null
  /usr/bin/codesign --force --sign - "$APP_BUNDLE" >/dev/null
}

open_app() {
  /usr/bin/open -n "$APP_BUNDLE"
}

kill_running
build_bundle

case "$MODE" in
  run)
    open_app
    ;;
  --debug|debug)
    lldb -- "$APP_BINARY"
    ;;
  --logs|logs)
    open_app
    /usr/bin/log stream --info --style compact --predicate "process == \"$APP_NAME\""
    ;;
  --telemetry|telemetry)
    open_app
    /usr/bin/log stream --info --style compact --predicate "subsystem == \"$BUNDLE_ID\""
    ;;
  --verify|verify)
    open_app
    sleep 2
    pgrep -x "$APP_NAME" >/dev/null
    ;;
  --no-run|no-run)
    echo "$APP_BUNDLE"
    ;;
  --export|export)
    EXPORT_DIR="${2:-}"
    if [[ -z "$EXPORT_DIR" ]]; then
      usage
      exit 2
    fi
    mkdir -p "$EXPORT_DIR"
    rm -rf "$EXPORT_DIR/$DISPLAY_NAME.app"
    cp -R "$APP_BUNDLE" "$EXPORT_DIR/"
    echo "$EXPORT_DIR/$DISPLAY_NAME.app"
    ;;
  --package|package)
    PACKAGE_DIR="${2:-}"
    if [[ -z "$PACKAGE_DIR" ]]; then
      usage
      exit 2
    fi
    mkdir -p "$PACKAGE_DIR"
    PACKAGE_DIR="$(cd "$PACKAGE_DIR" && pwd)"
    ARCHIVE="$PACKAGE_DIR/CodexUsageHUD-v1.8.4-macos-arm64.zip"
    CHECKSUM_FILE="$ARCHIVE.sha256"
    rm -f "$ARCHIVE" "$CHECKSUM_FILE"
    /usr/bin/xattr -cr "$APP_BUNDLE" 2>/dev/null || true
    (
      cd "$DIST_DIR"
      /usr/bin/zip -q -r -X "$ARCHIVE" "$DISPLAY_NAME.app"
    )
    /usr/bin/shasum -a 256 "$ARCHIVE" | /usr/bin/tee "$CHECKSUM_FILE"
    ;;
  --install|install)
    rm -rf "/Applications/$DISPLAY_NAME.app"
    cp -R "$APP_BUNDLE" "/Applications/"
    echo "/Applications/$DISPLAY_NAME.app"
    ;;
  *)
    usage
    exit 2
    ;;
esac
