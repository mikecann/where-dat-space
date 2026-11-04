import XCTest
import Foundation
@testable import SpaceCore

final class RefreshTests: XCTestCase {
    private func fixture() -> (DiskTree, a: NodeID, b: NodeID, file: NodeID, keep: NodeID) {
        var tree = DiskTree(rootPath: "/fixture")
        let a = tree.append(name: "a", size: 0, parent: 0, directory: true)
        let b = tree.append(name: "b", size: 0, parent: a, directory: true)
        let file = tree.append(name: "file", size: 300, parent: b)
        let keep = tree.append(name: "keep", size: 700, parent: a)
        return (tree, a, b, file, keep)
    }

    func testReplaceContentsUpdatesAncestorsAndKeepsIDs() {
        var (tree, a, b, file, keep) = fixture()
        var fresh = DiskTree(rootPath: "/fixture/a/b")
        fresh.append(name: "new", size: 50, parent: 0)
        let inner = fresh.append(name: "inner", size: 0, parent: 0, directory: true)
        fresh.append(name: "deep", size: 25, parent: inner)
        tree.replaceContents(of: b, with: fresh)
        XCTAssertEqual(tree[0].size, 775); XCTAssertEqual(tree[a].size, 775); XCTAssertEqual(tree[b].size, 75)
        XCTAssertEqual(tree[0].count, 3)
        XCTAssertTrue(tree[file].isRemoved); XCTAssertFalse(tree[b].isRemoved)
        XCTAssertEqual(tree.name(of: b), "b"); XCTAssertEqual(tree.children(of: a), [keep, b])
        let names = tree.children(of: b).map { tree.name(of: $0) }
        XCTAssertEqual(names, ["new", "inner"])
        let deep = try! XCTUnwrap(tree.node(atPath: "/fixture/a/b/inner/deep"))
        XCTAssertEqual(tree[deep].size, 25); XCTAssertEqual(tree.path(of: deep), "/fixture/a/b/inner/deep")
        XCTAssertEqual(tree.removedCount, 1)
    }

    func testEmptyingAFolder() {
        var (tree, a, b, _, _) = fixture()
        tree.replaceContents(of: b, with: DiskTree(rootPath: "/fixture/a/b"))
        XCTAssertEqual(tree[a].size, 700); XCTAssertTrue(tree.children(of: b).isEmpty)
    }

    func testNodeAtPath() {
        let (tree, a, b, file, _) = fixture()
        XCTAssertEqual(tree.node(atPath: "/fixture"), 0)
        XCTAssertEqual(tree.node(atPath: "/fixture/a/"), a)
        XCTAssertEqual(tree.node(atPath: "/fixture/a/b"), b)
        XCTAssertEqual(tree.node(atPath: "/fixture/a/b/file"), file)
        XCTAssertNil(tree.node(atPath: "/fixture/a/missing"))
        XCTAssertNil(tree.node(atPath: "/fixtures/a"))
    }

    func testChangedFoldersUseDeepestExistingFolder() {
        let (tree, a, b, _, _) = fixture()
        let all: (String) -> Bool = { _ in true }
        XCTAssertEqual(tree.changedFolders(for: ["/fixture/a/b"], exists: all), [b])
        // An unknown folder (new since the scan) refreshes the nearest one we know about.
        XCTAssertEqual(tree.changedFolders(for: ["/fixture/a/brand-new/x"], exists: all), [a])
        // A deleted folder is picked up through its parent.
        XCTAssertEqual(tree.changedFolders(for: ["/fixture/a/b"], exists: { $0 != "/fixture/a/b" }), [a])
        XCTAssertEqual(tree.changedFolders(for: ["/fixture/a/b", "/fixture/a", "/fixture/a/b"], exists: all), [a, b])
        XCTAssertEqual(tree.changedFolders(for: ["/elsewhere"], exists: all), [])
    }

