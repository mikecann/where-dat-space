# Agent guidance for Where Dat Space?

This is a native macOS 14+ disk-usage treemap, part of Mikerosoft. Swift 6, SwiftUI/AppKit and a small C scanner, with no third-party dependencies or backend. The public repo is https://github.com/mikecann/where-dat-space.

## Rules

- Never permanently delete scanned files. File removal must use macOS Trash. The UI confirms the exact path and allocated size; agents must get explicit approval for specific CLI Trash paths before invoking it. Keep destructive copy plain and the button labelled Move to Trash.
- Keep the treemap layout and scanner accounting intact when changing branding. Measure allocated bytes, count hard links once, skip symlinks and other volumes, and retain unreadable directories.
- Keep `com.mikerosoft.where-dat-space` and its designated signing requirement stable so Full Disk Access grants can survive rebuilds. Test permissions using the installed bundle.
- Keep binaries, staged app bundles, credentials and private paths out of Git.
- Use plain, friendly copy. The name is the joke; don't put a joke on every label. No em dashes, eyebrows or kickers.
- Use test-first development for non-trivial behaviour changes. Run the relevant checks before committing. PR descriptions start with `## Why`.
- The README Get it prompt must match `makeItYoursPrompt` in the mikerosoft.app site's `src/toolPages.ts` word for word.

## Code layout

- `Sources/WhereDatSpace`: app entry point, scan and selection state, SwiftUI views, AppKit map interaction, headless flags and `AgentCLI.swift` for JSON and safe Trash batches.
- `Sources/SpaceCore`: tree, Swift scanner wrapper, agent reports and size parsing, cleanup rule table, streaming duplicate finder, pure Trash policy, squarified layout, colours and cushion renderer.
- `Sources/SpaceScan`: pthread scanner and public `include/SpaceScan.h`, using `space_` C prefixes.
- `Tests/SpaceCoreTests`: layout, allocation, hard links, sparse files, permissions, folding, cancellation, removal accounting, PNG/hit testing and `AgentTests.swift` for metadata, report pruning, candidate rules, duplicate hashes and Trash refusals.
- `icons/where-dat-space.png`: generated mascot, matching the site's icon. Keep `Sources/WhereDatSpace/Resources/where-dat-space.png` identical for SwiftPM's empty state and About panel.
- `docs/header.webp`: 1376×768 artwork. `docs/screenshot.png`: real app capture, used as the README hero and site media.
- `scripts/pack-icon.swift`: fallback ICNS container writer when the iconutil conversion service is unavailable.
- `skill/SKILL.md`: public agent workflow, installed as owned Claude Code and Codex skill links.
- `restart.sh`: release build, icon bundle, stable signing, installation, CLI and skill links and launch. `uninstall.sh`: remove only this tool's bundle and owned links.

## Build and verify

```bash
swift build
swift test
bash -n restart.sh uninstall.sh scripts/test-install.sh
bash scripts/test-install.sh
bash restart.sh
where-dat-space --scan /Applications
where-dat-space --scan "$PWD" --json --candidates --depth 2 --min-size 1MB > build/scan.json
where-dat-space --scan "$PWD" --json --duplicates --dup-min 1MB > build/duplicates.json
where-dat-space --render /Applications --out build/applications.png --size 1600x1000 --color type
```

Create `build/` before rendering there. For a sandbox, use local module caches and `--disable-sandbox` with Swift commands:

```bash
export CLANG_MODULE_CACHE_PATH="$PWD/.build/module-cache"
export SWIFTPM_MODULECACHE_OVERRIDE="$PWD/.build/module-cache"
swift test --disable-sandbox
```

Use `WHERE_DAT_SPACE_APP_PATH`, `WHERE_DAT_SPACE_CLI_PATH`, `WHERE_DAT_SPACE_CODESIGN_IDENTITY` and `WHERE_DAT_SPACE_OPEN=0` for isolated installer checks. All path overrides are full paths. Set `WHERE_DAT_SPACE_CLAUDE_SKILL_PATH` and `WHERE_DAT_SPACE_CODEX_SKILL_PATH` inside the worktree too for isolated checks. Verify both skill links, repeat installation, and prove unrelated files and links are refused and preserved. Test Trash refusals through the pure policy; never trash existing user files to verify the CLI. Keep temporary test fixtures inside `build/` (set `TMPDIR="$PWD/build/tmp"` after creating it). Verify Info.plist, `.icns`, the resource bundle, CLI link and `codesign --verify --strict`. Report any macOS versions or privacy permissions you couldn't test live.

## Screenshots

Only ever capture this app's window, never the whole screen. `scripts/window-id.swift` identifies an on-screen main window by this bundle ID and PID, and fails if it cannot find one. Keep that failure fatal; never fall back to an unscoped capture.

```bash
window_id="$(swift scripts/window-id.swift)" || exit 1
[[ "$window_id" =~ ^[0-9]+$ ]] || exit 1
screencapture -x -l "$window_id" docs/screenshot.png
```

Inspect the image after capture. Headless `--render` proves the renderer, not the visible app controls or window title. Check the installed app's empty state, progress, summary, About panel and Trash confirmation when changing those views. Never approve a Trash action just to test copy.
