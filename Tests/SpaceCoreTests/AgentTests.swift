import XCTest
import Foundation
import Darwin
@testable import SpaceCore

final class AgentTests: XCTestCase {
    func testRetainedNodeMemoryBudget() {
        XCTAssertEqual(MemoryLayout<DiskNode>.stride, 40)
    }

    func testSizeParsing() throws {
        for (text, bytes): (String, UInt64) in [("500MB", 500_000_000), ("2GB", 2_000_000_000), ("1.5G", 1_500_000_000), ("42", 42), ("1MiB", 1_048_576)] {
            XCTAssertEqual(try parseSize(text), bytes)
        }
        for invalid in ["-1", "nan", "1XB", "", "1e100", "18446744073709551616", "1.1"] { XCTAssertThrowsError(try parseSize(invalid)) }
    }

    func testPruningAndMetadata() throws {
        var tree = DiskTree(rootPath: "/fixture")
        let folder = tree.append(name: "folder", size: 0, parent: 0, directory: true)
        tree.append(name: "big", size: 900, parent: folder, modified: 100)
        tree.append(name: "small", size: 50, parent: folder, modified: 200)
        tree.append(name: "tiny", size: 50, parent: 0, modified: 300)
        XCTAssertEqual(tree[0].fileCount, 3)
        XCTAssertEqual(tree[folder].fileCount, 2)
        XCTAssertEqual(tree[0].modified, 300)
        let report = TreeReport(tree: tree, depth: 2, minSize: 100)
        XCTAssertEqual(report.children?.reduce(0) { $0 + $1.bytes }, 1000)
        XCTAssertEqual(report.children?.first?.children?.reduce(0) { $0 + $1.bytes }, 950)
        XCTAssertEqual(report.children?.last?.kind, "other")
        XCTAssertNil(TreeReport(tree: tree, depth: 0, minSize: 0).children)
        tree.remove(folder)
        XCTAssertEqual(tree[0].fileCount, 1)
    }

    func testProjectRulesAndOutermostMatch() {
        let markers = [("node_modules", "package.json", "project.node-modules"), (".next", "package.json", "project.next"),
                       ("dist", "package.json", "project.output"), ("build", "build.gradle", "project.output"),
                       (".build", "Package.swift", "project.swiftpm"), ("target", "Cargo.toml", "project.rust"),
                       ("Pods", "Podfile", "project.pods"), (".gradle", "settings.gradle.kts", "project.gradle"),
                       (".venv", "pyproject.toml", "project.venv"), ("venv", "requirements.txt", "project.venv")]
        for (folder, marker, rule) in markers {
            var tree = DiskTree(rootPath: "/fixture/project")
            let output = tree.append(name: folder, size: 0, parent: 0, directory: true)
            tree.append(name: "payload", size: 200_000_000, parent: output, modified: 123)
            XCTAssertTrue(CleanupRules.candidates(in: tree, home: "/fixture", minSize: 0).isEmpty, folder)
            tree.append(name: marker, size: 1, parent: 0, modified: 456)
            let nested = tree.append(name: "node_modules", size: 1, parent: output, directory: true)
            tree.append(name: "package.json", size: 1, parent: output)
            tree.append(name: "payload", size: 1, parent: nested)
            let results = CleanupRules.candidates(in: tree, home: "/fixture", minSize: 0)
            XCTAssertEqual(results.count, 1, folder)
            XCTAssertEqual(results.first?.rule, rule)
            XCTAssertEqual(results.first?.projectNewestModified, isoTime(456))
        }
    }

