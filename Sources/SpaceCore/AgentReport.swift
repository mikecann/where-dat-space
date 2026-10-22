import Foundation

public enum AgentError: LocalizedError {
    case message(String)
    public var errorDescription: String? { switch self { case .message(let text): text } }
}

/// SI units match the app's size labels. Binary units are accepted explicitly too.
public func parseSize(_ text: String) throws -> UInt64 {
    let input = text.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
    let digits = input.prefix { $0.isASCII && ($0.isNumber || $0 == ".") }
    let suffix = String(input.dropFirst(digits.count))
    let units: [String: Decimal] = ["": 1, "B": 1, "K": 1_000, "KB": 1_000, "M": 1_000_000, "MB": 1_000_000,
        "G": 1_000_000_000, "GB": 1_000_000_000, "T": 1_000_000_000_000, "TB": 1_000_000_000_000,
        "KIB": 1_024, "MIB": 1_048_576, "GIB": 1_073_741_824, "TIB": 1_099_511_627_776]
    guard !digits.isEmpty, digits.filter({ $0 == "." }).count <= 1,
          let value = Decimal(string: String(digits), locale: Locale(identifier: "en_US_POSIX")), let unit = units[suffix] else {
        throw AgentError.message("Invalid size '\(text)'. Use bytes, 500MB, 2GB or 1.5G.")
    }
    var bytes = value * unit, rounded = Decimal()
    NSDecimalRound(&rounded, &bytes, 0, .down)
    guard bytes >= 0, bytes <= Decimal(UInt64.max), bytes == rounded else { throw AgentError.message("Size must be a whole number of bytes within UInt64 range.") }
    return NSDecimalNumber(decimal: bytes).uint64Value
}

public func isoTime(_ seconds: Int64) -> String {
    ISO8601DateFormatter().string(from: Date(timeIntervalSince1970: Double(seconds)))
}

public struct FileReport: Codable, Sendable {
    public var path: String
    public var bytes: UInt64
    public var newestModified: String
    public var mayShareBlocks: Bool? = nil
}

public struct TreeReport: Codable, Sendable {
    public var path: String?
    public var name: String?
    public var kind: String
    public var bytes: UInt64
    public var files: UInt64?
    public var newestModified: String?
    public var mayShareBlocks: Bool?
    public var items: Int?
    public var children: [TreeReport]?

    public init(tree: DiskTree, node: NodeID = 0, depth: Int = 3, minSize: UInt64 = 1_000_000_000) {
        let value = tree[node]
        path = tree.path(of: node); name = tree.name(of: node)
        kind = value.isDirectory ? "folder" : value.isAggregate ? "smallFiles" : "file"
        bytes = value.size; files = value.count; newestModified = isoTime(value.modified); mayShareBlocks = value.mayShareBlocks
        if value.isDirectory && depth > 0 {
            var visible: [TreeReport] = [], otherBytes: UInt64 = 0, otherItems = 0
            for child in tree.children(of: node) {
                if tree[child].size < minSize { otherBytes += tree[child].size; otherItems += 1 }
                else { visible.append(TreeReport(tree: tree, node: child, depth: depth - 1, minSize: minSize)) }
            }
            if otherItems > 0 { visible.append(TreeReport(otherBytes: otherBytes, items: otherItems)) }
            children = visible
        }
    }

    private init(otherBytes: UInt64, items: Int) { kind = "other"; bytes = otherBytes; self.items = items }
}

public struct ScanReport: Encodable {
    public let schemaVersion = 1
    public let root: String
    public let scannedAt: String
    public let elapsedSeconds: Double
    public let measure = "allocated"
    public let peakMemoryBytes: UInt64
    public let reclaimability = "Allocated bytes are not guaranteed freed space. APFS files may share blocks; snapshots, hard links outside the scan and concurrent changes can retain data."
    public let volume: Volume?
    public let totals: Totals
    public let unreadable: Unreadable
    public let tree: TreeReport
    public let largestFiles: [FileReport]
    public let candidates: [CleanupCandidate]?
    public let duplicates: [DuplicateGroup]?

    public struct Volume: Encodable {
        let name: String
        let capacity, available, availableForImportantUsage: UInt64
    }
    public struct Totals: Encodable {
        let allocatedBytes, files, folders, unreadableFolders, duplicateHardLinksSkipped: UInt64
    }
    public struct Unreadable: Encodable { let paths: [String]; let truncated: Bool }

    public init(result: ScanResult, depth: Int, minSize: UInt64, candidates: [CleanupCandidate]?, duplicates: [DuplicateGroup]?) {
        root = result.tree.rootPath; scannedAt = isoTime(Int64(result.scannedAt.timeIntervalSince1970)); elapsedSeconds = result.progress.elapsed
        peakMemoryBytes = result.peakMemory
        volume = VolumeSummary.read(at: root).map { Volume(name: $0.name, capacity: $0.capacity, available: $0.available, availableForImportantUsage: $0.importantAvailable) }
        let p = result.progress
        totals = Totals(allocatedBytes: result.tree[0].size, files: p.files, folders: p.folders, unreadableFolders: p.unreadable, duplicateHardLinksSkipped: p.duplicates)
        let denied = result.tree.unreadableFolders
        unreadable = Unreadable(paths: denied.prefix(1000).map { result.tree.path(of: $0) }, truncated: denied.count > 1000)
        tree = TreeReport(tree: result.tree, depth: depth, minSize: minSize)
        largestFiles = result.largestFiles; self.candidates = candidates; self.duplicates = duplicates
    }
}
