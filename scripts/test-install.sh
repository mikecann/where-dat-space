#!/usr/bin/env bash
# All destinations and fixtures stay inside this clone. No app is launched or trashed.
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
mkdir -p "$ROOT/build/tmp"
TEST_ROOT="$(mktemp -d "$ROOT/build/install-test.XXXXXX")"
APP="$TEST_ROOT/Where Dat Space.app"
CLI="$TEST_ROOT/bin/where-dat-space"
CLAUDE="$TEST_ROOT/claude/where-dat-space"
CODEX="$TEST_ROOT/codex/where-dat-space"
run_script() {
  env TMPDIR="$ROOT/build/tmp" \
    WHERE_DAT_SPACE_APP_PATH="$APP" WHERE_DAT_SPACE_CLI_PATH="$CLI" \
    WHERE_DAT_SPACE_CLAUDE_SKILL_PATH="$CLAUDE" WHERE_DAT_SPACE_CODEX_SKILL_PATH="$CODEX" \
    WHERE_DAT_SPACE_CODESIGN_IDENTITY=- WHERE_DAT_SPACE_OPEN=0 \
    WHERE_DAT_SPACE_BUILD_SYSTEM="${WHERE_DAT_SPACE_BUILD_SYSTEM:-native}" \
    bash "$ROOT/$1"
}
run_script restart.sh > "$TEST_ROOT/install.log" 2>&1
[[ "$(readlink "$CLI")" == "$APP/Contents/MacOS/WhereDatSpace" ]]
[[ "$(readlink "$CLAUDE")" == "$ROOT/skill" ]]
[[ "$(readlink "$CODEX")" == "$ROOT/skill" ]]
[[ -f "$APP/Contents/Resources/WhereDatSpace.icns" ]]
[[ -d "$APP/Contents/Resources/WhereDatSpace_WhereDatSpace.bundle" ]]
[[ "$(/usr/libexec/PlistBuddy -c 'Print CFBundleIdentifier' "$APP/Contents/Info.plist")" == com.mikerosoft.where-dat-space ]]
codesign --verify --strict "$APP"
"$CLI" --scan "$ROOT/skill" --json > "$TEST_ROOT/scan.json" 2> "$TEST_ROOT/scan.log"
run_script restart.sh > "$TEST_ROOT/reinstall.log" 2>&1
BEFORE="$(shasum "$APP/Contents/MacOS/WhereDatSpace")"
# Refuse both a regular file and an unrelated link, without replacing the existing app.
rm "$CLAUDE"
echo unrelated > "$CLAUDE"
if run_script restart.sh > "$TEST_ROOT/refuse-file.log" 2>&1; then echo 'Installer replaced an unrelated skill file' >&2; exit 1; fi
[[ "$(cat "$CLAUDE")" == unrelated ]]
[[ "$(shasum "$APP/Contents/MacOS/WhereDatSpace")" == "$BEFORE" ]]
rm "$CLAUDE"
ln -s "$ROOT/skill" "$CLAUDE"
rm "$CODEX"
ln -s "$TEST_ROOT/unrelated" "$CODEX"
if run_script restart.sh > "$TEST_ROOT/refuse-link.log" 2>&1; then echo 'Installer replaced an unrelated skill link' >&2; exit 1; fi
[[ "$(readlink "$CODEX")" == "$TEST_ROOT/unrelated" ]]
rm "$CODEX"
ln -s "$ROOT/skill" "$CODEX"
run_script uninstall.sh > "$TEST_ROOT/uninstall.log" 2>&1
[[ ! -e "$APP" && ! -L "$CLI" && ! -L "$CLAUDE" && ! -L "$CODEX" ]]
echo unrelated > "$CLAUDE"
ln -s "$TEST_ROOT/unrelated" "$CODEX"
run_script uninstall.sh > "$TEST_ROOT/preserve-unrelated.log" 2>&1
[[ "$(cat "$CLAUDE")" == unrelated && "$(readlink "$CODEX")" == "$TEST_ROOT/unrelated" ]]
echo "Installer checks passed. Logs: $TEST_ROOT"