    func testHomeRules() {
        let fixtures: [(String, String, String)] = [
            ("Library/Developer/Xcode/DerivedData", "xcode.derived-data", "regenerable"),
            ("Library/Developer/Xcode/iOS DeviceSupport", "xcode.device-support", "regenerable"),
            ("Library/Developer/Xcode/Archives", "xcode.archives", "review"),
            ("Library/Developer/CoreSimulator/Devices", "xcode.simulators", "review"),
            ("Library/Developer/CoreSimulator/Caches", "xcode.simulators", "review"),
            ("Library/Caches/example", "cache.app", "regenerable"),
            ("Library/Caches/Homebrew", "cache.homebrew", "regenerable"),
            (".cache/huggingface", "cache.models", "review"), (".cache/pip", "cache.python", "regenerable"),
            (".cache/uv", "cache.python", "regenerable"), (".cache/example", "cache.user", "regenerable"),
            (".npm/_cacache", "cache.npm", "regenerable"), (".bun/install/cache", "cache.bun", "regenerable"),
            ("Library/pnpm/store", "cache.pnpm", "regenerable"), (".gradle/caches", "cache.gradle", "regenerable"),
            (".cargo/registry", "cache.cargo", "regenerable"), (".android/avd", "android.avd", "review"),
            ("Library/Android/sdk/system-images", "android.images", "review"),
            ("Library/Containers/com.docker.docker/Data/vms/0/data/Docker.raw", "docker.disk", "review"),
            (".codex/worktrees", "git.agent-worktrees", "review"), ("dev/repo/.claude/worktrees", "git.agent-worktrees", "review"),
            (".claude/projects", "agent.history", "keep"), (".codex/sessions", "agent.history", "keep"),
            (".codex/archived_sessions", "agent.history", "keep"), (".codex/thread_history_1.sqlite", "agent.history", "keep"), (".Trash", "trash", "regenerable"),
            ("Library/Application Support/MobileSync/Backup", "ios.backups", "review"),
            ("Downloads/big.bin", "personal.download", "review"), ("Movies/old.mov", "personal.old-file", "review")]
        for (path, rule, confidence) in fixtures {
            var tree = DiskTree(rootPath: "/fixture")
            var parent: NodeID = 0
            let parts = path.split(separator: "/").map(String.init)
            for (i, part) in parts.enumerated() {
                let isFile = i == parts.count - 1 && ["Docker.raw", "big.bin", "old.mov", "thread_history_1.sqlite"].contains(part)
                parent = tree.append(name: part, size: i == parts.count - 1 ? 2_000_000_000 : 0, parent: parent, directory: !isFile, modified: 1)
            }
            let result = CleanupRules.candidates(in: tree, home: "/fixture", now: Date(), minSize: 0)
            XCTAssertEqual(result.count, 1, path)
            XCTAssertEqual(result.first?.rule, rule, path)
            XCTAssertEqual(result.first?.confidence, confidence, path)
            XCTAssertTrue(CleanupRules.candidates(in: tree, home: "/fixture", minSize: 3_000_000_000).isEmpty)
        }
    }

    func testScannerPreservesMarkersAndModificationTimes() throws {
        let root = try temporaryFolder()
        defer { try? FileManager.default.removeItem(at: root) }
        try Data("{}".utf8).write(to: root.appendingPathComponent("package.json"))
        let nested = root.appendingPathComponent("node_modules")
        try FileManager.default.createDirectory(at: nested, withIntermediateDirectories: true)
        let file = nested.appendingPathComponent("small.txt")
        try Data(repeating: 1, count: 100).write(to: file)
        let future = Date(timeIntervalSince1970: 2_000_000_000)
        try FileManager.default.setAttributes([.modificationDate: future], ofItemAtPath: file.path)
        let result = try DiskScanner(path: root.path).run()
        XCTAssertEqual(result.tree[0].modified, 2_000_000_000)
        XCTAssertEqual(result.tree[0].fileCount, 2)
        XCTAssertTrue(result.tree.children(of: 0).contains { result.tree.name(of: $0) == "package.json" })
        XCTAssertEqual(CleanupRules.candidates(in: result.tree, minSize: 0).first?.rule, "project.node-modules")
        XCTAssertEqual(result.largestFiles.count, 2)
    }

