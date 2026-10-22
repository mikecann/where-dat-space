// Prints only this app's main window number for `screencapture -l`.
// Match the running bundle ID and PID, not a window title shared with another app.
import AppKit
import CoreGraphics
let pids = Set(NSRunningApplication.runningApplications(withBundleIdentifier: "com.mikerosoft.where-dat-space").map(\.processIdentifier))
let windows = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] ?? []
let window = windows.first {
    guard let pid = $0[kCGWindowOwnerPID as String] as? Int32,
          let bounds = $0[kCGWindowBounds as String] as? [String: Double] else { return false }
    return pids.contains(pid) && ($0[kCGWindowLayer as String] as? Int) == 0 && (bounds["Width"] ?? 0) >= 900 && (bounds["Height"] ?? 0) >= 600
}
if let id = window?[kCGWindowNumber as String] as? Int { print(id) } else { exit(1) }
