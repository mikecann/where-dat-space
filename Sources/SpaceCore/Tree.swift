import Foundation
import SpaceScan

public typealias NodeID = UInt32
public let noNode = UInt32.max
public let smallFileThreshold: UInt64 = 512 * 1024

public struct DiskNode: Sendable {
    public var size: UInt64
    public var modified: Int64 = 0
    var fileCount32: UInt32
    public var count: UInt64 {
        get { UInt64(fileCount32) }
        set { precondition(newValue <= UInt32.max); fileCount32 = UInt32(newValue) }
    }
    /// nil means the filesystem did not return sharing metadata for the whole subtree.
    public var mayShareBlocks: Bool? { flags & 16 != 0 ? true : flags & 32 != 0 ? false : nil }
    public var parent: NodeID
    public var firstChild: NodeID
    public var nextSibling: NodeID
    public var nameOffset: UInt32
    public var nameLength: UInt16
    public var fileCount: UInt64 { count }
    public var flags: UInt16
    public var isDirectory: Bool { flags & 1 != 0 }
    public var isAggregate: Bool { flags & 2 != 0 }
    public var isUnreadable: Bool { flags & 4 != 0 }
    public var isRemoved: Bool { flags & 8 != 0 }
}

public struct DiskTree: Sendable {
    public private(set) var nodes: [DiskNode]
    private var names: [UInt8]
    public let rootPath: String

    init(nodes: [DiskNode], names: [UInt8], rootPath: String) {
        self.nodes = nodes; self.names = names; self.rootPath = rootPath
    }

    /// Useful for small synthetic layouts and tests as well as importing scan results.
    public init(rootPath: String) {
        let bytes = Array(rootPath.utf8)
        self.init(nodes: [DiskNode(size: 0, fileCount32: 0, parent: noNode, firstChild: noNode, nextSibling: noNode,
                                  nameOffset: 0, nameLength: UInt16(bytes.count), flags: 1)],
                  names: bytes, rootPath: rootPath)
    }

    @discardableResult public mutating func append(name: String, size: UInt64, parent: NodeID, directory: Bool = false, count: UInt64 = 1, modified: Int64 = 0) -> NodeID {
        let id = NodeID(nodes.count), bytes = Array(name.utf8)
        nodes.append(DiskNode(size: size, modified: modified, fileCount32: directory ? 0 : UInt32(count), parent: parent, firstChild: noNode, nextSibling: nodes[Int(parent)].firstChild,
                              nameOffset: UInt32(names.count), nameLength: UInt16(bytes.count), flags: directory ? 1 : 0))
        names.append(contentsOf: bytes); nodes[Int(parent)].firstChild = id
        var ancestor = parent
        while ancestor != noNode {
            nodes[Int(ancestor)].size += size
            nodes[Int(ancestor)].count += directory ? 0 : count
            nodes[Int(ancestor)].modified = max(nodes[Int(ancestor)].modified, modified)
            ancestor = nodes[Int(ancestor)].parent
        }
        return id
    }

    public subscript(_ id: NodeID) -> DiskNode { nodes[Int(id)] }

    public func name(of id: NodeID) -> String {
        let node = self[id]
        if node.isAggregate { return node.count == 1 ? "1 smaller file" : "\(node.count.formatted()) smaller files" }
        if id == 0 { return rootPath == "/" ? "/" : URL(fileURLWithPath: rootPath).lastPathComponent }
        let start = Int(node.nameOffset)
        return String(decoding: names[start ..< start + Int(node.nameLength)], as: UTF8.self)
    }

    public func children(of id: NodeID, sorted: Bool = true) -> [NodeID] {
        var result: [NodeID] = [], child = self[id].firstChild
        while child != noNode {
            if !self[child].isRemoved { result.append(child) }
            child = self[child].nextSibling
        }
        if sorted { result.sort { self[$0].size == self[$1].size ? $0 < $1 : self[$0].size > self[$1].size } }
        return result
    }

    public func ancestors(of id: NodeID) -> [NodeID] {
        var chain: [NodeID] = [], current = id
        while current != noNode { chain.append(current); current = self[current].parent }
        return chain.reversed()
    }

    public func path(of id: NodeID) -> String {
        var components: [String] = [], current = id
        while current != 0 && current != noNode {
            if !self[current].isAggregate { components.append(name(of: current)) }
            current = self[current].parent
        }
        return components.reversed().reduce(rootPath) { URL(fileURLWithPath: $0).appendingPathComponent($1).path }
    }

    public var unreadableFolders: [NodeID] { nodes.indices.compactMap { nodes[$0].isUnreadable && !nodes[$0].isRemoved ? NodeID($0) : nil } }

    /// IDs remain stable so an existing selection or breadcrumb cannot point at a different file.
    public mutating func remove(_ id: NodeID) {
        guard id != 0, !self[id].isRemoved else { return }
        let size = self[id].size
        var parent = self[id].parent
        while parent != noNode {
            nodes[Int(parent)].size -= min(size, nodes[Int(parent)].size)
            nodes[Int(parent)].count -= min(self[id].count, nodes[Int(parent)].count)
            parent = self[parent].parent
        }
        let owner = self[id].parent
        var child = self[owner].firstChild, previous = noNode
        while child != noNode {
            if child == id {
                if previous == noNode { nodes[Int(owner)].firstChild = self[id].nextSibling }
                else { nodes[Int(previous)].nextSibling = self[id].nextSibling }
                break
            }
            previous = child; child = self[child].nextSibling
        }
        var pending = [id]
        while let current = pending.popLast() {
            pending.append(contentsOf: children(of: current, sorted: false))
            nodes[Int(current)].flags |= 8
        }
    }
}

public func formatBytes(_ bytes: UInt64) -> String {
    ByteCountFormatter.string(fromByteCount: Int64(clamping: bytes), countStyle: .file)
}