    func testApplyListingKeepsFoldersAndReplacesFiles() {
        var tree = DiskTree(rootPath: "/fixture")
        let a = tree.append(name: "a", size: 0, parent: 0, directory: true)
        let kept = tree.append(name: "kept", size: 0, parent: a, directory: true)
        let deep = tree.append(name: "deep", size: 5000, parent: kept)
        let gone = tree.append(name: "gone", size: 0, parent: a, directory: true)
        tree.append(name: "inside-gone", size: 2000, parent: gone)
        let oldFile = tree.append(name: "old.bin", size: 1000, parent: a)
        XCTAssertEqual(tree[0].size, 8000)
        var listing = DiskTree(rootPath: "/fixture/a")
        listing.append(name: "kept", size: 0, parent: 0, directory: true)
        listing.append(name: "fresh", size: 0, parent: 0, directory: true)
        listing.append(name: "new.bin", size: 300, parent: 0)
        let added = tree.applyListing(of: a, listing)
        XCTAssertEqual(tree[0].size, 5300); XCTAssertEqual(tree[a].size, 5300)
        XCTAssertFalse(tree[kept].isRemoved); XCTAssertFalse(tree[deep].isRemoved); XCTAssertEqual(tree[kept].size, 5000)
        XCTAssertTrue(tree[gone].isRemoved); XCTAssertTrue(tree[oldFile].isRemoved)
        XCTAssertEqual(added.map { tree.name(of: $0) }, ["fresh"])
        XCTAssertEqual(Set(tree.children(of: a).map { tree.name(of: $0) }), ["kept", "fresh", "new.bin"])
        XCTAssertEqual(tree[0].count, 2)
    }

    func testCompactionRemapsLiveNodes() {
        var (tree, a, b, file, keep) = fixture()
        tree.remove(b)
        let remap = tree.compact()
        XCTAssertEqual(remap[Int(b)], noNode); XCTAssertEqual(remap[Int(file)], noNode)
        XCTAssertEqual(tree.nodes.count, 3); XCTAssertEqual(tree.removedCount, 0)
        XCTAssertEqual(tree.children(of: remap[Int(a)]), [remap[Int(keep)]])
        XCTAssertEqual(tree.path(of: remap[Int(keep)]), "/fixture/a/keep")
        XCTAssertEqual(tree[0].size, 700)
    }

    func testRefreshAfterDeletingOnDisk() throws {
        let fm = FileManager.default
        let root = fm.temporaryDirectory.appendingPathComponent("space-refresh-\(UUID())", isDirectory: true)
        let inner = root.appendingPathComponent("inner", isDirectory: true)
        try fm.createDirectory(at: inner, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: root) }
        let big = inner.appendingPathComponent("big.bin"), other = root.appendingPathComponent("other.bin")
        try Data(repeating: 7, count: 2_000_000).write(to: big)
        try Data(repeating: 8, count: 1_000_000).write(to: other)
        var tree = try DiskScanner(path: root.path, workers: 2).run().tree
        let before = tree[0].size, innerID = try XCTUnwrap(tree.node(atPath: tree.rootPath + "/inner"))
        try fm.removeItem(at: big)
        for folder in tree.changedFolders(for: [inner.path]) {
            tree.applyListing(of: folder, try DiskScanner(path: tree.path(of: folder), workers: 2, shallow: true).run().tree)
        }
        XCTAssertEqual(tree[innerID].size, 0)
        XCTAssertLessThan(tree[0].size, before)
        XCTAssertNil(tree.node(atPath: tree.rootPath + "/inner/big.bin"))
        XCTAssertNotNil(tree.node(atPath: tree.rootPath + "/other.bin"))
        // A new folder shows up through a shallow look at its parent, then a full scan of it.
        let added = root.appendingPathComponent("added/nested", isDirectory: true)
        try fm.createDirectory(at: added, withIntermediateDirectories: true)
        try Data(repeating: 9, count: 1_500_000).write(to: added.appendingPathComponent("new.bin"))
        for folder in tree.changedFolders(for: [root.path]) {
            let listing = try DiskScanner(path: tree.path(of: folder), workers: 2, shallow: true).run().tree
            XCTAssertEqual(listing.nodes.count, 4)  // root, inner, added, other.bin: shallow means no descending
            for new in tree.applyListing(of: folder, listing) {
                tree.replaceContents(of: new, with: try DiskScanner(path: tree.path(of: new), workers: 2).run().tree)
            }
        }
        let newFile = try XCTUnwrap(tree.node(atPath: tree.rootPath + "/added/nested/new.bin"))
        XCTAssertGreaterThan(tree[newFile].size, 1_000_000)
        let fresh = try DiskScanner(path: root.path, workers: 2).run().tree
        XCTAssertEqual(tree[0].size, fresh[0].size); XCTAssertEqual(tree[0].count, fresh[0].count)
    }
}
