import XCTest
import Foundation
import Darwin
@testable import SpaceCore

final class LayoutTests: XCTestCase {
    func testAreasContainmentAndNoOverlap() {
        let sizes: [UInt64] = [600, 400, 300, 200, 150, 100, 80, 40, 20, 0]
        let bounds = CGRect(x: 17, y: 31, width: 1200, height: 800)
        let tiles = SquarifiedLayout.layout(sizes.enumerated().map { WeightedItem(id: NodeID($0.offset), size: $0.element) }, in: bounds)
        XCTAssertEqual(tiles.count, 9)
        let total = Double(sizes.reduce(0, +))
        for tile in tiles {
            XCTAssertGreaterThanOrEqual(tile.rect.minX, bounds.minX - 0.0001)
            XCTAssertGreaterThanOrEqual(tile.rect.minY, bounds.minY - 0.0001)
            XCTAssertLessThanOrEqual(tile.rect.maxX, bounds.maxX + 0.0001)
            XCTAssertLessThanOrEqual(tile.rect.maxY, bounds.maxY + 0.0001)
            XCTAssertEqual(tile.rect.width * tile.rect.height / (bounds.width * bounds.height), Double(sizes[Int(tile.id)]) / total, accuracy: 0.000001)
            XCTAssertLessThan(max(tile.rect.width / tile.rect.height, tile.rect.height / tile.rect.width), 4)
        }
        for i in tiles.indices { for j in tiles.indices where j > i {
            let overlap = tiles[i].rect.intersection(tiles[j].rect)
            XCTAssertTrue(overlap.isNull || overlap.width * overlap.height < 0.00001)
        } }
    }
    func testEmptyAndDegenerateInputs() {
        XCTAssertTrue(SquarifiedLayout.layout([WeightedItem(id: 0, size: 0)], in: CGRect(x: 0, y: 0, width: 100, height: 100)).isEmpty)
        XCTAssertTrue(SquarifiedLayout.layout([WeightedItem(id: 0, size: 1)], in: .zero).isEmpty)
    }
    func testManyItemsConserveArea() {
        let items = (1...1000).map { WeightedItem(id: NodeID($0), size: UInt64($0 * $0)) }
        let tiles = SquarifiedLayout.layout(items, in: CGRect(x: 0, y: 0, width: 1600, height: 1000))
        XCTAssertEqual(tiles.reduce(0) { $0 + $1.rect.width * $1.rect.height }, 1_600_000, accuracy: 0.01)
    }
}

