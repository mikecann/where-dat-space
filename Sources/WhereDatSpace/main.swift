import Foundation
import SpaceCore
import SwiftUI
import Darwin

func headless(_ arguments: [String]) throws {
    let options = try AgentOptions(arguments)
    if !options.trash.isEmpty { try trashPaths(options); return }
    let scanner = try DiskScanner(path: options.scan ?? options.render!, largest: options.largest,
        retainingFilesAtLeast: options.duplicates ? options.dupMin : smallFileThreshold)
    stderr("Scanning \(options.scan ?? options.render!) (allocated bytes, read only)…")
    let polling = DispatchSource.makeTimerSource(queue: .global(qos: .utility))
    polling.schedule(deadline: .now() + 3, repeating: 3)
    polling.setEventHandler {
        let p = scanner.progress()
        stderr(String(format: "Scanning: %.1fs, %llu files, %llu bytes", p.elapsed, p.files, p.bytes))
    }
    polling.resume()
    let result: ScanResult
    do { result = try scanner.run() } catch { polling.cancel(); throw error }
    polling.cancel()
    let tree = result.tree, p = result.progress
    stderr(String(format: "Scan finished: %.3fs, %llu files, %llu unreadable folders, peak memory %llu bytes", p.elapsed, p.files, p.unreadable, result.peakMemory))
    let candidates = options.candidates ? CleanupRules.candidates(in: tree, minSize: options.candidateMin) : nil
    let duplicates = options.duplicates ? DuplicateFinder.find(in: tree, minSize: options.dupMin, progress: stderr) : nil
    if options.json {
        try writeJSON(ScanReport(result: result, depth: options.depth, minSize: options.minSize, candidates: candidates, duplicates: duplicates))
        return
    }
    print("Path: \(tree.rootPath)\nMeasurement: allocated bytes on disk (hard links counted once; symlinks and other devices skipped)")
    print("Allocated bytes: \(tree[0].size) (\(formatBytes(tree[0].size)))")
    print("Files: \(p.files)\nFolders: \(p.folders)\nNodes: \(tree.nodes.count)\nUnreadable folders: \(p.unreadable)\nDuplicate hard links skipped: \(p.duplicates)")
    print(String(format: "Elapsed seconds: %.3f", p.elapsed))
    print("Peak resident memory bytes: \(result.peakMemory) (\(formatBytes(result.peakMemory)))")
    print("Largest top-level children:")
    for id in tree.children(of: 0).prefix(15) { print("  \(tree[id].size)\t\(formatBytes(tree[id].size))\t\(tree.name(of: id))") }
    if let candidates {
        print("Cleanup candidates (allocated sizes, not guaranteed freed space):")
        print("BYTES\tCONFIDENCE\tPATH\tACTION")
        for candidate in candidates { print("\(candidate.bytes)\t\(candidate.confidence)\t\(candidate.path)\t\(candidate.action)") }
    }
    if let duplicates {
        print("Confirmed duplicate groups (logical sizes; shared blocks may retain space):")
        for group in duplicates { print("\(group.bytes) bytes each; up to \(group.reclaimable) reclaimable; likely APFS clones: \(group.likelyAPFSClones)\n  " + group.paths.joined(separator: "\n  ")) }
    }
    if options.render != nil {
        let out = options.out!
        let renderOptions = try options.renderOptions()
        let start = Date()
        guard let map = TreemapRenderer.render(tree: tree, options: renderOptions) else { throw CLIError.message("Could not render treemap") }
        try map.writePNG(to: URL(fileURLWithPath: out))
        print(String(format: "Render seconds: %.3f", Date().timeIntervalSince(start)))
        print("Rendered regions: \(map.regions.count)\nPNG: \(out)\nPeak resident memory after rendering bytes: \(DiskScanner.peakMemory)")
    }
}
enum CLIError: LocalizedError {
    case message(String)
    var errorDescription: String? {
        switch self { case .message(let message): return message }
    }
}

let arguments = Array(CommandLine.arguments.dropFirst())
let help = """
Usage: where-dat-space --scan <folder> [--json] [--candidates] [--duplicates]
  --depth N             JSON tree depth (default 3, 0...64)
  --min-size SIZE       JSON tree threshold (default 1GB)
  --largest N           Largest individual files (default 25, 0...10000)
  --candidate-min SIZE  Cleanup threshold (default 100MB)
  --dup-min SIZE        Duplicate allocated-size threshold (default 100MB)
  Sizes accept bytes, 500MB, 2GB, 1.5G, or binary units such as 1GiB.
where-dat-space --trash <path> [<path>...] [--json]
  Move explicit items to Trash. Space is freed only after emptying Trash.
  Agents must get explicit user approval for these specific items first.
where-dat-space --render <folder> --out <file.png> [--size 1600x1000] [--color type|folder]
where-dat-space --open <folder>
Scans and duplicate detection are read only. JSON schemaVersion is 1.
"""
if arguments.contains("--help") {
    print(help)
} else if !arguments.isEmpty && !(arguments.count == 2 && arguments[0] == "--open" && !arguments[1].hasPrefix("--")) && !arguments.contains(where: { $0.hasPrefix("-psn_") }) {
    do { try headless(arguments) }
    catch { FileHandle.standardError.write(Data("Where Dat Space?: \(error.localizedDescription)\n".utf8)); exit(1) }
} else if let app = installedApp() {
    // Through the ~/.local/bin link the binary runs outside its bundle, and macOS treats that as a
    // separate, bundle-less app. Hand the folder to the real app instead, even if it's already open.
    let open = Process()
    open.executableURL = URL(fileURLWithPath: "/usr/bin/open")
    open.arguments = ["-a", app.path] + (value(of: "--open", in: arguments).map { [$0] } ?? [])
    try open.run(); open.waitUntilExit(); exit(open.terminationStatus)
} else {
    WhereDatSpaceApp.main()
}

/// The .app this binary lives in, when it was started from outside it (the CLI link).
func installedApp() -> URL? {
    guard Bundle.main.bundleIdentifier == nil, var url = Bundle.main.executableURL?.resolvingSymlinksInPath() else { return nil }
    while url.pathComponents.count > 1 {
        url.deleteLastPathComponent()
        if url.pathExtension == "app" { return url }
    }
    return nil
}
func value(of flag: String, in arguments: [String]) -> String? {
    guard let index = arguments.firstIndex(of: flag), index + 1 < arguments.count else { return nil }
    return URL(fileURLWithPath: (arguments[index + 1] as NSString).expandingTildeInPath).path
}
