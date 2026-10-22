import Foundation
import Darwin

public struct CleanupCandidate: Codable, Sendable {
    public let path: String
    public let bytes: UInt64
    public let newestModified: String
    public let projectNewestModified: String?
    public let mayShareBlocks: Bool?
    public let rule, category, confidence, why, action, loses: String
}

public enum CleanupRules {
    private struct Context {
        let tree: DiskTree
        let id: NodeID
        let path, home: String
        let now: Date
        var node: DiskNode { tree[id] }
        var name: String { tree.name(of: id) }
        var relative: String { path.hasPrefix(home + "/") ? String(path.dropFirst(home.count + 1)) : "" }
        var parentNames: Set<String> {
            guard node.parent != noNode else { return [] }
            return Set(tree.children(of: node.parent, sorted: false).filter { !tree[$0].isDirectory && !tree[$0].isAggregate }.map { tree.name(of: $0) })
        }
    }
    private struct Rule: Sendable {
        let id, category, confidence, why, action, loses: String
        let project: Bool
        let matches: @Sendable (Context) -> Bool
        init(_ id: String, _ category: String, _ confidence: String, _ why: String, _ action: String, _ loses: String,
             project: Bool = false, matches: @escaping @Sendable (Context) -> Bool) {
            self.id = id; self.category = category; self.confidence = confidence; self.why = why
            self.action = action; self.loses = loses; self.project = project; self.matches = matches
        }
    }

