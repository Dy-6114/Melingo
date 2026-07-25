#!/usr/bin/env bash
# Double-click in Finder (or run from Terminal) to build a styled DMG.
# Prompts for a marketing version (e.g. 1.2), builds the app, then packs
# dist/Melingo-<version>.dmg with:
#   • background “Drag to Applications”
#   • Melingo.app on the left, Applications alias on the right
#   • Finder icon view sized for drag-install

cd "$(dirname "$0")"
# shellcheck source=_common.sh
source "./_common.sh"

prompt_version
build_app
create_dmg

echo ""
echo -n "Open DMG to preview install window? [Y/n]: "
read -r reveal
reveal="$(echo "${reveal:-Y}" | tr '[:upper:]' '[:lower:]')"
if [[ "$reveal" == "y" || "$reveal" == "yes" ]]; then
  open "$DIST_DIR/${APP_NAME}-${VERSION}.dmg"
  sleep 1
  open -R "$DIST_DIR/${APP_NAME}-${VERSION}.dmg"
fi

pause_if_gui
