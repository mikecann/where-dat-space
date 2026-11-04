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
    /// Folders refreshing in place after a change on disk or a manual Rescan.
    var refreshing = false
    private var watcher: FolderWatcher?
    /// Folders whose own entries changed. Each gets a quick look at just that folder.
    private var changedPaths = Set<String>()
    /// Folders to scan right through: a manual Rescan, or FSEvents saying it dropped events.
    private var deepPaths: [String] = []
    private var lastRefreshEnded = Date.distantPast
    private var refreshRetry: Task<Void, Never>?

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
            // Start watching before the scan so nothing deleted mid-scan is missed.
            watcher?.stop(); changedPaths = []; deepPaths = []; refreshing = false
            watcher = FolderWatcher(path: scanner.path) { [weak self] changes in self?.filesChanged(changes) }
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
                        startRefresh()
                    } else { watcher?.stop(); watcher = nil }
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
    func rescanEverything() { scan(tree?.rootPath ?? lastPath) }
    /// Rescans the folder on screen in place, so you stay zoomed where you are.
    func rescan() {
        guard let tree, root != 0 else { return rescanEverything() }
        rescanInPlace(tree.path(of: root))
    }
    private func rescanInPlace(_ path: String) {
        if !deepPaths.contains(path) { deepPaths.append(path) }
        startRefresh(now: true)
    }
    func zoom(_ id: NodeID) {
        guard let tree, Int(id) < tree.nodes.count, tree[id].isDirectory, !tree[id].isRemoved else { return }
        root = id; selected = nil; hovered = nil; map = nil
        currentChildren = tree.children(of: id); requestRender()
    }

    private func filesChanged(_ changes: [FolderWatcher.Change]) {
        for change in changes {
            if change.deep { if !deepPaths.contains(change.path) { deepPaths.append(change.path) } } else { changedPaths.insert(change.path) }
        }
        startRefresh()
    }
    /// Applies the changes collected so far, then renders once. Automatic refreshes leave a short
    /// gap after the last one, so a folder that never stops changing (logs, caches, a build)
    /// can't keep the scanner and renderer busy.
    private func startRefresh(now: Bool = false) {
        guard tree != nil, !scanning, !refreshing, !changedPaths.isEmpty || !deepPaths.isEmpty else { return }
        let wait = 2 - Date().timeIntervalSince(lastRefreshEnded)
        if !now && wait > 0 {
            if refreshRetry == nil {
                refreshRetry = Task { try? await Task.sleep(for: .seconds(wait)); refreshRetry = nil; startRefresh() }
            }
            return
        }
        refreshing = true
        let generation = scanGeneration
        Task {
            // Hold changes while a Trash confirmation is open, so its item can't move under it.
            while trashCandidate != nil && generation == scanGeneration { try? await Task.sleep(for: .milliseconds(300)) }
            guard generation == scanGeneration, let tree else { return }
            let deep = deepPaths, shallow = tree.changedFolders(for: Array(changedPaths)).map { tree.path(of: $0) }
            deepPaths = []; changedPaths = []
            for path in deep { await refreshFolder(path, deep: true, generation: generation) }
            for path in shallow { await refreshFolder(path, deep: false, generation: generation) }
            guard generation == scanGeneration, let tree = self.tree else { return }
            refreshing = false; lastRefreshEnded = Date()
            volume = VolumeSummary.read(at: tree.rootPath); refreshLists(); requestRender()
            startRefresh(now: !deepPaths.isEmpty)
        }
    }
    /// A shallow refresh lists just this folder, keeping its subfolders as they were, which keeps
    /// a change in a big folder (a file in your home folder, say) from rescanning everything under it.
    private func refreshFolder(_ path: String, deep: Bool, generation: UUID) async {
        let result = await Task.detached(priority: .utility) { try? DiskScanner(path: path, largest: 0, shallow: !deep).run() }.value
        guard generation == scanGeneration, let tree, let id = tree.node(atPath: path), tree[id].isDirectory else { return }
        guard let result, !result.cancelled else {
            // Gone since we last looked, so have a look at its parent instead.
            if id != 0, !FileManager.default.fileExists(atPath: path) { changedPaths.insert(tree.path(of: tree[id].parent)) }
            return
        }
        var newFolders: [String] = []
        editTree { tree in
            if deep { tree.replaceContents(of: id, with: result.tree) }
            else { newFolders = tree.applyListing(of: id, result.tree).map { tree.path(of: $0) } }
        }
        for folder in newFolders { await refreshFolder(folder, deep: true, generation: generation) }
    }
    /// Edits the tree without copying it, then puts the view and selection back by path, as a
    /// refresh can remove the nodes they pointed at (or renumber everything when it compacts).
    private func editTree(_ change: (inout DiskTree) -> Void) {
        guard var tree else { return }
        let rootPath = tree.path(of: root), selectedPath = selected.map { tree.path(of: $0) }
        self.tree = nil
        change(&tree)
        let compacted = tree.needsCompaction
        if compacted { tree.compact(); map = nil }
        root = Self.deepestNode(in: tree, along: rootPath)
        selected = selectedPath.flatMap { tree.node(atPath: $0) }
        if let hovered, compacted || tree[hovered].isRemoved { self.hovered = nil }
        self.tree = tree
    }
    private static func deepestNode(in tree: DiskTree, along path: String) -> NodeID {
        var candidate = path
        while candidate.count > tree.rootPath.count {
            if let id = tree.node(atPath: candidate), tree[id].isDirectory { return id }
            candidate = (candidate as NSString).deletingLastPathComponent
        }
        return 0
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
        case .rescan: rescanInPlace(tree[id].isDirectory ? url.path : url.deletingLastPathComponent().path)
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
                guard generation == scanGeneration, let current = tree, let id = current.node(atPath: path) else { return }
                if current.ancestors(of: root).contains(id) { root = current[id].parent }
                tree?.remove(id); selected = nil; hovered = nil
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
