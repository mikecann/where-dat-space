#!/usr/bin/env bash
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
APP="${WHERE_DAT_SPACE_APP_PATH:-$HOME/Applications/Where Dat Space.app}"
CLI="${WHERE_DAT_SPACE_CLI_PATH:-$HOME/.local/bin/where-dat-space}"
CLAUDE_SKILL="${WHERE_DAT_SPACE_CLAUDE_SKILL_PATH:-$HOME/.claude/skills/where-dat-space}"
CODEX_SKILL="${WHERE_DAT_SPACE_CODEX_SKILL_PATH:-$HOME/.codex/skills/where-dat-space}"
# Stop only processes running from this exact destination, including isolated test installs.
app_pids() {
  local PID
  while read -r PID; do
    if [[ "$(ps -p "$PID" -o comm= 2>/dev/null || true)" == "$APP/Contents/MacOS/WhereDatSpace" ]]; then echo "$PID"; fi
  done < <(pgrep -x WhereDatSpace || true)
}
stop_app() {
  local PID WAIT
  while read -r PID; do
    [[ -n "$PID" ]] || continue
    kill -TERM "$PID" 2>/dev/null || true
    for WAIT in {1..30}; do
      if ! kill -0 "$PID" 2>/dev/null; then break; fi
      sleep 0.1
    done
    if kill -0 "$PID" 2>/dev/null; then
      echo 'Where Dat Space? is still running at this install path. Close it before continuing.' >&2
      return 1
    fi
  done < <(app_pids)
}
# Remove only our own bundle and the exact link installed with these paths.
if [[ -e "$APP" || -L "$APP" ]]; then
  if [[ -L "$APP" || "$(/usr/libexec/PlistBuddy -c 'Print CFBundleIdentifier' "$APP/Contents/Info.plist" 2>/dev/null || true)" != 'com.mikerosoft.where-dat-space' ]]; then
    echo "An unrelated item exists at $APP; leaving it alone." >&2
    exit 1
  fi
  stop_app
  rm -rf "$APP"
fi
if [[ -L "$CLI" && "$(readlink "$CLI")" == "$APP/Contents/MacOS/WhereDatSpace" ]]; then rm "$CLI"; fi
echo "Removed Where Dat Space? from $APP and its owned CLI link."
for LINK in "$CLAUDE_SKILL" "$CODEX_SKILL"; do
  if [[ -L "$LINK" && "$(readlink "$LINK")" == "$ROOT/skill" ]]; then
    rm "$LINK"
  elif [[ -e "$LINK" || -L "$LINK" ]]; then
    echo "Unrelated skill at $LINK; leaving it alone." >&2
  fi
done
