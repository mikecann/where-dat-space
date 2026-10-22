# <img src="icons/where-dat-space.png" width="28" alt=""> Where Dat Space?

A little disk-space detective for the Mac, part of [Mikerosoft](https://mikerosoft.app).

macOS 14 or later

<!-- media: hero -->
![A disk-usage treemap with nested rectangles sized by allocated space](docs/screenshot.png)
<!-- /media: hero -->

## What it is

My 1 TB MacBook kept filling up, so I wanted the GrandPerspective / WinDirStat sort of map I remembered. Big files get big rectangles, and I can zoom in to see what's eating the disk.

## Using it

Choose a folder with **⌘O**, or use **Scan Home** or **Scan Whole Disk**. Whole Disk scans `/System/Volumes/Data` so the same folders don't appear twice through macOS firmlinks. The last folder is remembered, and **⌘R** rescans it.

Hover for a path, allocated size and percentage of the current view. Click to select in the map and size-sorted sidebar. Double-click a folder to zoom in, then use a breadcrumb, **Escape** or **⌘↑** to go back up. Colours can follow file type or top folder. **Cushions** switches the soft shading on and off.

Right-click a file or folder to reveal it in Finder, copy its path or move it to Trash. **Move to Trash** asks for confirmation and shows the full path and allocated size. You can restore the item from Trash. Grouped smaller files can't be trashed together from the app; open their parent folder in Finder to inspect them.

## Get it

Paste this into your AI coding agent (Claude Code, Codex, Cursor...):

> Fork https://github.com/mikecann/where-dat-space to my GitHub account and clone my fork (if I don't use GitHub, or want to keep my copy private, just clone it instead), then make it my own. It's one of Mike Cann's personal tools, so read the README first, change anything specific to his setup to suit mine, then help me get it running.

### Or set it up by hand

You'll need macOS 14 or later, Git, and Xcode or Command Line Tools with Swift 6 or later. If needed, run `xcode-select --install` first. No API keys, backend or network connection are needed to use the app.

```bash
git clone https://github.com/mikecann/where-dat-space.git
cd where-dat-space
bash restart.sh
```

That makes a release build, installs `~/Applications/Where Dat Space.app`, links `~/.local/bin/where-dat-space` to its executable, installs the agent skill links and opens it. Add `~/.local/bin` to your PATH if it isn't already there. The script builds a macOS `.icns` from the mascot PNG and signs with the first available Apple Development identity, falling back to ad-hoc signing. It isn't notarised. If `iconutil`'s conversion service is unavailable in a sandbox, the script packs the same resized PNGs into an `.icns` directly.

The bundle ID is `com.mikerosoft.where-dat-space`, with a stable designated signing requirement so privacy grants can survive rebuilds. Keep using the installed bundle when checking permissions. macOS may still ask you to re-add it after changing signing identities.

`WHERE_DAT_SPACE_APP_PATH` and `WHERE_DAT_SPACE_CLI_PATH` override the full bundle and CLI link paths. `WHERE_DAT_SPACE_CLAUDE_SKILL_PATH` and `WHERE_DAT_SPACE_CODEX_SKILL_PATH` override the full skill link paths. `WHERE_DAT_SPACE_CODESIGN_IDENTITY` overrides the signing identity (`-` for ad-hoc). On Swift toolchains with multiple build engines, `WHERE_DAT_SPACE_BUILD_SYSTEM=native` selects the native engine if the default engine is unavailable in a sandbox. Set `WHERE_DAT_SPACE_OPEN=0` to install without opening a window. For example, to keep an install inside this clone:

```bash
WHERE_DAT_SPACE_APP_PATH="$PWD/build/Where Dat Space.app" \
WHERE_DAT_SPACE_CLI_PATH="$PWD/build/bin/where-dat-space" \
WHERE_DAT_SPACE_CLAUDE_SKILL_PATH="$PWD/build/claude/where-dat-space" \
WHERE_DAT_SPACE_CODEX_SKILL_PATH="$PWD/build/codex/where-dat-space" \
WHERE_DAT_SPACE_OPEN=0 bash restart.sh
```

`bash uninstall.sh` removes the installed app and its owned CLI and skill links. Pass the same path overrides if you used custom locations. It leaves unrelated apps and commands alone.

## Headless commands

```bash
where-dat-space --scan /Applications
where-dat-space --render /Applications --out applications.png --size 1600x1000 --color type
where-dat-space --render /Applications --out folders.png --color folder
where-dat-space --open /Applications
```

`--scan` prints allocated bytes, file and folder counts, retained nodes, unreadable folders, duplicate hard links, elapsed time, peak memory and the 15 largest top-level children. `--render` prints the same summary and writes a PNG with the app's treemap renderer. Neither opens a window or changes the scanned files. Image dimensions default to 1600×1000 and can range from 64 to 8192 per side. `--open` opens the app and scans that folder; `--help` lists the flags.

For development, use `swift run WhereDatSpace` or `.build/release/WhereDatSpace` with the same flags.

## For AI agents

An agent can scan a folder, read the JSON and suggest what to clean up. The scan does not change files. Please check the plan before letting it remove anything.

```bash
where-dat-space --scan ~ --json --candidates --largest 30 > "$TMPDIR/wds.json"
jq '.candidates[:20]' "$TMPDIR/wds.json"
where-dat-space --scan ~/Downloads --json --depth 2 --min-size 500MB
where-dat-space --scan ~/Movies --json --duplicates --dup-min 100MB
# Only after approving these specific files:
where-dat-space --trash ~/Downloads/example.dmg --json
```

`--json` with `--scan` writes one document to stdout; diagnostics go to stderr. `--candidates` adds a size-sorted list of common developer caches, build folders, worktrees and old personal files. Without JSON it prints a table. Rules check project markers such as `package.json` before suggesting build folders, and report only the outermost match. The default minimum is 100 MB (`--candidate-min SIZE`). Each suggestion explains what you lose. `regenerable` means normally rebuilt or downloaded again, `review` needs a decision, and `keep` includes agent histories that other tools may index. These are heuristics, so check the contents and how the project is built.

`--duplicates` checks same-size files with a SHA-256 hash of the first and last 1 MiB, then a full streaming SHA-256 only for partial matches. It skips unreadable or changing files and does not count hard links twice. Memory for file contents is bounded to a 1 MiB buffer. The default minimum allocated file size is 100 MB (`--dup-min SIZE`), so sparsely allocated files below that threshold are excluded. A threshold below 512 KiB retains more individual nodes and uses more metadata memory. Hashing large files can take a while; progress goes to stderr.

`--trash` moves explicit paths with macOS Trash and never deletes permanently. It has no interactive prompt, so agents must get approval for the specific paths first. It validates the whole batch before moving anything and reports any move failures with a non-zero exit. It refuses missing paths, `/`, home itself, `~/Library` itself, system and application paths, mounted volume roots, overlapping paths, and anything outside home or `/Volumes`. Resolved symlink targets are checked too. **Space is only freed once Trash is emptied**, and snapshots or shared blocks can still retain it. Prefer each tool's own cleanup command when one is listed.

### JSON schema, version 1

Field names use camelCase. All byte counts are integer bytes and timestamps are ISO 8601 UTC. New optional fields may be added; incompatible changes need a new `schemaVersion`.

| Field | Contents |
| --- | --- |
| `schemaVersion`, `root`, `scannedAt` | Version `1`, absolute scan root, scan completion time |
| `elapsedSeconds`, `peakMemoryBytes`, `measure` | Scan time, process peak resident memory at scan completion, and `"allocated"` |
| `volume` | `name`, `capacity`, `available`, `availableForImportantUsage`; omitted if unavailable |
| `totals` | `allocatedBytes`, `files`, `folders`, `unreadableFolders`, `duplicateHardLinksSkipped` |
| `unreadable` | `paths` (at most 1,000) and `truncated` |
| `tree` | Nested `path`, `name`, `kind` (`folder`, `file`, `smallFiles`), `bytes`, `files`, `newestModified`, optional `mayShareBlocks` and `children` |
| `largestFiles` | Up to `--largest N` individual files anywhere under the root, each with `path`, `bytes`, `newestModified`, optional `mayShareBlocks` |
| `candidates` | Only with `--candidates`: `path`, `bytes`, `newestModified`, optional `projectNewestModified` and `mayShareBlocks`, `rule`, `category`, `confidence`, `why`, `action`, `loses` |
| `duplicates` | Only with `--duplicates`: groups with logical content `bytes` per file, `paths`, theoretical `reclaimable = (paths.count - 1) × bytes`, `likelyAPFSClones`, aligned `mayShareBlocks` (null for unknown), `reclaimableIsEstimate: true` |
| `reclaimability` | Explains why allocated or duplicate bytes are not guaranteed freed space |

The tree defaults to `--depth 3 --min-size 1GB`. Root is depth zero. At the depth limit, `children` is omitted. Below-threshold children collapse into one `{ "kind": "other", "bytes": ..., "items": ... }` per parent; `items` counts immediate rolled-up entries, including any small-files group. Where children are shown, their bytes add up to their parent's bytes. `--depth 0` gives only the root. `--largest` defaults to 25, can be zero, and is capped at 10,000; depth is capped at 64. Sizes accept plain bytes, `500MB`, `2GB`, `1.5G`, and explicit binary units such as `1GiB`.

Directory `files` counts recursively accounted files, with hard links counted once. `totals.files` also includes skipped duplicate hard links. `newestModified` is the newest modification time of the item or any counted descendant, including folded small files. Project candidates also carry their parent's newest time. Most files under 512 KiB are folded, but project marker files keep their names for rule matching; a bounded list keeps the largest individual small files available too.

On filesystems that return `ATTR_CMNEXT_EXT_FLAGS` in bulk, `mayShareBlocks` reports APFS's shared-block hint and propagates it into directories. It is omitted when unknown, and `false` means the filesystem returned metadata without that hint. It does not identify which files share particular extents. Private-size metadata was tested but made large scans substantially slower, so the normal scan does not request it or claim an exact freed-space estimate. Snapshots, other hard links and files changing during a scan can also retain data. Duplicate sizes are logical content lengths and can overstate reclaimable space for sparse, compressed or cloned files.

Trash JSON uses `schemaVersion: 1`, `moved: [{path, allocatedBytes}]`, `errors: [{path, error}]` and `note`. Validation failures happen before any move, print an error to stderr and exit non-zero; they do not produce a success document.

### Agent skill

[`skill/SKILL.md`](skill/SKILL.md) teaches the scan, review, approval and rescan workflow, including free-space and Time Machine snapshot checks. `bash restart.sh` links it into `~/.claude/skills/where-dat-space` and `~/.codex/skills/where-dat-space`. The links point to this clone, so keep the clone where it is. Installation refuses to replace unrelated files or links; `uninstall.sh` removes only the exact links it owns. Use the path overrides above for an isolated install.

## Full Disk Access

Some folders won't let us in. A scan carries on and lists unreadable folders, with an **Open Full Disk Access** button. In **System Settings > Privacy & Security > Full Disk Access**, add **Where Dat Space?**, turn it on, then rescan. Some protected folders can still be unreadable. For headless runs, your terminal or agent may also need access.

The scanned total can differ from the volume's used space because of skipped folders, APFS snapshots, filesystem metadata and clones sharing blocks. The volume bar also shows space available for important usage, which includes purgeable space.

## How it works

The app measures **allocated bytes on disk**, so sparse and compressed files reflect their allocated storage. Hard links count once, attributed to the first link encountered. It doesn't follow symlinks or cross into other volumes. APFS shared extents are not deduplicated from the allocated total; agent reports flag possible shared blocks when the filesystem provides that metadata.

A small C scanner uses `getattrlistbulk` with up to sixteen workers, with a `readdir` / `fstatat` fallback. Files below **512 KiB allocated** are folded into a mixed entry per directory. The squarified layout fits the rectangles together, and cushion shading makes the nesting easier to see. A cached Core Graphics image keeps hovering and selection light.

## Development

```bash
swift build
swift test
bash -n restart.sh uninstall.sh
```

In a restricted agent sandbox, set `CLANG_MODULE_CACHE_PATH` and `SWIFTPM_MODULECACHE_OVERRIDE` to `$PWD/.build/module-cache`, then use `swift build --disable-sandbox` and `swift test --disable-sandbox`. The installer does this for you.

See [AGENTS.md](AGENTS.md) for code layout and window-only screenshot commands.

MIT licensed. See [LICENSE](LICENSE).
