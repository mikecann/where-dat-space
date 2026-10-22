import SwiftUI
import AppKit
import SpaceCore

struct MapView: NSViewRepresentable {
    let model: AppModel
    func makeNSView(context: Context) -> TreemapNSView { TreemapNSView() }
    func updateNSView(_ view: TreemapNSView, context: Context) {
        view.map = model.map; view.selection = model.selected; view.hover = model.hovered
        view.tree = model.tree
        view.onHover = { model.hovered = $0 }
        view.onSelect = { model.selected = $0 }
        view.onZoom = { model.zoom($0) }
        view.onZoomUp = { model.goUp() }
        view.onAction = { model.contextAction($0, id: $1) }
        view.needsDisplay = true
    }
}
@MainActor final class TreemapNSView: NSView {
    var map: RenderedMap?
    var tree: DiskTree?
    var selection: NodeID?
    var hover: NodeID?
    var onHover: ((NodeID?) -> Void)?
    var onSelect: ((NodeID?) -> Void)?
    var onZoom: ((NodeID) -> Void)?
    var onAction: ((FileAction, NodeID) -> Void)?
    private var tracking: NSTrackingArea?
    private var menuNode: NodeID?
    override var isFlipped: Bool { true }
    override var acceptsFirstResponder: Bool { true }
    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let tracking { removeTrackingArea(tracking) }
        let area = NSTrackingArea(rect: bounds, options: [.mouseMoved, .mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect], owner: self)
        addTrackingArea(area); tracking = area
    }
    override func draw(_ dirtyRect: NSRect) {
        guard let map, let context = NSGraphicsContext.current?.cgContext else { return }
        context.saveGState(); context.translateBy(x: 0, y: bounds.height); context.scaleBy(x: 1, y: -1)
        context.interpolationQuality = .high; context.draw(map.image, in: bounds); context.restoreGState()
        func outline(_ id: NodeID?, color: NSColor, width: CGFloat) {
            guard let id, let raw = map.rect(for: id) else { return }
            let rect = CGRect(x: raw.minX / CGFloat(map.image.width) * bounds.width, y: raw.minY / CGFloat(map.image.height) * bounds.height,
                              width: raw.width / CGFloat(map.image.width) * bounds.width, height: raw.height / CGFloat(map.image.height) * bounds.height).insetBy(dx: width / 2, dy: width / 2)
            color.setStroke(); let path = NSBezierPath(rect: rect); path.lineWidth = width; path.stroke()
        }
        outline(selection, color: .controlAccentColor, width: 3)
        outline(hover, color: .white, width: 1.5)
    }
    private func node(at event: NSEvent) -> NodeID? {
        guard let map, bounds.width > 0, bounds.height > 0 else { return nil }
        let point = convert(event.locationInWindow, from: nil)
        return map.hitTest(CGPoint(x: point.x / bounds.width * CGFloat(map.image.width), y: point.y / bounds.height * CGFloat(map.image.height)))
    }
    override func mouseMoved(with event: NSEvent) { onHover?(node(at: event)) }
    override func mouseExited(with event: NSEvent) { onHover?(nil) }
    override func mouseDown(with event: NSEvent) {
        window?.makeFirstResponder(self)
        let id = node(at: event); onSelect?(id)
        if event.clickCount == 2, let id { onZoom?(id) }
    }
    override func keyDown(with event: NSEvent) {
        if event.keyCode == 53 { onZoomUp?() } else { super.keyDown(with: event) }
    }
    var onZoomUp: (() -> Void)?
    override func menu(for event: NSEvent) -> NSMenu? {
        guard let id = node(at: event), let tree, !tree[id].isAggregate else { return nil }
        menuNode = id; onSelect?(id)
        let menu = NSMenu()
        for action in FileAction.allCases {
            if action == .zoom && !tree[id].isDirectory { continue }
            if action == .trash && id == 0 { continue }
            if action == .trash { menu.addItem(.separator()) }
            let item = NSMenuItem(title: action.rawValue, action: #selector(menuAction(_:)), keyEquivalent: "")
            item.target = self; item.representedObject = action.rawValue; menu.addItem(item)
        }
        return menu
    }
    @objc private func menuAction(_ item: NSMenuItem) {
        if let raw = item.representedObject as? String, let action = FileAction(rawValue: raw), let menuNode { onAction?(action, menuNode) }
    }
}
