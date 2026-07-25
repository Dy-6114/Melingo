#!/usr/bin/env bash
# Shared helpers for MelingoMac packaging scripts.
# shellcheck shell=bash

set -euo pipefail

SCRIPTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$SCRIPTS_DIR/.." && pwd)"
PROJECT="$ROOT/MelingoMac.xcodeproj"
SCHEME="MelingoMac"
APP_NAME="Melingo"
DIST_DIR="$ROOT/dist"
DERIVED_DATA="$ROOT/DerivedData"
DEFAULT_VERSION="0.2.3"

# Prefer last packaged app version, then pbxproj MARKETING_VERSION, then fallback.
detect_default_version() {
  local from_app from_pbx
  if [[ -f "$DIST_DIR/${APP_NAME}.app/Contents/Info.plist" ]]; then
    from_app="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' \
      "$DIST_DIR/${APP_NAME}.app/Contents/Info.plist" 2>/dev/null || true)"
  fi
  if [[ -z "${from_app:-}" ]]; then
    from_pbx="$(grep -m1 'MARKETING_VERSION' "$ROOT/MelingoMac.xcodeproj/project.pbxproj" \
      | sed -E 's/.*MARKETING_VERSION = ([^;]+);/\1/' | tr -d '[:space:]' || true)"
  fi
  if [[ -n "${from_app:-}" ]]; then
    DEFAULT_VERSION="$from_app"
  elif [[ -n "${from_pbx:-}" ]]; then
    DEFAULT_VERSION="$from_pbx"
  fi
}

prompt_version() {
  local input
  detect_default_version
  echo ""
  echo "Melingo macOS — enter marketing version (e.g. 1.2 or 1.2.0)"
  echo -n "Version [$DEFAULT_VERSION]: "
  read -r input
  input="${input:-$DEFAULT_VERSION}"
  input="$(echo "$input" | tr -d '[:space:]')"

  if [[ ! "$input" =~ ^[0-9]+(\.[0-9]+){1,3}([-+][A-Za-z0-9._-]+)?$ ]]; then
    echo "Invalid version: '$input' (expected like 1.2 or 1.2.0)" >&2
    exit 1
  fi

  VERSION="$input"
  # CFBundleVersion — unique build number for this packaging run
  BUILD_NUMBER="$(date +%Y%m%d%H%M)"
  echo "Using version $VERSION (build $BUILD_NUMBER)"
}

require_xcode() {
  if ! command -v xcodebuild >/dev/null 2>&1; then
    echo "xcodebuild not found. Install Xcode from the App Store." >&2
    exit 1
  fi
  if [[ ! -d "$PROJECT" ]]; then
    echo "Xcode project not found: $PROJECT" >&2
    exit 1
  fi
}

build_app() {
  require_xcode
  mkdir -p "$DIST_DIR" "$DERIVED_DATA"

  echo ""
  echo "Building $APP_NAME.app (Release, v$VERSION)…"
  echo ""

  xcodebuild \
    -project "$PROJECT" \
    -scheme "$SCHEME" \
    -configuration Release \
    -derivedDataPath "$DERIVED_DATA" \
    -destination "platform=macOS" \
    MARKETING_VERSION="$VERSION" \
    CURRENT_PROJECT_VERSION="$BUILD_NUMBER" \
    ONLY_ACTIVE_ARCH=NO \
    build

  local built_app
  built_app="$(find "$DERIVED_DATA/Build/Products/Release" -maxdepth 1 -name "${APP_NAME}.app" -print -quit)"
  if [[ -z "$built_app" || ! -d "$built_app" ]]; then
    echo "Build succeeded but ${APP_NAME}.app was not found under DerivedData." >&2
    exit 1
  fi

  rm -rf "$DIST_DIR/${APP_NAME}.app"
  ditto "$built_app" "$DIST_DIR/${APP_NAME}.app"

  # Icon Composer AppIcon.icon lives in Assets.xcassets — actool packs it into Assets.car.
  local resources="$DIST_DIR/${APP_NAME}.app/Contents/Resources"
  if [[ -f "$resources/Assets.car" || -f "$resources/AppIcon.icns" ]]; then
    echo "App icon resources OK (Asset Catalog)."
  else
    echo "Warning: no Assets.car / AppIcon.icns in app bundle — Dock icon may be generic." >&2
  fi

  # Keep a versioned copy next to the stable name
  rm -rf "$DIST_DIR/${APP_NAME}-${VERSION}.app"
  ditto "$DIST_DIR/${APP_NAME}.app" "$DIST_DIR/${APP_NAME}-${VERSION}.app"

  echo ""
  echo "App ready:"
  echo "  $DIST_DIR/${APP_NAME}.app"
  echo "  $DIST_DIR/${APP_NAME}-${VERSION}.app"
}

