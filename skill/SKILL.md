---
name: where-dat-space
description: Find what is using disk space on a Mac, inspect cleanup candidates and confirmed duplicates, and propose a cleanup plan before changing files. Use for disk-space investigations, a full disk, large developer caches or stale project worktrees.
---

Use `where-dat-space` on macOS 14 or later. Scans and duplicate checks are read only. If it is missing, run `bash restart.sh` from this repo to build and install the app, CLI and this skill.

1. Check actual free space and snapshots:
   ```sh
   df -h /System/Volumes/Data
   tmutil listlocalsnapshots /
   ```
   Snapshots, purgeable storage, APFS shared blocks and unreadable folders can explain differences from scan totals. Do not remove snapshots as part of a file cleanup without separate approval.

2. Start a home scan in the background. A big home folder takes about a minute:
   ```sh
   where-dat-space --scan ~ --json --candidates --largest 30 > "$TMPDIR/wds.json" 2> "$TMPDIR/wds.log" &
   wds_pid=$!
   # Do other read-only investigation while it runs, then wait before reading JSON.
   wait "$wds_pid"
   jq '{schemaVersion, volume, totals, elapsedSeconds, unreadable}' "$TMPDIR/wds.json"
   jq '.candidates | .[:20]' "$TMPDIR/wds.json"
   jq '.largestFiles | .[:10]' "$TMPDIR/wds.json"
   ```
   Read with `jq`; do not dump the full report into context. Check the exit status and `wds.log` on failure. Reports contain private filenames, so keep them local. If `$TMPDIR` is unset, use a private temporary directory.

   For the whole Data volume, scan `/System/Volumes/Data`. Drill into a large folder with `--scan <path> --json --depth 2`. Use `--min-size 500MB`, `--candidate-min 100MB` and `--largest 30` as needed. For media-heavy folders, add `--duplicates --dup-min 100MB`; hashing can take much longer than scanning and progress goes to stderr.

3. Build a ranked plan with a table of path, size, confidence, why, exact action and what the user loses. Group it into **regenerable**, **review**, and **keep / don't touch**. Prefer stale items using `newestModified` and `projectNewestModified`. Show a potential total without double-counting overlapping paths or duplicate groups. Candidate matches are outermost only.

   JSON uses `schemaVersion: 1` and allocated bytes. Tree entries below the threshold roll into `other`; depth limits hide descendants. `mayShareBlocks`, where present, flags possible APFS sharing but does not measure how much would be freed. Duplicate `bytes` and `reclaimable` are logical content sizes, with `reclaimableIsEstimate: true` and a `likelyAPFSClones` flag. Do not promise that removing a clone frees its allocated size. Review unreadable folders before drawing conclusions. Candidate rules are suggestions, not proof a folder is disposable. Never recommend deleting agent history just because it is large; other tools may index it.

4. Get the user's explicit OK for the specific items and actions before deleting, pruning or trashing anything. Prefer the tool's cleanup command in `action` (for example `pnpm store prune` or `docker builder prune`). Such commands can affect more than the candidate, so explain their scope. For worktrees, run `git status --short` in each and `git worktree list` in its main repository first; preserve uncommitted and untracked work. Agent history always needs a separate, explicit decision.

   Otherwise use `where-dat-space --trash <path> [<path>...] --json` after approval. It moves only the explicit paths to macOS Trash and refuses protected roots and paths outside home or `/Volumes`. Never use `rm` as a fallback. The CLI has no interactive confirmation, so approval must come before invoking it. Never empty Trash without explicit approval too.

5. Rescan after cleanup and compare the volume's available bytes and scan totals. Report the measured change, not just the sum of planned sizes. Remind the user that trashed files still take space until Trash is emptied; snapshots and shared blocks can retain it afterwards.

6. To show a folder visually, run `where-dat-space --open <path>`.
