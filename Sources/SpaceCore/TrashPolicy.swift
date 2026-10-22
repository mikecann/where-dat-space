import Foundation
import Darwin

public enum TrashPolicy {
    /// Pure validation; callers also validate the resolved path to reject symlink escapes.
    public static func refusal(path: String, home: String, exists: Bool) -> String? {
        let path = URL(fileURLWithPath: path).standardizedFileURL.path
        let home = URL(fileURLWithPath: home).standardizedFileURL.path
        guard exists else { return "The path does not exist: \(path)" }
        if path == "/" || path == home || path == home + "/Library" || path == "/Volumes" { return "This folder is protected: \(path)" }
        if ["/System", "/Library", "/Applications"].contains(where: { path == $0 || path.hasPrefix($0 + "/") }) {
            return "System and application paths are protected: \(path)"
        }
        guard path.hasPrefix(home + "/") || path.hasPrefix("/Volumes/") else { return "Only items inside your home folder or /Volumes can be moved to Trash: \(path)" }
        return nil
    }

    public static func validatedURL(_ path: String, home: String = NSHomeDirectory()) throws -> URL {
        let url = URL(fileURLWithPath: (path as NSString).expandingTildeInPath).standardizedFileURL
        let exists = FileManager.default.fileExists(atPath: url.path)
        if let reason = refusal(path: url.path, home: home, exists: exists) { throw AgentError.message(reason) }
        if let reason = refusal(path: url.resolvingSymlinksInPath().path, home: URL(fileURLWithPath: home).resolvingSymlinksInPath().path, exists: exists) { throw AgentError.message(reason) }
        // Moving a mounted volume itself could affect every file on it.
        let values = try url.resourceValues(forKeys: [.isVolumeKey])
        if values.isVolume == true { throw AgentError.message("A mounted volume cannot be moved to Trash: \(url.path)") }
        return url
    }

    public static func allocatedBytes(at url: URL) throws -> UInt64 {
        var info = stat()
        guard lstat(url.path, &info) == 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
        if info.st_mode & S_IFMT == S_IFDIR {
            let result = try DiskScanner(path: url.path, largest: 0).run()
            guard result.progress.unreadable == 0 else { throw AgentError.message("Cannot measure every file in \(url.path); refusing to move an unreadable folder.") }
            return result.tree[0].size
        }
        return UInt64(max(0, info.st_blocks)) * 512
    }
}