create_dmg() {
  local app_path="$DIST_DIR/${APP_NAME}.app"
  local dmg_path="$DIST_DIR/${APP_NAME}-${VERSION}.dmg"
  local bg_src="$SCRIPTS_DIR/dmg-assets/background.png"
  local vol_name="Melingo $VERSION"
  local stage rw_dmg mount_dir device bg_dir
  local win_w=800 win_h=500
  local icon_app_x=180 icon_app_y=220
  local icon_apps_x=620 icon_apps_y=220

  if [[ ! -d "$app_path" ]]; then
    echo "Missing $app_path — build the app first." >&2
    exit 1
  fi

  stage="$(mktemp -d "${TMPDIR:-/tmp}/melingo-dmg-stage.XXXXXX")"
  rw_dmg="${TMPDIR:-/tmp}/melingo-dmg-rw.$$.$RANDOM.dmg"
  rm -f "$rw_dmg"
  device=""
  trap 'rm -rf "${stage:-}"; rm -f "${rw_dmg:-}"; [[ -n "${device:-}" ]] && hdiutil detach "$device" -force >/dev/null 2>&1 || true' EXIT

  echo ""
  echo "Creating styled DMG $dmg_path …"
  echo "  (Melingo.app → drag into Applications)"

  # Stage contents: app + Applications symlink
  ditto "$app_path" "$stage/$APP_NAME.app"
  ln -sf /Applications "$stage/Applications"

  # Volume icon (Finder shows Melingo icon on the DMG)
  if [[ -f "$ROOT/Asset/AppIcon.icns" ]]; then
    cp -f "$ROOT/Asset/AppIcon.icns" "$stage/.VolumeIcon.icns"
  elif [[ -f "$app_path/Contents/Resources/AppIcon.icns" ]]; then
    cp -f "$app_path/Contents/Resources/AppIcon.icns" "$stage/.VolumeIcon.icns"
  fi

  # Hidden background folder (Finder shows picture, not the folder)
  bg_dir="$stage/.background"
  mkdir -p "$bg_dir"
  if [[ -f "$bg_src" ]]; then
    # Flatten to RGB PNG Finder can use as background
    sips -s format png "$bg_src" --out "$bg_dir/background.png" >/dev/null
  else
    echo "Warning: no background at $bg_src — icon layout only." >&2
  fi

  # Size RW image with headroom for AppleScript / DS_Store
  local size_mb
  size_mb="$(du -sm "$stage" | awk '{print $1}')"
  size_mb=$((size_mb + 40))
  if (( size_mb < 80 )); then size_mb=80; fi

  hdiutil create \
    -srcfolder "$stage" \
    -volname "$vol_name" \
    -fs HFS+ \
    -fsargs "-c c=64,a=16,e=16" \
    -format UDRW \
    -size "${size_mb}m" \
    "$rw_dmg" >/dev/null

  # Mount read-write
  local attach_out
  attach_out="$(hdiutil attach -readwrite -noverify -noautoopen "$rw_dmg")"
  device="$(echo "$attach_out" | awk '/^\/dev\// { print $1; exit }')"
  mount_dir="$(echo "$attach_out" | awk -F'\t' '/\/Volumes\// { print $NF; exit }')"
  if [[ -z "$device" || -z "$mount_dir" || ! -d "$mount_dir" ]]; then
    echo "Failed to mount temporary DMG." >&2
    echo "$attach_out" >&2
    exit 1
  fi

  # Make background folder invisible-ish + set Finder layout
  if [[ -d "$mount_dir/.background" ]]; then
    SetFile -a V "$mount_dir/.background" 2>/dev/null || true
  fi
  if [[ -f "$mount_dir/.VolumeIcon.icns" ]]; then
    SetFile -a C "$mount_dir" 2>/dev/null || true
  fi

  echo "  Styling Finder window…"
  # shellcheck disable=SC2088
  osascript <<OSA
tell application "Finder"
  tell disk "$vol_name"
    open
    set current view of container window to icon view
    set toolbar visible of container window to false
    set statusbar visible of container window to false
    set the bounds of container window to {100, 100, $((100 + win_w)), $((100 + win_h))}
    set viewOptions to the icon view options of container window
    set arrangement of viewOptions to not arranged
    set icon size of viewOptions to 128
    set text size of viewOptions to 12
    try
      set background picture of viewOptions to file ".background:background.png"
    end try
    try
      set position of item "$APP_NAME.app" of container window to {$icon_app_x, $icon_app_y}
    end try
    try
      set position of item "Applications" of container window to {$icon_apps_x, $icon_apps_y}
    end try
    update without registering applications
    delay 1
    close
    open
    delay 1
    close
  end tell
end tell
OSA

  # Flush .DS_Store
  sync
  sleep 1

  hdiutil detach "$device" -quiet || hdiutil detach "$device" -force
  device=""

  rm -f "$dmg_path"
  hdiutil convert "$rw_dmg" \
    -format UDZO \
    -imagekey zlib-level=9 \
    -o "$dmg_path" >/dev/null

  # Optional internet-enable (legacy; harmless if unsupported)
  hdiutil internet-enable -yes "$dmg_path" >/dev/null 2>&1 || true

  echo ""
  echo "DMG ready (drag Melingo → Applications):"
  echo "  $dmg_path"
}

install_to_applications() {
  local app_path="$DIST_DIR/${APP_NAME}.app"
  local dest="/Applications/${APP_NAME}.app"

  if [[ ! -d "$app_path" ]]; then
    echo "Missing $app_path — build the app first." >&2
    exit 1
  fi

  echo ""
  echo "Installing to $dest …"
  # Replace existing install atomically-ish
  if [[ -d "$dest" ]]; then
    rm -rf "$dest"
  fi
  ditto "$app_path" "$dest"
  # Clear quarantine so Gatekeeper is less noisy for local builds
  xattr -dr com.apple.quarantine "$dest" 2>/dev/null || true
  # Refresh Services menu database so “Add Card to Melingo” appears
  /System/Library/CoreServices/pbs -flush 2>/dev/null || true
  echo "Installed: $dest"
  echo "Tip: select text → right-click → Services → «Добавить карточку в Melingo»"
}

pause_if_gui() {
  # Keep Terminal open when double-clicked from Finder (.command)
  if [[ -t 0 ]]; then
    echo ""
    echo -n "Press Return to close…"
    read -r _
  fi
}
