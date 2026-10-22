import SwiftUI
import AppKit
import SpaceCore

@MainActor @Observable final class AppModel {
    var tree: DiskTree?
    var root: NodeID = 0
    var selected: NodeID?
    var hovered: NodeID?
    var progress = ScanProgress()
    var scanning = false
    var volume: VolumeSummary?
    var map: RenderedMap?
    var rendering = false
    var colorMode = ColorMode(rawValue: UserDefaults.standard.string(forKey: "colorMode") ?? "") ?? .type {
        didSet { UserDefaults.standard.set(colorMode.rawValue, forKey: "colorMode") }
    }
    var cushions = UserDefaults.standard.object(forKey: "cushions") as? Bool ?? true {
        didSet { UserDefaults.standard.set(cushions, forKey: "cushions") }
    }
    var errorMessage: String?
    var showingUnreadable = false
    var trashCandidate: NodeID?
    private var scanner: DiskScanner?
    private var scanGeneration = UUID()
    private var trashGeneration: UUID?
    private var renderTask: Task<Void, Never>?
    private var renderCancellation: RenderCancellation?
    private var renderSize = CGSize(width: 1000, height: 750)
    private var dark = true

    var currentChildren: [NodeID] = []
    var unreadableFolders: [NodeID] = []
    private func refreshLists() {
        currentChildren = tree?.children(of: root) ?? []
        unreadableFolders = tree?.unreadableFolders ?? []
    }
    var statusNode: NodeID? { hovered ?? selected }
    var lastPath: String { UserDefaults.standard.string(forKey: "lastFolder") ?? NSHomeDirectory() }

    func chooseFolder() {
        let panel = NSOpenPanel(); panel.canChooseDirectories = true; panel.canChooseFiles = false
        panel.allowsMultipleSelection = false; panel.prompt = "Scan Folder"
        panel.directoryURL = URL(fileURLWithPath: lastPath)
        if panel.runModal() == .OK, let url = panel.url { scan(url.path) }
    }
    func scan(_ path: String) {
        scanner?.cancel(); trashCandidate = nil
        do {
            let scanner = try DiskScanner(path: path)
            self.scanner = scanner; scanning = true; progress = ScanProgress(); errorMessage = nil
            let generation = UUID(); scanGeneration = generation
            UserDefaults.standard.set(path, forKey: "lastFolder")
            volume = VolumeSummary.read(at: path)
            Task {
                let polling = Task {
                    while !Task.isCancelled {
                        if scanGeneration != generation { return }
                        progress = scanner.progress()
                        try? await Task.sleep(for: .milliseconds(150))
                    }
                }
                let result = await Task.detached(priority: .userInitiated) { Result { try scanner.run() } }.value
                polling.cancel()
                guard scanGeneration == generation else { return }
                self.scanner = nil; scanning = false
                switch result {
                case .success(let result):
                    progress = result.progress
                    if !result.cancelled {
                        tree = result.tree; root = 0; selected = nil; hovered = nil; map = nil; refreshLists(); requestRender()
                    }
                case .failure(let error): errorMessage = "Couldn’t scan this folder: \(error.localizedDescription)"
                }
            }
        } catch { scanning = false; errorMessage = "Couldn’t scan this folder: \(error.localizedDescription)" }
    }
    /// `where-dat-space --open <folder>` starts the app already scanning that folder.
    func scanLaunchFolder() {
        guard !handledLaunchFolder else { return }
        handledLaunchFolder = true
        let arguments = CommandLine.arguments
        guard let index = arguments.firstIndex(of: "--open"), index + 1 < arguments.count else { return }
        scan(arguments[index + 1])
    }
    private var handledLaunchFolder = false
    func cancelScan() { scanner?.cancel() }
    func rescan() { scan(tree?.rootPath ?? lastPath) }
    func zoom(_ id: NodeID) {
        guard let tree, Int(id) < tree.nodes.count, tree[id].isDirectory, !tree[id].isRemoved else { return }
        root = id; selected = nil; hovered = nil; map = nil
        currentChildren = tree.children(of: id); requestRender()
    }
    func goUp() {
        guard let tree, root != 0 else { return }
        zoom(tree[root].parent)
    }
    func resize(_ size: CGSize, dark: Bool) {
        let bounded = CGSize(width: max(1, size.width.rounded()), height: max(1, size.height.rounded()))
        guard bounded != renderSize || self.dark != dark else { return }
        renderSize = bounded; self.dark = dark; requestRender()
    }
    func requestRender() {
        renderTask?.cancel(); renderCancellation?.cancel()
        guard let tree else { return }
        let token = RenderCancellation(); renderCancellation = token
        let root = root
        let options = RenderOptions(width: Int(renderSize.width * 2), height: Int(renderSize.height * 2), colorMode: colorMode, cushions: cushions, dark: dark, pixelScale: 2)
        rendering = true
        renderTask = Task {
            do { try await Task.sleep(for: .milliseconds(100)) } catch { return }
            let result = await Task.detached(priority: .userInitiated) {
                TreemapRenderer.render(tree: tree, root: root, options: options, cancelled: { token.isCancelled })
            }.value
            guard !token.isCancelled else { return }
            map = result; rendering = false
        }
    }
    func contextAction(_ action: FileAction, id: NodeID) {
        guard let tree, Int(id) < tree.nodes.count, !tree[id].isRemoved, !tree[id].isAggregate else { return }
        let url = URL(fileURLWithPath: tree.path(of: id))
        switch action {
        case .reveal: NSWorkspace.shared.activateFileViewerSelecting([url])
        case .copy: NSPasteboard.general.clearContents(); NSPasteboard.general.setString(url.path, forType: .string)
        case .zoom: zoom(id)
        case .rescan: scan(tree[id].isDirectory ? url.path : url.deletingLastPathComponent().path)
        case .trash: if id != 0 { trashGeneration = scanGeneration; trashCandidate = id }
        }
    }
    /// Takes the id from the dialog, because SwiftUI may clear `trashCandidate` before the button's action runs.
    func trash(_ id: NodeID) {
        trashCandidate = nil
        guard trashGeneration == scanGeneration, let snapshot = tree, !snapshot[id].isRemoved else { return }
        let path = snapshot.path(of: id), generation = scanGeneration
        Task {
            let result = await Task.detached { Result { try FileManager.default.trashItem(at: URL(fileURLWithPath: path), resultingItemURL: nil) } }.value
            switch result {
            case .success:
                guard generation == scanGeneration else { return }
                tree?.remove(id); selected = nil; hovered = nil
                if snapshot.ancestors(of: root).contains(id) { root = snapshot[id].parent }
                volume = VolumeSummary.read(at: snapshot.rootPath); refreshLists(); requestRender()
            case .failure(let error): errorMessage = "Could not move this item to Trash: \(error.localizedDescription)"
            }
        }
    }
    func openFullDiskAccess() {
        NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_AllFiles")!)
    }
}
enum FileAction: String, CaseIterable {
    case reveal = "Reveal in Finder", copy = "Copy Path", zoom = "Zoom Into", rescan = "Rescan This Folder", trash = "Move to Trash…"
}
private final class RenderCancellation: @unchecked Sendable {
    private let lock = NSLock()
    private var cancelled = false
    var isCancelled: Bool { lock.withLock { cancelled } }
    func cancel() { lock.withLock { cancelled = true } }
}
