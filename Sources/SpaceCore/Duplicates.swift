import Foundation
import CryptoKit
import Darwin

public struct DuplicateGroup: Codable, Sendable {
    /// Logical content bytes, unlike allocated scan sizes. Reclaimable is a theoretical upper bound.
    public let bytes: UInt64
    public let paths: [String]
    public let reclaimable: UInt64
    public let likelyAPFSClones: Bool
    public let mayShareBlocks: [Bool?]
    public var reclaimableIsEstimate = true
}

public enum DuplicateFinder {
    private struct File {
        let path: String
        let info: stat
        let mayShareBlocks: Bool?
    }

    public static func find(in tree: DiskTree, minSize: UInt64 = 100_000_000, progress: (String) -> Void = { _ in }) -> [DuplicateGroup] {
        var sizes: [Int64: [File]] = [:], seen: Set<String> = []
        for i in tree.nodes.indices {
            let node = tree[NodeID(i)]
            guard !node.isDirectory, !node.isAggregate, !node.isRemoved, node.size >= minSize else { continue }
            let path = tree.path(of: NodeID(i)); var info = stat()
            guard lstat(path, &info) == 0, info.st_mode & S_IFMT == S_IFREG, info.st_size >= 0 else { continue }
            let identity = "\(info.st_dev):\(info.st_ino)"
            guard seen.insert(identity).inserted else { continue }
            sizes[info.st_size, default: []].append(File(path: path, info: info, mayShareBlocks: node.mayShareBlocks))
        }
        var results: [DuplicateGroup] = [], hashed = 0, lastProgress = Date.distantPast
        let potential = sizes.values.reduce(0) { $0 + ($1.count > 1 ? $1.count : 0) }
        progress("Duplicates: checking \(potential) files in same-size groups (read only).")
        for (size, files) in sizes where files.count > 1 {
            var partial: [String: [File]] = [:]
            for file in files {
                hashed += 1
                if Date().timeIntervalSince(lastProgress) >= 2 {
                    progress("Duplicates: partial hash \(hashed)/\(potential): \(file.path)"); lastProgress = Date()
                }
                if let digest = hash(file, partial: true, progress: progress) { partial[digest, default: []].append(file) }
                else { progress("Duplicates: skipped unreadable or changed file: \(file.path)") }
            }
            for matches in partial.values where matches.count > 1 {
                var full: [String: [File]] = [:]
                for file in matches {
                    progress("Duplicates: SHA-256: \(file.path)")
                    if let digest = hash(file, partial: false, progress: progress) { full[digest, default: []].append(file) }
                    else { progress("Duplicates: skipped unreadable or changed file: \(file.path)") }
                }
                for identical in full.values where identical.count > 1 {
                    // Check again after all files in the group have been read.
                    let stable = identical.filter { file in var info = stat(); return lstat(file.path, &info) == 0 && same(file.info, info) }.sorted { $0.path < $1.path }
                    guard stable.count > 1 else { continue }
                    let bytes = UInt64(size)
                    let product = bytes.multipliedReportingOverflow(by: UInt64(stable.count - 1))
                    guard !product.overflow else { continue }
                    results.append(DuplicateGroup(bytes: bytes, paths: stable.map(\.path), reclaimable: product.partialValue,
                        likelyAPFSClones: stable.contains { $0.mayShareBlocks == true },
                        mayShareBlocks: stable.map(\.mayShareBlocks)))
                }
            }
        }
        progress("Duplicates: finished, \(results.count) confirmed groups. Reclaimable bytes are estimates; shared blocks and snapshots may retain space.")
        return results.sorted { $0.reclaimable == $1.reclaimable ? $0.paths[0] < $1.paths[0] : $0.reclaimable > $1.reclaimable }
    }

    private static func same(_ a: stat, _ b: stat) -> Bool {
        a.st_dev == b.st_dev && a.st_ino == b.st_ino && a.st_size == b.st_size && b.st_mode & S_IFMT == S_IFREG &&
        a.st_mtimespec.tv_sec == b.st_mtimespec.tv_sec && a.st_mtimespec.tv_nsec == b.st_mtimespec.tv_nsec &&
        a.st_ctimespec.tv_sec == b.st_ctimespec.tv_sec && a.st_ctimespec.tv_nsec == b.st_ctimespec.tv_nsec
    }

    private static func hash(_ file: File, partial: Bool, progress: (String) -> Void) -> String? {
        let fd = open(file.path, O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC)
        guard fd >= 0 else { return nil }; defer { close(fd) }
        var info = stat(); guard fstat(fd, &info) == 0, same(file.info, info) else { return nil }
        // One fixed buffer and a streaming digest, even for multi-gigabyte files.
        let chunk = 1_048_576
        var buffer = [UInt8](repeating: 0, count: chunk), hash = SHA256()
        let length = Int64(info.st_size)
        var ranges: [(Int64, Int64)] = [(0, length)]
        if partial { ranges = [(0, Swift.min(Int64(chunk), length)), (Swift.max(Int64(chunk), length - Int64(chunk)), length)] }
        var lastProgress = Date()
        for (start, end) in ranges {
            var offset = start
            while offset < end {
                let count = pread(fd, &buffer, min(chunk, Int(end - offset)), off_t(offset))
                if count < 0 && errno == EINTR { continue }
                guard count > 0 else { return nil }
                buffer.withUnsafeBytes { hash.update(bufferPointer: UnsafeRawBufferPointer(rebasing: $0.prefix(count))) }
                offset += Int64(count)
                if Date().timeIntervalSince(lastProgress) >= 2 {
                    progress("Duplicates: read \(offset)/\(info.st_size) bytes: \(file.path)"); lastProgress = Date()
                }
            }
        }
        guard fstat(fd, &info) == 0, same(file.info, info) else { return nil }
        return hash.finalize().map { String(format: "%02x", $0) }.joined()
    }
}
