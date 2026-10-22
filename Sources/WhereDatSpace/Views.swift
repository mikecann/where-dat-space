import SwiftUI
import SpaceCore

struct ContentView: View {
    @Bindable var model: AppModel
    @Environment(\.colorScheme) private var scheme
    var body: some View {
        VStack(spacing: 0) {
            if let volume = model.volume { VolumeView(volume: volume).padding(.horizontal, 18).padding(.vertical, 10) }
            if model.scanning { scanProgress }
            if let tree = model.tree {
                breadcrumbs(tree)
                HSplitView {
                    sidebar(tree).frame(minWidth: 230, idealWidth: 280, maxWidth: 430)
                    GeometryReader { geometry in
                        ZStack(alignment: .topTrailing) {
                            MapView(model: model)
                            if model.rendering { ProgressView().controlSize(.small).padding(10).background(.regularMaterial, in: RoundedRectangle(cornerRadius: 8)).padding(8) }
                            if tree[model.root].size == 0 { ContentUnavailableView("Nothing to map here", systemImage: "square.dashed", description: Text("This folder is empty, uses no allocated space, or could not be read.")) }
                        }
                        .onAppear { model.resize(geometry.size, dark: scheme == .dark) }
                        .onChange(of: geometry.size) { _, size in model.resize(size, dark: scheme == .dark) }
                        .onChange(of: scheme) { _, value in model.resize(geometry.size, dark: value == .dark) }
                    }
                    .frame(minWidth: 450)
                }
                legend(tree)
                status(tree)
            } else if !model.scanning {
                ContentUnavailableView {
                    VStack(spacing: 12) {
                        Image(nsImage: Mascot.image).resizable().interpolation(.high).scaledToFit().frame(width: 112, height: 112)
                            .accessibilityHidden(true)
                        Text("Where did all that space go?")
                    }
                } description: {
                    Text("Pick a folder and let's have a look. Bigger rectangles mean more space on disk.")
                } actions: {
                    // One VStack, or the actions sit side by side and squash the button titles.
                    VStack(spacing: 12) {
                        HStack {
                            Button("Choose Folder…", action: model.chooseFolder)
                            Button("Scan Home") { model.scan(NSHomeDirectory()) }
                            Button("Scan Whole Disk") { model.scan("/System/Volumes/Data") }
                        }.fixedSize()
                        Button("Scan Last Folder") { model.scan(model.lastPath) }.buttonStyle(.link)
                    }
                }.frame(maxWidth: .infinity, maxHeight: .infinity)
            } else { Spacer() }
        }
        .frame(minWidth: 900, minHeight: 600)
        .toolbar {
            ToolbarItemGroup(placement: .navigation) {
                Button(action: model.chooseFolder) { Label("Choose Folder", systemImage: "folder.badge.plus") }.help("Choose a folder to see where its space went (⌘O)")
                Menu {
                    Button("Home") { model.scan(NSHomeDirectory()) }
                    Button("Whole Disk (Data volume)") { model.scan("/System/Volumes/Data") }
                    Button("Last Folder") { model.scan(model.lastPath) }
                } label: { Label("Quick Scan", systemImage: "internaldrive") }
                Button(action: model.rescan) { Label("Rescan", systemImage: "arrow.clockwise") }.help("Have another look at this folder (⌘R)").disabled(model.scanning)
            }
            ToolbarItemGroup {
                Picker("Colour", selection: $model.colorMode) {
                    Text("File Type").tag(ColorMode.type); Text("Top Folder").tag(ColorMode.folder)
                }.pickerStyle(.segmented).frame(width: 190)
                Toggle("Cushions", isOn: $model.cushions).toggleStyle(.checkbox).help("Soft shading to make the nested rectangles easier to see")
            }
        }
        .onChange(of: model.colorMode) { model.requestRender() }
        .onChange(of: model.cushions) { model.requestRender() }
        .onExitCommand { model.goUp() }
        .alert("Where Dat Space?", isPresented: Binding(get: { model.errorMessage != nil }, set: { if !$0 { model.errorMessage = nil } })) {
            Button("OK") { model.errorMessage = nil }
        } message: { Text(model.errorMessage ?? "") }
        .confirmationDialog("Move to Trash?", isPresented: Binding(get: { model.trashCandidate != nil }, set: { if !$0 { model.trashCandidate = nil } }),
                            titleVisibility: .visible, presenting: model.trashCandidate) { id in
            Button("Move to Trash", role: .destructive) { model.trash(id) }
            Button("Cancel", role: .cancel) { model.trashCandidate = nil }
        } message: { id in
            if let tree = model.tree {
                Text("This will move \(tree.path(of: id)) to Trash.\n\(formatBytes(tree[id].size)) allocated on disk. You can restore it from Trash.")
            }
        }
        .sheet(isPresented: $model.showingUnreadable) { unreadableSheet }
    }
    private var scanProgress: some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(scanMessage).font(.callout)
            HStack {
                ProgressView().controlSize(.small)
                Text("\(model.progress.files.formatted()) files · \(model.progress.folders.formatted()) folders · \(formatBytes(model.progress.bytes)) · \(model.progress.elapsed, specifier: "%.1f")s")
                    .font(.system(.callout, design: .monospaced))
                Spacer(); Button("Cancel", action: model.cancelScan)
            }
            Text(model.progress.currentPath).font(.caption).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
        }.padding(12).background(.quaternary)
    }
    // Six-second beats keep the personality from competing with the live counts.
    private var scanMessage: String {
        let messages = [
            "Rummaging through \(model.progress.files.formatted()) files…",
            "Checking down the back of the sofa…",
            "Still looking. Some folders have a lot in them."
        ]
        return messages[Int(model.progress.elapsed / 6) % messages.count]
    }
    private func breadcrumbs(_ tree: DiskTree) -> some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 6) {
                Button(action: model.goUp) { Image(systemName: "arrow.up") }.disabled(model.root == 0).help("Go up (⌘↑ or Escape)")
                ForEach(tree.ancestors(of: model.root), id: \.self) { id in
                    if id != 0 { Image(systemName: "chevron.right").font(.caption2).foregroundStyle(.tertiary) }
                    Button(tree.name(of: id)) { model.zoom(id) }.buttonStyle(.plain).fontWeight(id == model.root ? .semibold : .regular)
                }
            }.padding(.horizontal, 14).padding(.vertical, 9)
        }.background(.bar)
    }
    private func sidebar(_ tree: DiskTree) -> some View {
        let selectedBranch = model.selected.flatMap { selected in
            tree.ancestors(of: selected).first { tree[$0].parent == model.root }
        }
        return ScrollView {
            LazyVStack(spacing: 2) {
                ForEach(model.currentChildren, id: \.self) { id in
                    let node = tree[id]
                    VStack(alignment: .leading, spacing: 5) {
                        HStack(alignment: .firstTextBaseline) {
                            Image(systemName: node.isDirectory ? "folder.fill" : node.isAggregate ? "square.stack.3d.up.fill" : "doc.fill").foregroundStyle(node.isDirectory ? .blue : .secondary)
                            Text(tree.name(of: id)).lineLimit(1).truncationMode(.middle)
                            Spacer(minLength: 4); Text(formatBytes(node.size)).foregroundStyle(.secondary).font(.caption).monospacedDigit()
                        }
                        GeometryReader { geometry in
                            Capsule().fill(Color.accentColor.opacity(0.55)).frame(width: max(1, geometry.size.width * Double(node.size) / Double(max(1, tree[model.root].size))))
                        }.frame(height: 3).padding(.leading, 22)
                    }
                    .padding(.horizontal, 10).padding(.vertical, 8)
                    .background(selectedBranch == id ? Color.accentColor.opacity(0.18) : .clear, in: RoundedRectangle(cornerRadius: 6))
                    .contentShape(Rectangle())
                    .onTapGesture(count: 2) { model.selected = id; model.zoom(id) }
                    .onTapGesture { model.selected = id }
                    .contextMenu { contextMenu(id, tree) }
                }
            }.padding(6)
        }.background(.background)
    }
    @ViewBuilder private func contextMenu(_ id: NodeID, _ tree: DiskTree) -> some View {
        if !tree[id].isAggregate {
            ForEach(FileAction.allCases, id: \.self) { action in
                if action != .zoom || tree[id].isDirectory {
                    Button(action.rawValue, role: action == .trash ? .destructive : nil) { model.contextAction(action, id: id) }
                }
            }
        } else { Text("These smaller files are grouped together. Open their parent folder in Finder to have a look.") }
    }
    private func legend(_ tree: DiskTree) -> some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 14) {
                if model.colorMode == .type {
                    ForEach(FileCategory.allCases, id: \.self) { category in
                        legendItem(category.rawValue, color: category.color)
                    }
                } else {
                    ForEach(Array(model.currentChildren.prefix(12).enumerated()), id: \.element) { rank, id in
                        legendItem(tree.name(of: id), color: FolderColors.color(at: rank))
                    }
                }
            }.padding(.horizontal, 12).padding(.vertical, 8)
        }.background(.bar)
    }
    private func legendItem(_ name: String, color: RGB) -> some View {
        HStack(spacing: 4) { RoundedRectangle(cornerRadius: 2).fill(Color(red: color.r, green: color.g, blue: color.b)).frame(width: 9, height: 9); Text(name).font(.caption) }
    }
    private func status(_ tree: DiskTree) -> some View {
        VStack(spacing: 0) {
            if !model.unreadableFolders.isEmpty {
                HStack {
                    Image(systemName: "lock.shield")
                    Button("\(model.unreadableFolders.count.formatted()) unreadable folders") { model.showingUnreadable = true }.buttonStyle(.link)
                    Text("Some folders wouldn't let us in. Full Disk Access may help.").foregroundStyle(.secondary)
                    Spacer(); Button("Open Full Disk Access", action: model.openFullDiskAccess)
                }.font(.caption).padding(.horizontal, 12).padding(.vertical, 6)
            }
            HStack {
                if let id = model.statusNode {
                    Text(tree.path(of: id) + (tree[id].isAggregate ? "/[\(tree.name(of: id))]" : "")).lineLimit(1).truncationMode(.middle)
                    Spacer(); Text(formatBytes(tree[id].size))
                    Text(String(format: "%.2f%% of view", 100 * Double(tree[id].size) / Double(max(1, tree[model.root].size)))).foregroundStyle(.secondary)
                } else {
                    Text("Found \(formatBytes(tree[model.root].size)) allocated on disk").foregroundStyle(.secondary)
                    Spacer(); Text("Double-click a folder to zoom").foregroundStyle(.tertiary)
                }
            }.font(.caption).padding(.horizontal, 12).padding(.vertical, 8).background(.bar)
        }
    }
    private var unreadableSheet: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Unreadable folders").font(.title2).bold()
            Text("These folders wouldn't let us in, so we carried on with the rest. In System Settings > Privacy & Security > Full Disk Access, add Where Dat Space? and turn it on, then rescan. Some protected folders may still be unreadable.")
            List(model.unreadableFolders, id: \.self) { id in Text(model.tree?.path(of: id) ?? "").font(.system(.caption, design: .monospaced)).textSelection(.enabled) }
            HStack { Button("Open Full Disk Access", action: model.openFullDiskAccess); Spacer(); Button("Done") { model.showingUnreadable = false }.keyboardShortcut(.defaultAction) }
        }.padding(20).frame(width: 700, height: 440)
    }
}
struct VolumeView: View {
    let volume: VolumeSummary
    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            HStack {
                Label(volume.name, systemImage: "internaldrive").fontWeight(.medium)
                Spacer(); Text("\(formatBytes(volume.used)) used of \(formatBytes(volume.capacity))").foregroundStyle(.secondary)
            }.font(.callout)
            GeometryReader { geometry in
                ZStack(alignment: .leading) {
                    Capsule().fill(.quaternary)
                    Capsule().fill(Color.accentColor.gradient).frame(width: geometry.size.width * Double(volume.used) / Double(max(1, volume.capacity)))
                }
            }.frame(height: 8)
            HStack {
                Text("\(formatBytes(volume.available)) available")
                Spacer(); Text("\(formatBytes(volume.importantAvailable)) available for important usage (includes purgeable space)")
            }.font(.caption).foregroundStyle(.secondary)
        }
    }
}