    func testDuplicatesAndLinkedWorktrees() throws {
        let root = try temporaryFolder()
        defer { try? FileManager.default.removeItem(at: root) }
        // Same ends but a different middle must survive the partial stage and fail the full hash.
        let content = Data(repeating: 0x41, count: 3_000_000)
        var different = content; different[1_500_000] = 0x42
        try content.write(to: root.appendingPathComponent("one"))
        try content.write(to: root.appendingPathComponent("two"))
        try different.write(to: root.appendingPathComponent("different"))
        try FileManager.default.linkItem(at: root.appendingPathComponent("one"), to: root.appendingPathComponent("hardlink"))
        let groups = DuplicateFinder.find(in: try DiskScanner(path: root.path).run().tree, minSize: 1)
        XCTAssertEqual(groups.count, 1)
        XCTAssertEqual(groups.first?.paths.count, 2)
        XCTAssertEqual(groups.first?.bytes, 3_000_000)
        XCTAssertEqual(groups.first?.reclaimable, 3_000_000)
        try Data("gitdir: /fixture/main/.git/worktrees/test\n".utf8).write(to: root.appendingPathComponent(".git"))
        let tree = try DiskScanner(path: root.path).run().tree
        XCTAssertEqual(CleanupRules.candidates(in: tree, minSize: 0).first?.rule, "git.linked-worktree")
    }

    func testSmallDuplicatesWhenRequested() throws {
        let root = try temporaryFolder()
        defer { try? FileManager.default.removeItem(at: root) }
        try Data(repeating: 1, count: 4000).write(to: root.appendingPathComponent("one"))
        try Data(repeating: 1, count: 4000).write(to: root.appendingPathComponent("two"))
        try Data(repeating: 2, count: 4000).write(to: root.appendingPathComponent("different"))
        let tree = try DiskScanner(path: root.path, retainingFilesAtLeast: 1).run().tree
        XCTAssertEqual(DuplicateFinder.find(in: tree, minSize: 1).first?.paths.count, 2)
    }

    func testCloneMetadataWhenAvailable() throws {
        let root = try temporaryFolder()
        defer { try? FileManager.default.removeItem(at: root) }
        let one = root.appendingPathComponent("source"), two = root.appendingPathComponent("clone")
        try Data(repeating: 0x51, count: 2_000_000).write(to: one)
        guard clonefile(one.path, two.path, 0) == 0 else { throw XCTSkip("Volume does not support clonefile") }
        let tree = try DiskScanner(path: root.path).run().tree
        let files = tree.children(of: 0).filter { !tree[$0].isAggregate }
        guard files.allSatisfy({ tree[$0].mayShareBlocks != nil }) else { throw XCTSkip("Volume does not return extended sharing flags") }
        XCTAssertTrue(files.allSatisfy { tree[$0].mayShareBlocks == true })
        XCTAssertEqual(DuplicateFinder.find(in: tree, minSize: 1).first?.likelyAPFSClones, true)
    }

    func testDirectoryMarkersDoNotIdentifyProjectsAndFreshFilesAreKept() {
        var tree = DiskTree(rootPath: "/fixture")
        tree.append(name: "package.json", size: 0, parent: 0, directory: true)
        let dependencies = tree.append(name: "node_modules", size: 200_000_000, parent: 0, directory: true)
        let downloads = tree.append(name: "Downloads", size: 0, parent: 0, directory: true)
        tree.append(name: "new.dmg", size: 2_000_000_000, parent: downloads, modified: Int64(Date().timeIntervalSince1970))
        XCTAssertTrue(CleanupRules.candidates(in: tree, home: "/fixture").isEmpty)
        XCTAssertEqual(tree[dependencies].fileCount, 0)
    }

    func testTrashPolicy() {
        for path in ["/", "/Users/test", "/Users/test/Library", "/Users/test/Library/../Library", "/System/a", "/Library/a", "/Applications", "/Applications/Test.app", "/tmp/file", "/Volumes"] {
            XCTAssertNotNil(TrashPolicy.refusal(path: path, home: "/Users/test", exists: true), path)
        }
        for path in ["/Users/test/Downloads/file", "/Volumes/External/file", "/Users/test/Applications/My.app"] {
            XCTAssertNil(TrashPolicy.refusal(path: path, home: "/Users/test", exists: true), path)
        }
        XCTAssertNotNil(TrashPolicy.refusal(path: "/Users/test/file", home: "/Users/test", exists: false))
        XCTAssertNotNil(TrashPolicy.refusal(path: "/Users/test2/file", home: "/Users/test", exists: true))
    }

    private func temporaryFolder() throws -> URL {
        let root = URL(fileURLWithPath: FileManager.default.currentDirectoryPath).appendingPathComponent("build/tests/\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }
}
