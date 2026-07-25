#!/usr/bin/env bash
# Unified release: ask version → Release .app → /Applications → styled DMG.
# Double-click in Finder or run from Terminal:
#   ./Scripts/Release.command
#   ./Scripts/Release.command 0.3.0          # version as arg (skips prompt)
#   MELINGO_SKIP_APPS=1 ./Scripts/Release.command   # skip /Applications install
#   MELINGO_SKIP_DMG=1 ./Scripts/Release.command    # app (+ optional Apps) only

cd "$(dirname "$0")"
# shellcheck source=_common.sh
source "./_common.sh"

echo "═══════════════════════════════════════"
echo "  Melingo — Release build"
echo "═══════════════════════════════════════"

if [[ $# -ge 1 && -n "${1:-}" ]]; then
  VERSION="$(echo "$1" | tr -d '[:space:]')"
  if [[ ! "$VERSION" =~ ^[0-9]+(\.[0-9]+){1,3}([-+][A-Za-z0-9._-]+)?$ ]]; then
    echo "Invalid version: '$VERSION' (expected like 1.2 or 1.2.0)" >&2
    exit 1
  fi
  BUILD_NUMBER="$(date +%Y%m%d%H%M)"
  echo "Using version $VERSION (build $BUILD_NUMBER)"
else
  prompt_version
fi

build_app

# Install into /Applications (default yes)
if [[ "${MELINGO_SKIP_APPS:-}" != "1" ]]; then
  echo ""
  echo -n "Install Melingo.app into /Applications? [Y/n]: "
  read -r install_apps
  install_apps="$(echo "${install_apps:-Y}" | tr '[:upper:]' '[:lower:]')"
  if [[ "$install_apps" == "y" || "$install_apps" == "yes" || "$install_apps" == "" ]]; then
    install_to_applications
  fi
fi

# DMG for sharing (default yes)
if [[ "${MELINGO_SKIP_DMG:-}" != "1" ]]; then
  echo ""
  echo -n "Create shareable DMG? [Y/n]: "
  read -r make_dmg
  make_dmg="$(echo "${make_dmg:-Y}" | tr '[:upper:]' '[:lower:]')"
  if [[ "$make_dmg" == "y" || "$make_dmg" == "yes" || "$make_dmg" == "" ]]; then
    create_dmg
  fi
fi

echo ""
echo "═══════════════════════════════════════"
echo "  Done"
echo "═══════════════════════════════════════"
echo "  App:  $DIST_DIR/${APP_NAME}.app"
echo "  App:  $DIST_DIR/${APP_NAME}-${VERSION}.app"
if [[ -f "$DIST_DIR/${APP_NAME}-${VERSION}.dmg" ]]; then
  echo "  DMG:  $DIST_DIR/${APP_NAME}-${VERSION}.dmg"
fi
if [[ -d "/Applications/${APP_NAME}.app" ]]; then
  echo "  Installed: /Applications/${APP_NAME}.app"
fi
echo ""

echo -n "Reveal dist/ in Finder? [Y/n]: "
read -r reveal
reveal="$(echo "${reveal:-Y}" | tr '[:upper:]' '[:lower:]')"
if [[ "$reveal" == "y" || "$reveal" == "yes" || "$reveal" == "" ]]; then
  open "$DIST_DIR"
  if [[ -f "$DIST_DIR/${APP_NAME}-${VERSION}.dmg" ]]; then
    open -R "$DIST_DIR/${APP_NAME}-${VERSION}.dmg"
  fi
fi

pause_if_gui
