#!/usr/bin/env bash
# Double-click in Finder (or run from Terminal) to build Melingo.app.
# Prompts for a marketing version (e.g. 1.2), then produces dist/Melingo.app.

cd "$(dirname "$0")"
# shellcheck source=_common.sh
source "./_common.sh"

prompt_version
build_app

echo ""
echo -n "Open the app now? [Y/n]: "
read -r open_now
open_now="$(echo "${open_now:-Y}" | tr '[:upper:]' '[:lower:]')"
if [[ "$open_now" == "y" || "$open_now" == "yes" ]]; then
  open "$DIST_DIR/${APP_NAME}.app"
else
  open "$DIST_DIR"
fi

pause_if_gui
