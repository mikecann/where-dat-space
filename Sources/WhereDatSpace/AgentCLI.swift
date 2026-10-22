import Foundation
import SpaceCore

struct AgentOptions {
    var scan: String?
    var render: String?
    var trash: [String] = []
    var json = false, candidates = false, duplicates = false
    var depth = 3, largest = 25
    var minSize: UInt64 = 1_000_000_000, candidateMin: UInt64 = 100_000_000, dupMin: UInt64 = 100_000_000
    var out: String?, size = "1600x1000", color = "type"

    init(_ arguments: [String]) throws {
        var index = 0
        func argument(_ flag: String) throws -> String {
            index += 1
            guard index < arguments.count, !arguments[index].hasPrefix("--") else { throw AgentError.message("\(flag) requires a value.") }
            return arguments[index]
        }
        func number(_ flag: String, maximum: Int) throws -> Int {
            let text = try argument(flag)
            guard let value = Int(text), value >= 0, value <= maximum else { throw AgentError.message("\(flag) must be between 0 and \(maximum).") }
            return value
        }
        while index < arguments.count {
            let flag = arguments[index]
            switch flag {
            case "--scan": scan = try argument(flag)
            case "--render": render = try argument(flag)
            case "--trash":
                while index + 1 < arguments.count && !arguments[index + 1].hasPrefix("--") { index += 1; trash.append(arguments[index]) }
                guard !trash.isEmpty else { throw AgentError.message("--trash requires at least one explicit path.") }
            case "--json": json = true
            case "--candidates": candidates = true
            case "--duplicates": duplicates = true
            case "--depth": depth = try number(flag, maximum: 64)
            case "--largest": largest = try number(flag, maximum: 10_000)
            case "--min-size": minSize = try parseSize(argument(flag))
            case "--candidate-min": candidateMin = try parseSize(argument(flag))
            case "--dup-min": dupMin = try parseSize(argument(flag))
            case "--out": out = try argument(flag)
            case "--size": size = try argument(flag)
            case "--color": color = try argument(flag)
            default: throw AgentError.message("Unknown argument: \(flag). See --help.")
            }
            index += 1
        }
        guard [scan != nil, render != nil, !trash.isEmpty].filter({ $0 }).count == 1 else { throw AgentError.message("Choose one mode: --scan <folder>, --render <folder>, or --trash <path> [...].") }
        if render != nil && json { throw AgentError.message("--json works with --scan or --trash.") }
        if scan == nil && (candidates || duplicates) { throw AgentError.message("--candidates and --duplicates require --scan.") }
        // Validate render options before doing an expensive scan.
        if render != nil { _ = try renderOptions() }
    }

    func renderOptions() throws -> RenderOptions {
        guard let out, !out.isEmpty else { throw AgentError.message("--render requires --out <file.png>.") }
        let dimensions = size.split(separator: "x", omittingEmptySubsequences: false).compactMap { Int($0) }
        guard dimensions.count == 2, (64...8192).contains(dimensions[0]), (64...8192).contains(dimensions[1]) else { throw AgentError.message("--size must be WIDTHxHEIGHT, between 64 and 8192 pixels.") }
        guard let mode = ColorMode(rawValue: color) else { throw AgentError.message("--color must be type or folder.") }
        return RenderOptions(width: dimensions[0], height: dimensions[1], colorMode: mode)
    }
}

func stderr(_ message: String) { FileHandle.standardError.write(Data((message + "\n").utf8)) }

func writeJSON<T: Encodable>(_ value: T) throws {
    let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
    FileHandle.standardOutput.write(try encoder.encode(value))
    FileHandle.standardOutput.write(Data([10]))
}

struct TrashReport: Encodable {
    let schemaVersion = 1
    let moved: [Item]
    let errors: [Failure]
    let note = "Space is only freed once the Trash is emptied. Shared blocks and snapshots may still retain space."
    struct Item: Encodable { let path: String; let allocatedBytes: UInt64 }
    struct Failure: Encodable { let path: String; let error: String }
}

func trashPaths(_ options: AgentOptions) throws {
    // Validate and measure the entire batch before moving anything. An invalid path never causes a partial move.
    let urls = try options.trash.map { try TrashPolicy.validatedURL($0) }
    for (i, url) in urls.enumerated() {
        if urls.enumerated().contains(where: { $0.offset != i && (url.path == $0.element.path || url.path.hasPrefix($0.element.path + "/")) }) {
            throw AgentError.message("Trash paths overlap: \(url.path). Pass each item only once, without its parent.")
        }
    }
    let sizes = try urls.map { try TrashPolicy.allocatedBytes(at: $0) }
    var moved: [TrashReport.Item] = [], errors: [TrashReport.Failure] = []
    for (url, size) in zip(urls, sizes) {
        do {
            _ = try TrashPolicy.validatedURL(url.path)
            try FileManager.default.trashItem(at: url, resultingItemURL: nil)
            moved.append(.init(path: url.path, allocatedBytes: size))
        } catch { errors.append(.init(path: url.path, error: error.localizedDescription)) }
    }
    let report = TrashReport(moved: moved, errors: errors)
    if options.json { try writeJSON(report) }
    else {
        for item in moved { print("Moved to Trash: \(item.path)\t\(item.allocatedBytes) bytes (\(formatBytes(item.allocatedBytes)))") }
        for error in errors { stderr("Could not move \(error.path): \(error.error)") }
        print(report.note)
    }
    if !errors.isEmpty { throw AgentError.message("Some items could not be moved to Trash; see the results above.") }
}