final class ScannerTests: XCTestCase {
    func testAllocatedSizesLinksPermissionsAndFolding() throws {
        let fm = FileManager.default
        let root = fm.temporaryDirectory.appendingPathComponent("space-test-\(UUID())", isDirectory: true)
        try fm.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? fm.setAttributes([.posixPermissions: 0o700], ofItemAtPath: root.appendingPathComponent("unreadable").path); try? fm.removeItem(at: root) }
        let nested = root.appendingPathComponent("nested", isDirectory: true)
        let denied = root.appendingPathComponent("unreadable", isDirectory: true)
        try fm.createDirectory(at: nested, withIntermediateDirectories: true)
        try fm.createDirectory(at: denied, withIntermediateDirectories: true)
        let big = nested.appendingPathComponent("big.mov")
        try Data(repeating: 0x51, count: 800_000).write(to: big)
        try fm.linkItem(at: big, to: root.appendingPathComponent("hardlink.mov"))
        try fm.createSymbolicLink(at: root.appendingPathComponent("symlink"), withDestinationURL: nested)
        let small1 = nested.appendingPathComponent("a.txt"), small2 = nested.appendingPathComponent("b.txt")
        try Data(repeating: 1, count: 4000).write(to: small1)
        try Data(repeating: 2, count: 9000).write(to: small2)
        let sparse = root.appendingPathComponent("sparse.img")
        let fd = open(sparse.path, O_CREAT | O_RDWR, 0o600)
        XCTAssertGreaterThanOrEqual(fd, 0); XCTAssertEqual(ftruncate(fd, 80_000_000), 0); close(fd)
        try fm.setAttributes([.posixPermissions: 0], ofItemAtPath: denied.path)
        func allocated(_ url: URL) throws -> UInt64 {
            var st = stat(); guard lstat(url.path, &st) == 0 else { throw POSIXError(.EIO) }; return UInt64(st.st_blocks) * 512
        }
        let expected = try allocated(big) + allocated(small1) + allocated(small2) + allocated(sparse)
        let result = try DiskScanner(path: root.path, workers: 4).run()
        XCTAssertEqual(result.tree[0].size, expected)
        XCTAssertEqual(result.progress.bytes, expected)
        XCTAssertEqual(result.progress.duplicates, 1)
        XCTAssertEqual(result.progress.files, 5)
        XCTAssertEqual(result.progress.folders, 3)
        XCTAssertEqual(result.progress.unreadable, 1)
        XCTAssertEqual(result.tree.unreadableFolders.count, 1)
        XCTAssertFalse(result.tree.nodes.indices.contains { result.tree.name(of: NodeID($0)) == "symlink" })
        let nestedID = try XCTUnwrap(result.tree.children(of: 0).first { result.tree.name(of: $0) == "nested" })
        let aggregate = try XCTUnwrap(result.tree.children(of: nestedID).first { result.tree[$0].isAggregate })
        XCTAssertEqual(result.tree[aggregate].count, 2)
        XCTAssertEqual(result.tree[aggregate].size, try allocated(small1) + allocated(small2))
        XCTAssertEqual(result.tree.path(of: aggregate), nested.path)
    }
    func testParallelWideTree() throws {
        let fm = FileManager.default
        let root = fm.temporaryDirectory.appendingPathComponent("space-wide-\(UUID())")
        try fm.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: root) }
        var expected: UInt64 = 0
        for i in 0..<400 {
            let directory = root.appendingPathComponent("folder-\(i)")
            let nested = directory.appendingPathComponent("nested")
            try fm.createDirectory(at: nested, withIntermediateDirectories: true)
            for url in [directory.appendingPathComponent("a.txt"), nested.appendingPathComponent("b.txt")] {
                try Data(repeating: 1, count: 100).write(to: url)
                var info = stat(); XCTAssertEqual(lstat(url.path, &info), 0)
                expected += UInt64(info.st_blocks) * 512
            }
        }
        for workers in [2, 16] {
            let result = try DiskScanner(path: root.path, workers: workers).run()
            XCTAssertEqual(result.progress.files, 800)
            XCTAssertEqual(result.progress.folders, 801)
            XCTAssertEqual(result.tree.nodes.count, 1601)
            XCTAssertEqual(result.tree[0].size, expected)
            XCTAssertEqual(result.progress.unreadable, 0)
            XCTAssertEqual(result.tree.children(of: 0).count, 400)
        }
    }
    func testCancellationAndInvalidRoot() throws {
        XCTAssertThrowsError(try DiskScanner(path: "/no-such-space-folder-\(UUID())"))
        let scanner = try DiskScanner(path: NSTemporaryDirectory())
        scanner.cancel()
        let result = try scanner.run()
        XCTAssertTrue(result.cancelled)
        XCTAssertEqual(result.progress.files, 0)
        XCTAssertThrowsError(try scanner.run())
    }
}

final class TreeTests: XCTestCase {
    func testRemovalSubtractsFromEveryAncestorAndKeepsIDsStable() {
        var tree = DiskTree(rootPath: "/fixture")
        let a = tree.append(name: "a", size: 0, parent: 0, directory: true)
        let b = tree.append(name: "b", size: 0, parent: a, directory: true)
        let file = tree.append(name: "file", size: 300, parent: b)
        let sibling = tree.append(name: "keep", size: 700, parent: a)
        XCTAssertEqual(tree[0].size, 1000)
        tree.remove(b)
        XCTAssertEqual(tree[0].size, 700); XCTAssertEqual(tree[a].size, 700)
        XCTAssertTrue(tree[b].isRemoved); XCTAssertTrue(tree[file].isRemoved)
        XCTAssertEqual(tree.children(of: a), [sibling])
        tree.remove(b); XCTAssertEqual(tree[0].size, 700)
        XCTAssertEqual(tree.path(of: sibling), "/fixture/a/keep")
    }
    func testRendererAndHitTesting() throws {
        var tree = DiskTree(rootPath: "/fixture")
        let folder = tree.append(name: "video", size: 0, parent: 0, directory: true)
        let file = tree.append(name: "movie.mov", size: 9000, parent: folder)
        tree.append(name: "photo.jpg", size: 1000, parent: 0)
        let map = try XCTUnwrap(TreemapRenderer.render(tree: tree, options: RenderOptions(width: 400, height: 300)))
        let rect = try XCTUnwrap(map.rect(for: file))
        XCTAssertEqual(map.hitTest(CGPoint(x: rect.midX, y: rect.midY)), file)
        XCTAssertNil(map.hitTest(CGPoint(x: -1, y: -1)))
        let png = FileManager.default.temporaryDirectory.appendingPathComponent("space-render-\(UUID()).png")
        defer { try? FileManager.default.removeItem(at: png) }
        try map.writePNG(to: png)
        XCTAssertGreaterThan(try Data(contentsOf: png).count, 2000)
    }
}
