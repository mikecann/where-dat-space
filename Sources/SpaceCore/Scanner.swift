import Foundation
import SpaceScan

public struct ScanProgress: Sendable {
    public init(files: UInt64 = 0, folders: UInt64 = 0, bytes: UInt64 = 0, unreadable: UInt64 = 0, duplicates: UInt64 = 0, elapsed: Double = 0, currentPath: String = "") {
        self.files = files; self.folders = folders; self.bytes = bytes; self.unreadable = unreadable
        self.duplicates = duplicates; self.elapsed = elapsed; self.currentPath = currentPath
    }
    public var files: UInt64 = 0
    public var folders: UInt64 = 0
    public var bytes: UInt64 = 0
    public var unreadable: UInt64 = 0
    public var duplicates: UInt64 = 0
    public var elapsed: Double = 0
    public var currentPath: String = ""
}

public struct ScanResult: Sendable {
    public let scannedAt: Date
    public let largestFiles: [FileReport]
    public let tree: DiskTree
    public let progress: ScanProgress
    public let peakMemory: UInt64
    public let cancelled: Bool
}

/// The C context synchronizes progress and cancellation while its workers own all writes.
public final class DiskScanner: @unchecked Sendable {
    private let context: OpaquePointer
    private let path: String
    private let largestLimit: Int
    private let stateLock = NSLock()
    private var didRun = false
    private var wasCancelled = false

    public init(path: String, workers: Int = min(16, ProcessInfo.processInfo.activeProcessorCount), largest: Int = 25, retainingFilesAtLeast: UInt64 = smallFileThreshold) throws {
        self.largestLimit = min(10_000, max(0, largest))
        self.path = URL(fileURLWithPath: (path as NSString).expandingTildeInPath).standardized.path
        guard let context = space_scan_create(self.path, min(smallFileThreshold, retainingFilesAtLeast), Int32(workers)) else { throw CocoaError(.fileReadUnknown) }
        self.context = context
        let error = space_scan_error(context)
        if error != 0 { throw POSIXError(POSIXErrorCode(rawValue: error) ?? .EIO) }
        space_scan_set_largest(context, largestLimit)
    }
    deinit { space_scan_destroy(context) }

    public func cancel() {
        stateLock.withLock { wasCancelled = true }
        space_scan_cancel(context)
    }

    public func progress() -> ScanProgress {
        var raw = SpaceProgress(); space_scan_progress(context, &raw)
        let path = withUnsafeBytes(of: raw.current_path) { bytes in
            String(decoding: bytes.prefix { $0 != 0 }, as: UTF8.self)
        }
        return ScanProgress(files: raw.files, folders: raw.folders, bytes: raw.bytes, unreadable: raw.unreadable,
                            duplicates: raw.duplicates, elapsed: raw.elapsed, currentPath: path)
    }

    public func run() throws -> ScanResult {
        let firstRun = stateLock.withLock { if didRun { return false }; didRun = true; return true }
        guard firstRun else { throw CocoaError(.featureUnsupported) }
        let error = space_scan_run(context)
        guard error == 0 else { throw POSIXError(POSIXErrorCode(rawValue: error) ?? .EIO) }
        let count = space_scan_node_count(context)
        let raw = UnsafeBufferPointer(start: space_scan_nodes(context), count: count)
        let nodes = raw.map { DiskNode(size: $0.size, modified: $0.modified, fileCount32: $0.count, parent: $0.parent, firstChild: $0.first_child, nextSibling: $0.next_sibling,
                                      nameOffset: $0.name_offset, nameLength: $0.name_length, flags: $0.flags) }
        let names = UnsafeBufferPointer(start: space_scan_names(context), count: space_scan_names_count(context)).map { UInt8(bitPattern: $0) }
        let tree = DiskTree(nodes: nodes, names: names, rootPath: path)
        var largest: [FileReport] = []
        if largestLimit > 0 {
            // Keep this list bounded even when the scan retains millions of file nodes.
            func consider(_ file: FileReport) {
                if largest.count == largestLimit && file.bytes <= largest.last!.bytes { return }
                let position = largest.firstIndex { $0.bytes < file.bytes } ?? largest.count
                largest.insert(file, at: position)
                if largest.count > largestLimit { largest.removeLast() }
            }
            for i in nodes.indices where !nodes[i].isDirectory && !nodes[i].isAggregate {
                if largest.count < largestLimit || nodes[i].size > largest.last!.bytes {
                    consider(FileReport(path: tree.path(of: NodeID(i)), bytes: nodes[i].size, newestModified: isoTime(nodes[i].modified), mayShareBlocks: nodes[i].mayShareBlocks))
                }
            }
            for i in 0..<space_scan_small_largest_count(context) {
                let parent = tree.path(of: space_scan_small_largest_parent(context, i))
                let name = String(cString: space_scan_small_largest_name(context, i))
                consider(FileReport(path: URL(fileURLWithPath: parent).appendingPathComponent(name).path,
                    bytes: space_scan_small_largest_size(context, i), newestModified: isoTime(space_scan_small_largest_modified(context, i)),
                    mayShareBlocks: space_scan_small_largest_sharing(context, i) & 32 != 0 ? space_scan_small_largest_sharing(context, i) & 16 != 0 : nil))
            }
        }
        return ScanResult(scannedAt: Date(), largestFiles: largest, tree: tree, progress: progress(),
                          peakMemory: space_peak_memory(), cancelled: stateLock.withLock { wasCancelled })
    }
    public static var peakMemory: UInt64 { space_peak_memory() }
}

public struct VolumeSummary: Sendable {
    public let name: String
    public let capacity: UInt64
    public let available: UInt64
    public let importantAvailable: UInt64
    public var used: UInt64 { capacity - min(capacity, available) }

    public static func read(at path: String) -> VolumeSummary? {
        let url = URL(fileURLWithPath: path)
        guard let values = try? url.resourceValues(forKeys: [.volumeNameKey, .volumeTotalCapacityKey, .volumeAvailableCapacityKey, .volumeAvailableCapacityForImportantUsageKey]),
              let capacity = values.volumeTotalCapacity, let available = values.volumeAvailableCapacity else { return nil }
        return VolumeSummary(name: values.volumeName ?? url.lastPathComponent, capacity: UInt64(max(0, capacity)),
                             available: UInt64(max(0, available)), importantAvailable: UInt64(max(0, values.volumeAvailableCapacityForImportantUsage ?? Int64(available))))
    }
}
