#!/usr/bin/env bash
set -euo pipefail
APP="${WHERE_DAT_SPACE_APP_PATH:-$HOME/Applications/Where Dat Space.app}"
CLI="${WHERE_DAT_SPACE_CLI_PATH:-$HOME/.local/bin/where-dat-space}"
# Remove only our own bundle and the exact link installed with these paths.
if [[ -e "$APP" || -L "$APP" ]]; then
  if [[ -L "$APP" || "$(/usr/libexec/PlistBuddy -c 'Print CFBundleIdentifier' "$APP/Contents/Info.plist" 2>/dev/null || true)" != 'com.mikerosoft.where-dat-space' ]]; then
    echo "An unrelated item exists at $APP; leaving it alone." >&2
    exit 1
  fi
  if pgrep -x WhereDatSpace >/dev/null; then
    pkill -TERM -x WhereDatSpace || true
    for WAIT in {1..30}; do
      if ! pgrep -x WhereDatSpace >/dev/null; then break; fi
      sleep 0.1
    done
    if pgrep -x WhereDatSpace >/dev/null; then
      echo 'Where Dat Space? is still running. Close it before uninstalling.' >&2
      exit 1
    fi
  fi
  rm -rf "$APP"
fi
if [[ -L "$CLI" && "$(readlink "$CLI")" == "$APP/Contents/MacOS/WhereDatSpace" ]]; then rm "$CLI"; fi
echo "Removed Where Dat Space? from $APP and its owned CLI link."
