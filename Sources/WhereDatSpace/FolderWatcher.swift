import Foundation
import CoreServices

/// Watches a scanned folder with FSEvents and hands back the folders whose contents changed,
/// already translated to the path the tree was scanned under.
final class FolderWatcher {
    /// A folder whose entries changed. `deep` means FSEvents lost track of what changed
    /// underneath it, so the whole folder needs scanning.
    struct Change { let path: String; let deep: Bool }
    private var stream: FSEventStreamRef?
    private let onChange: ([Change]) -> Void
    private let scannedRoot: String
    private let realRoot: String

    init?(path: String, onChange: @escaping ([Change]) -> Void) {
        self.onChange = onChange
        scannedRoot = path
        // FSEvents reports resolved paths (/private/var rather than /var), so map them back.
        realRoot = URL(fileURLWithPath: path).resolvingSymlinksInPath().path
        var context = FSEventStreamContext(version: 0, info: nil, retain: nil, release: nil, copyDescription: nil)
        context.info = Unmanaged.passUnretained(self).toOpaque()
        let callback: FSEventStreamCallback = { _, info, count, paths, flags, _ in
            guard let info else { return }
            let watcher = Unmanaged<FolderWatcher>.fromOpaque(info).takeUnretainedValue()
            let array = Unmanaged<CFArray>.fromOpaque(paths).takeUnretainedValue() as? [String] ?? []
            let deep = FSEventStreamEventFlags(kFSEventStreamEventFlagMustScanSubDirs)
            watcher.deliver(array.prefix(count).enumerated().map { ($1, flags[$0] & deep != 0) })
        }
        // A one second latency lets a burst of deletes (emptying a folder, rm -rf) arrive as one batch.
        guard let stream = FSEventStreamCreate(nil, callback, &context, [path] as CFArray, FSEventStreamEventId(kFSEventStreamEventIdSinceNow), 1.0,
                                               FSEventStreamCreateFlags(kFSEventStreamCreateFlagUseCFTypes)) else { return nil }
        self.stream = stream
        FSEventStreamSetDispatchQueue(stream, .main)
        FSEventStreamStart(stream)
    }

    private func deliver(_ events: [(String, Bool)]) {
        onChange(events.compactMap { path, deep in
            var trimmed = path.count > 1 && path.hasSuffix("/") ? String(path.dropLast()) : path
            // Watching the Data volume reports firmlinked paths (/Users/...), not /System/Volumes/Data/Users/...
            if !Self.isInside(trimmed, realRoot) && !Self.isInside(trimmed, scannedRoot) && scannedRoot.hasPrefix(Self.dataVolume) {
                trimmed = Self.dataVolume + trimmed
            }
            if Self.isInside(trimmed, scannedRoot) { return Change(path: trimmed, deep: deep) }
            if Self.isInside(trimmed, realRoot) { return Change(path: scannedRoot + trimmed.dropFirst(realRoot.count), deep: deep) }
            return nil
        })
    }
    private static let dataVolume = "/System/Volumes/Data"
    private static func isInside(_ path: String, _ root: String) -> Bool { path == root || path.hasPrefix(root == "/" ? "/" : root + "/") }

    func stop() {
        guard let stream else { return }
        FSEventStreamStop(stream); FSEventStreamInvalidate(stream); FSEventStreamRelease(stream)
        self.stream = nil
    }
    deinit { stop() }
}