    // First match wins. Specific caches precede general cache folders; all matches stop descent.
    private static let rules: [Rule] = [
        Rule("agent.history", "agent history", "keep", "Other tools may index these sessions, so ask before removing any history.", "Ask before changing agent history", "Conversation history and indexes may stop working") {
            [".claude/projects", ".claude/sessions", ".codex/sessions", ".codex/archived_sessions", ".local/share/opencode", ".local/share/claude", ".gemini/tmp"].contains($0.relative) || $0.relative.hasPrefix(".codex/thread_history") || [".codex/history.jsonl", ".claude/history.jsonl"].contains($0.relative)
        },
        Rule("git.agent-worktrees", "worktrees", "review", "These agent worktrees may contain uncommitted work and must be checked in their main repositories.", "git worktree list; check git status in each worktree, then git worktree remove <path> from its main repository", "Uncommitted work in removed worktrees") {
            $0.node.isDirectory && ($0.relative == ".codex/worktrees" || $0.path.hasSuffix("/.claude/worktrees"))
        },
        Rule("git.linked-worktree", "worktrees", "review", "This is a linked Git worktree, so check for uncommitted work before removing it from the main repository.", "git worktree remove {path}", "Uncommitted work in this worktree") { c in
            guard c.node.isDirectory, c.tree.children(of: c.id, sorted: false).contains(where: { !c.tree[$0].isDirectory && !c.tree[$0].isAggregate && c.tree.name(of: $0) == ".git" }) else { return false }
            // Never load a whole arbitrary .git file or follow a replacement symlink.
            let fd = open(c.path + "/.git", O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC)
            guard fd >= 0 else { return false }; defer { close(fd) }
            var info = stat(); guard fstat(fd, &info) == 0, info.st_mode & S_IFMT == S_IFREG else { return false }
            var buffer = [UInt8](repeating: 0, count: 4096)
            let count = read(fd, &buffer, buffer.count)
            guard count > 0 else { return false }
            let text = String(decoding: buffer.prefix(count), as: UTF8.self)
            return text.hasPrefix("gitdir:") && !text.dropFirst(7).trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        },
        Rule("xcode.derived-data", "Xcode", "regenerable", "Xcode rebuilds these intermediate files when needed.", "Move to Trash", "The next build takes longer") { $0.relative == "Library/Developer/Xcode/DerivedData" },
        Rule("xcode.device-support", "Xcode", "regenerable", "Xcode can recreate device support files when a device reconnects.", "Move to Trash", "Device symbols need to be downloaded or prepared again") { $0.relative.hasPrefix("Library/Developer/Xcode/") && $0.name.hasSuffix(" DeviceSupport") },
        Rule("xcode.archives", "Xcode", "review", "Archives may be needed to export old builds or symbolicate crash reports.", "Move to Trash", "Archived builds and their debug symbols") { $0.relative == "Library/Developer/Xcode/Archives" },
        Rule("xcode.simulators", "Xcode", "review", "Remove unavailable simulators first and review installed runtimes before removing more.", "xcrun simctl delete unavailable; xcrun simctl runtime list", "Data in unavailable simulators; other devices and runtimes remain") { ["Library/Developer/CoreSimulator/Devices", "Library/Developer/CoreSimulator/Caches"].contains($0.relative) },
        Rule("cache.homebrew", "caches", "regenerable", "Homebrew can download cached packages again.", "brew cleanup -s", "Packages may need to be downloaded again") { $0.relative == "Library/Caches/Homebrew" },
        Rule("cache.models", "models", "review", "Downloaded models can be large and may be needed offline.", "Move to Trash", "Models must be downloaded again") { [".cache/huggingface", "Library/Caches/huggingface"].contains($0.relative) },
        Rule("cache.python", "caches", "regenerable", "Python package caches are downloaded or built again when needed.", "Move to Trash", "Packages need to be downloaded or built again") { [".cache/pip", ".cache/uv", "Library/Caches/pip", "Library/Caches/uv"].contains($0.relative) },
        Rule("cache.pnpm", "caches", "regenerable", "pnpm can prune packages no longer referenced by projects.", "pnpm store prune", "Unused packages need to be downloaded again") { ["Library/pnpm/store", ".local/share/pnpm/store", ".pnpm-store"].contains($0.relative) },
        Rule("cache.npm", "caches", "regenerable", "npm can download these cached packages again.", "npm cache clean --force", "Packages need to be downloaded again") { $0.relative == ".npm/_cacache" },
        Rule("cache.bun", "caches", "regenerable", "Bun can download these cached packages again.", "bun pm cache rm", "Packages need to be downloaded again") { $0.relative == ".bun/install/cache" },
        Rule("cache.gradle", "caches", "regenerable", "Gradle recreates its dependency and build caches.", "Move to Trash", "The next build downloads dependencies and takes longer") { $0.relative == ".gradle/caches" },
        Rule("cache.cargo", "caches", "regenerable", "Cargo can download these registry packages again.", "Move to Trash", "Crates need to be downloaded again") { $0.relative == ".cargo/registry" },
        Rule("cache.app", "caches", "regenerable", "Applications normally recreate their cache files.", "Move to Trash", "The app may rebuild or download cached data") { c in c.node.isDirectory && c.relative.hasPrefix("Library/Caches/") && c.relative.split(separator: "/").count == 3 },
        Rule("cache.user", "caches", "regenerable", "Tools normally recreate their cache files.", "Move to Trash", "The tool may rebuild or download cached data") { c in c.node.isDirectory && c.relative.hasPrefix(".cache/") && c.relative.split(separator: "/").count == 2 },
        Rule("android.avd", "Android", "review", "Android virtual devices may contain app and test data you want to keep.", "Move to Trash", "Virtual devices and their saved data") { $0.relative == ".android/avd" },
        Rule("android.images", "Android", "review", "Android emulator system images can be downloaded again if still available.", "Move to Trash", "Installed emulator system images") { $0.relative == "Library/Android/sdk/system-images" || $0.path.hasSuffix("/Android/Sdk/system-images") },
        Rule("docker.disk", "Docker", "review", "Prune unused Docker data through Docker rather than removing its disk image.", "docker system prune; docker builder prune", "Unused containers, networks, images and build caches after Docker confirmation") { $0.name == "Docker.raw" && $0.relative.hasPrefix("Library/Containers/com.docker.docker/Data/") },
        Rule("ios.backups", "device backups", "review", "These device backups may be your only local restore copy.", "Move to Trash", "Local iPhone and iPad restore backups") { $0.relative == "Library/Application Support/MobileSync/Backup" },
        Rule("trash", "Trash", "regenerable", "These files are already in Trash, but emptying it permanently removes them.", "Empty Trash", "The ability to restore these files from Trash") { $0.relative == ".Trash" },
        Rule("project.node-modules", "project dependencies", "regenerable", "The project manifest lets its package manager install dependencies again.", "Move to Trash", "Dependencies need to be installed again", project: true) { $0.node.isDirectory && $0.name == "node_modules" && $0.parentNames.contains("package.json") },
        Rule("project.next", "project build", "regenerable", "Next.js recreates its build output and cache.", "Move to Trash", "The next build takes longer", project: true) { $0.node.isDirectory && $0.name == ".next" && $0.parentNames.contains("package.json") },
        Rule("project.swiftpm", "project build", "regenerable", "Swift Package Manager recreates this build folder.", "Move to Trash", "The next build downloads dependencies and takes longer", project: true) { $0.node.isDirectory && $0.name == ".build" && $0.parentNames.contains("Package.swift") },
        Rule("project.rust", "project build", "regenerable", "Cargo recreates this build output.", "Move to Trash", "The next build takes longer", project: true) { $0.node.isDirectory && $0.name == "target" && $0.parentNames.contains("Cargo.toml") },
        Rule("project.pods", "project dependencies", "regenerable", "CocoaPods can install these dependencies from the project manifest.", "Move to Trash", "Dependencies need to be installed again", project: true) { $0.node.isDirectory && $0.name == "Pods" && $0.parentNames.contains("Podfile") },
        Rule("project.gradle", "project build", "regenerable", "Gradle recreates this project's local cache.", "Move to Trash", "The next build takes longer", project: true) { $0.node.isDirectory && $0.name == ".gradle" && !$0.parentNames.isDisjoint(with: ["build.gradle", "build.gradle.kts", "settings.gradle", "settings.gradle.kts"]) },
        Rule("project.venv", "project dependencies", "regenerable", "The Python project manifest can be used to recreate this virtual environment.", "Move to Trash", "Python dependencies need to be installed again", project: true) { $0.node.isDirectory && [".venv", "venv"].contains($0.name) && !$0.parentNames.isDisjoint(with: ["pyproject.toml", "requirements.txt", "setup.py", "Pipfile"]) },
        // dist/build are deliberately review: some projects keep hand-written or release files here.
        Rule("project.output", "project build", "review", "This looks like project output, but check for hand-written or release files before removing it.", "Move to Trash", "Build output and any files saved manually here", project: true) { $0.node.isDirectory && ["dist", "build"].contains($0.name) && !$0.parentNames.isDisjoint(with: ["package.json", "Package.swift", "build.gradle", "build.gradle.kts"]) },
        Rule("personal.download", "personal files", "review", "This large download has not been modified for at least 90 days.", "Move to Trash", "The downloaded file; check that another copy is available") { !$0.node.isDirectory && !$0.node.isAggregate && $0.relative.hasPrefix("Downloads/") && $0.node.size >= 500_000_000 && Double($0.node.modified) <= $0.now.timeIntervalSince1970 - 90 * 86400 },
        Rule("personal.old-file", "personal files", "review", "This large media file, disk image or archive has not been modified for at least 180 days.", "Move to Trash", "The file; check that another copy is available") { c in
            !c.node.isDirectory && !c.node.isAggregate && c.node.size >= 1_000_000_000 && Double(c.node.modified) <= c.now.timeIntervalSince1970 - 180 * 86400 &&
            ["mov", "mp4", "mkv", "avi", "m4v", "dmg", "iso", "img", "zip", "tar", "gz", "7z", "rar"].contains((c.name as NSString).pathExtension.lowercased())
        }
    ]

