import Foundation
import SpaceCore
import SwiftUI
import Darwin

func headless(_ arguments: [String]) throws {
    func value(after flag: String) -> String? {
        guard let index = arguments.firstIndex(of: flag), index + 1 < arguments.count else { return nil }
        return arguments[index + 1]
    }
    guard let path = value(after: "--scan") ?? value(after: "--render") else {
        throw CLIError.message("Usage: where-dat-space --scan <folder> | --render <folder> --out <file.png> [--size 1600x1000] [--color type|folder] | --open <folder>\nSee where your disk space went. Headless modes read files without changing them.")
    }
    let scanner = try DiskScanner(path: path)
    let result = try scanner.run(), tree = result.tree, p = result.progress
    print("Path: \(tree.rootPath)\nMeasurement: allocated bytes on disk (hard links counted once; symlinks and other devices skipped)")
    print("Allocated bytes: \(tree[0].size) (\(formatBytes(tree[0].size)))")
    print("Files: \(p.files)\nFolders: \(p.folders)\nNodes: \(tree.nodes.count)\nUnreadable folders: \(p.unreadable)\nDuplicate hard links skipped: \(p.duplicates)")
    print(String(format: "Elapsed seconds: %.3f", p.elapsed))
    print("Peak resident memory bytes: \(result.peakMemory) (\(formatBytes(result.peakMemory)))")
    print("Largest top-level children:")
    for id in tree.children(of: 0).prefix(15) { print("  \(tree[id].size)\t\(formatBytes(tree[id].size))\t\(tree.name(of: id))") }
    if arguments.contains("--render") {
        guard let out = value(after: "--out") else { throw CLIError.message("--render requires --out <file.png>") }
        let size = (value(after: "--size") ?? "1600x1000").split(separator: "x").compactMap { Int($0) }
        guard size.count == 2, (64...8192).contains(size[0]), (64...8192).contains(size[1]) else { throw CLIError.message("--size must be WIDTHxHEIGHT, between 64 and 8192 pixels") }
        guard let mode = ColorMode(rawValue: value(after: "--color") ?? "type") else { throw CLIError.message("--color must be type or folder") }
        let start = Date()
        guard let map = TreemapRenderer.render(tree: tree, options: RenderOptions(width: size[0], height: size[1], colorMode: mode)) else { throw CLIError.message("Could not render treemap") }
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
if arguments.contains("--help") {
    print("Usage: where-dat-space --scan <folder> | --render <folder> --out <file.png> [--size 1600x1000] [--color type|folder] | --open <folder>\nSee where your disk space went. Headless modes read files without changing them.")
} else if arguments.contains("--scan") || arguments.contains("--render") {
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
