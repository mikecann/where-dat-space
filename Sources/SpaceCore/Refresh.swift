import Foundation

/// Refreshing one folder in place: rescan just that folder and splice the result into the
/// existing tree, so the view, breadcrumbs and selection survive and every ancestor's size updates.
extension DiskTree {
    /// The live node at `path`, or nil when the path is outside this tree or wasn't scanned.
    public func node(atPath path: String) -> NodeID? {
        guard let components = relativeComponents(path) else { return nil }
        var current: NodeID = 0
        for component in components {
            guard let next = children(of: current, sorted: false).first(where: { !self[$0].isAggregate && name(of: $0) == component }) else { return nil }
            current = next
        }
        return current
    }

    /// The folders to look at again for a batch of changed paths, as reported by FSEvents.
    /// Each path maps to the deepest folder we know about that still exists on disk: a deleted
    /// folder is picked up through its parent, a brand new one through the nearest folder we know.
    public func changedFolders(for paths: [String], exists: (String) -> Bool = { FileManager.default.fileExists(atPath: $0) }) -> [NodeID] {
        var folders = Set<NodeID>()
        for path in paths {
            guard let components = relativeComponents(path) else { continue }
            var current: NodeID = 0
            for component in components {
                guard let next = children(of: current, sorted: false).first(where: { self[$0].isDirectory && name(of: $0) == component }) else { break }
                current = next
            }
            while current != 0 && !exists(self.path(of: current)) { current = self[current].parent }
            folders.insert(current)
        }
        return folders.sorted()
    }

    /// Updates folder `id` from a shallow scan of just that folder. Its files and small-files
    /// group are replaced, folders that have gone are removed, and folders still there keep
    /// their contents. Returns the folders that are new, as empty nodes ready for a full scan.
    @discardableResult public mutating func applyListing(of id: NodeID, _ listing: DiskTree) -> [NodeID] {
        guard Int(id) < nodes.count, self[id].isDirectory, !self[id].isRemoved, !listing[0].isUnreadable else { return [] }
        var listedFolders: [String: NodeID] = [:]
        for child in listing.children(of: 0, sorted: false) where listing[child].isDirectory { listedFolders[listing.name(of: child)] = child }
        var kept = Set<String>()
        for child in children(of: id, sorted: false) {
            if self[child].isDirectory, let listed = listedFolders[name(of: child)], kept.insert(name(of: child)).inserted {
                // Still there. Pick up a folder that has become readable or unreadable, though.
                if listing[listed].isUnreadable != self[child].isUnreadable { nodes[Int(child)].flags ^= 4 }
            } else { remove(child) }
        }
        var added: [NodeID] = []
        for child in listing.children(of: 0, sorted: false) {
            let node = listing[child], name = listing.name(of: child)
            if node.isDirectory && kept.contains(name) { continue }
            let new = append(name: node.isAggregate ? "" : name, size: node.size, parent: id, directory: node.isDirectory,
                             count: node.isDirectory ? 1 : node.count, modified: node.modified)
            nodes[Int(new)].flags = node.flags
            if node.isDirectory && !node.isUnreadable { added.append(new) }
        }
        nodes[Int(id)].modified = max(nodes[Int(id)].modified, listing[0].modified)
        return added
    }

    /// Replaces the contents of folder `id` with a fresh scan of that folder. `id` and its
    /// ancestors keep their IDs; the old descendants are marked removed. Hard links shared with
    /// files outside the folder can be counted twice, as the fresh scan only sees its own subtree.
    public mutating func replaceContents(of id: NodeID, with fresh: DiskTree) {
        guard Int(id) < nodes.count, self[id].isDirectory, !self[id].isRemoved else { return }
        let old = self[id], new = fresh[0]
        var ancestor = old.parent
        while ancestor != noNode {
            nodes[Int(ancestor)].size = nodes[Int(ancestor)].size - min(old.size, nodes[Int(ancestor)].size) + new.size
            nodes[Int(ancestor)].count = nodes[Int(ancestor)].count - min(old.count, nodes[Int(ancestor)].count) + new.count
            nodes[Int(ancestor)].modified = max(nodes[Int(ancestor)].modified, new.modified)
            ancestor = self[ancestor].parent
        }
        var pending = children(of: id, sorted: false)
        while let current = pending.popLast() {
            pending.append(contentsOf: children(of: current, sorted: false))
            nodes[Int(current)].flags |= 8; removedCount += 1
        }
        let base = NodeID(nodes.count) - 1, nameBase = UInt32(names.count)
        func map(_ child: NodeID) -> NodeID { child == noNode ? noNode : child == 0 ? id : child + base }
        for i in 1..<fresh.nodes.count {
            var node = fresh.nodes[i]
            node.parent = map(node.parent); node.firstChild = map(node.firstChild); node.nextSibling = map(node.nextSibling)
            node.nameOffset += nameBase
            nodes.append(node)
        }
        names.append(contentsOf: fresh.names)
        nodes[Int(id)].size = new.size; nodes[Int(id)].count = new.count; nodes[Int(id)].modified = new.modified
        nodes[Int(id)].firstChild = map(new.firstChild)
        nodes[Int(id)].flags = new.flags & ~8
    }

    /// Whether enough removed nodes have piled up from refreshes to be worth compacting.
    public var needsCompaction: Bool { removedCount > max(200_000, nodes.count / 2) }

    /// Drops removed nodes and their names. Returns a map from old IDs to new ones, with
    /// `noNode` for anything that was removed. The root stays 0.
    @discardableResult public mutating func compact() -> [NodeID] {
        var remap = [NodeID](repeating: noNode, count: nodes.count), next: NodeID = 0
        for i in nodes.indices where !nodes[i].isRemoved { remap[i] = next; next += 1 }
        var newNodes: [DiskNode] = [], newNames: [UInt8] = []
        newNodes.reserveCapacity(Int(next))
        func map(_ id: NodeID) -> NodeID { id == noNode ? noNode : remap[Int(id)] }
        for i in nodes.indices where !nodes[i].isRemoved {
            var node = nodes[i]
            let start = Int(node.nameOffset)
            node.nameOffset = UInt32(newNames.count)
            newNames.append(contentsOf: names[start ..< start + Int(node.nameLength)])
            node.parent = map(node.parent); node.firstChild = map(node.firstChild); node.nextSibling = map(node.nextSibling)
            newNodes.append(node)
        }
        nodes = newNodes; names = newNames; removedCount = 0
        return remap
    }

    private func relativeComponents(_ path: String) -> [String]? {
        let standard = URL(fileURLWithPath: path).standardized.path
        if standard == rootPath { return [] }
        let prefix = rootPath == "/" ? "/" : rootPath + "/"
        guard standard.hasPrefix(prefix) else { return nil }
        return standard.dropFirst(prefix.count).split(separator: "/").map(String.init)
    }
}