    public static func candidates(in tree: DiskTree, home: String = NSHomeDirectory(), now: Date = Date(), minSize: UInt64 = 100_000_000) -> [CleanupCandidate] {
        var pending: [(NodeID, String)] = [(0, tree.rootPath)], results: [CleanupCandidate] = []
        while let (id, path) = pending.popLast() {
            let node = tree[id]
            guard !node.isRemoved, !node.isAggregate, node.size >= minSize else { continue }
            let context = Context(tree: tree, id: id, path: path, home: home, now: now)
            if let rule = rules.first(where: { $0.matches(context) }) {
                results.append(CleanupCandidate(path: path, bytes: node.size, newestModified: isoTime(node.modified),
                    projectNewestModified: rule.project && node.parent != noNode ? isoTime(tree[node.parent].modified) : nil,
                    mayShareBlocks: node.mayShareBlocks, rule: rule.id, category: rule.category, confidence: rule.confidence,
                    why: rule.why, action: rule.action.replacingOccurrences(of: "{path}", with: shellQuote(path)), loses: rule.loses))
            } else if node.isDirectory {
                for child in tree.children(of: id, sorted: false) { pending.append((child, path == "/" ? "/" + tree.name(of: child) : path + "/" + tree.name(of: child))) }
            }
        }
        return results.sorted { $0.bytes == $1.bytes ? $0.path < $1.path : $0.bytes > $1.bytes }
    }
}

public func shellQuote(_ path: String) -> String { "'" + path.replacingOccurrences(of: "'", with: "'\\''") + "'" }
