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
BUNDLE_ID='com.mikerosoft.where-dat-space'
export CLANG_MODULE_CACHE_PATH="$ROOT/.build/module-cache"
export SWIFTPM_MODULECACHE_OVERRIDE="$ROOT/.build/module-cache"
cd "$ROOT"
BUILD_ARGS=(--disable-sandbox)
if [[ -n "${WHERE_DAT_SPACE_BUILD_SYSTEM:-}" ]]; then BUILD_ARGS+=(--build-system "$WHERE_DAT_SPACE_BUILD_SYSTEM"); fi
swift build -c release "${BUILD_ARGS[@]}"
BIN_DIR="$(swift build -c release --show-bin-path "${BUILD_ARGS[@]}")"
STAGE_ROOT="$(mktemp -d "$ROOT/.build/stage.XXXXXX")"
trap 'rm -rf "$STAGE_ROOT"' EXIT
STAGE="$STAGE_ROOT/Where Dat Space.app"
mkdir -p "$STAGE/Contents/MacOS" "$STAGE/Contents/Resources" "$STAGE_ROOT/icon.iconset"
cp "$BIN_DIR/WhereDatSpace" "$STAGE/Contents/MacOS/WhereDatSpace"
# SwiftPM's resource accessor looks here inside an installed macOS bundle.
cp -R "$BIN_DIR/WhereDatSpace_WhereDatSpace.bundle" "$STAGE/Contents/Resources/"
cp "$ROOT/icons/where-dat-space.png" "$STAGE/Contents/Resources/where-dat-space.png"
for SIZE in 16 32 128 256 512; do
  sips -z "$SIZE" "$SIZE" "$ROOT/icons/where-dat-space.png" --out "$STAGE_ROOT/icon.iconset/icon_${SIZE}x${SIZE}.png" >/dev/null
  DOUBLE=$((SIZE * 2))
  sips -z "$DOUBLE" "$DOUBLE" "$ROOT/icons/where-dat-space.png" --out "$STAGE_ROOT/icon.iconset/icon_${SIZE}x${SIZE}@2x.png" >/dev/null
done
if ! iconutil -c icns "$STAGE_ROOT/icon.iconset" -o "$STAGE/Contents/Resources/WhereDatSpace.icns"; then
  echo 'iconutil is unavailable; packing the resized PNG representations directly.' >&2
  swift "$ROOT/scripts/pack-icon.swift" "$STAGE_ROOT/icon.iconset" "$STAGE/Contents/Resources/WhereDatSpace.icns"
fi
cat > "$STAGE/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>CFBundleIdentifier</key><string>com.mikerosoft.where-dat-space</string>
<key>CFBundleName</key><string>Where Dat Space</string>
<key>CFBundleDisplayName</key><string>Where Dat Space?</string>
<key>CFBundleExecutable</key><string>WhereDatSpace</string>
<key>CFBundleIconFile</key><string>WhereDatSpace.icns</string>
<key>CFBundlePackageType</key><string>APPL</string>
<key>CFBundleShortVersionString</key><string>1.0.0</string>
<key>CFBundleVersion</key><string>1</string>
<key>LSMinimumSystemVersion</key><string>14.0</string>
<key>NSHighResolutionCapable</key><true/>
<key>NSPrincipalClass</key><string>NSApplication</string>
<key>CFBundleDocumentTypes</key><array><dict>
<key>CFBundleTypeName</key><string>Folder</string>
<key>CFBundleTypeRole</key><string>Viewer</string>
<key>LSHandlerRank</key><string>None</string>
<key>LSItemContentTypes</key><array><string>public.folder</string></array>
</dict></array>
<key>NSHumanReadableCopyright</key><string>Copyright © 2026 Mike Cann. MIT licensed.</string>
</dict></plist>
PLIST
IDENTITY="${WHERE_DAT_SPACE_CODESIGN_IDENTITY:-$(security find-identity -v -p codesigning 2>/dev/null | sed -n 's/.*"\(Apple Development:[^"]*\)".*/\1/p' | head -n 1)}"
# Keep the designated requirement stable so privacy grants can survive a rebuild.
codesign --force --timestamp=none --sign "${IDENTITY:--}" --requirements '=designated => identifier "com.mikerosoft.where-dat-space"' "$STAGE"
codesign --verify --strict "$STAGE"
# Validate both destinations before stopping or replacing anything.
if [[ -e "$APP" || -L "$APP" ]]; then
  if [[ -L "$APP" || "$(/usr/libexec/PlistBuddy -c 'Print CFBundleIdentifier' "$APP/Contents/Info.plist" 2>/dev/null || true)" != "$BUNDLE_ID" ]]; then
    echo "An unrelated item exists at $APP. Move it before installing." >&2
    exit 1
  fi
fi
if [[ -e "$CLI" || -L "$CLI" ]]; then
  if [[ ! -L "$CLI" || "$(readlink "$CLI")" != "$APP/Contents/MacOS/WhereDatSpace" ]]; then
    echo "An unrelated command exists at $CLI. Move it before installing." >&2
    exit 1
  fi
fi
for LINK in "$CLAUDE_SKILL" "$CODEX_SKILL"; do
  if [[ -e "$LINK" || -L "$LINK" ]]; then
    if [[ ! -L "$LINK" || "$(readlink "$LINK")" != "$ROOT/skill" ]]; then
      echo "An unrelated item exists at $LINK. Move it before installing." >&2
      exit 1
    fi
  fi
done
stop_app
mkdir -p "$(dirname "$APP")" "$(dirname "$CLI")" "$(dirname "$CLAUDE_SKILL")" "$(dirname "$CODEX_SKILL")"
if [[ -d "$APP" ]]; then rm -rf "$APP"; fi
mv "$STAGE" "$APP"
ln -sfn "$APP/Contents/MacOS/WhereDatSpace" "$CLI"
ln -sfn "$ROOT/skill" "$CLAUDE_SKILL"
ln -sfn "$ROOT/skill" "$CODEX_SKILL"
if [[ "${WHERE_DAT_SPACE_OPEN:-1}" != 0 ]]; then open "$APP"; fi
echo "Installed $APP"
echo "CLI: $CLI"
echo "Skills: $CLAUDE_SKILL and $CODEX_SKILL"
