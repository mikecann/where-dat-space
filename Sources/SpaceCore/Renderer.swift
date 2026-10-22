import Foundation
import CoreGraphics
import CoreText
import ImageIO
import UniformTypeIdentifiers

public struct RenderOptions: Sendable, Equatable {
    public var width: Int
    public var height: Int
    public var colorMode: ColorMode
    public var cushions: Bool
    public var dark: Bool
    public var pixelScale: Double
    public init(width: Int = 1600, height: Int = 1000, colorMode: ColorMode = .type, cushions: Bool = true, dark: Bool = true, pixelScale: Double = 1) {
        self.width = width; self.height = height; self.colorMode = colorMode; self.cushions = cushions; self.dark = dark; self.pixelScale = pixelScale
    }
}
public struct RenderRegion: Sendable {
    public let id: NodeID
    public let rect: CGRect
}
/// CGImage is immutable after construction and safe to hand back to the main actor.
public final class RenderedMap: @unchecked Sendable {
    public let image: CGImage
    public let regions: [RenderRegion]
    private let buckets: [[Int]]
    private let columns: Int
    private let rows: Int
    public init(image: CGImage, regions: [RenderRegion]) {
        self.image = image; self.regions = regions
        columns = max(1, (image.width + 47) / 48); rows = max(1, (image.height + 47) / 48)
        var grid = [[Int]](repeating: [], count: columns * rows)
        for (index, region) in regions.enumerated() {
            let x0 = max(0, min(columns - 1, Int(region.rect.minX / 48)))
            let x1 = max(x0, min(columns - 1, Int(region.rect.maxX / 48)))
            let y0 = max(0, min(rows - 1, Int(region.rect.minY / 48)))
            let y1 = max(y0, min(rows - 1, Int(region.rect.maxY / 48)))
            for y in y0...y1 { for x in x0...x1 { grid[y * columns + x].append(index) } }
        }
        buckets = grid
    }
    public func hitTest(_ point: CGPoint) -> NodeID? {
        let x = Int(point.x / 48), y = Int(point.y / 48)
        guard point.x >= 0, point.y >= 0, x < columns, y < rows else { return nil }
        return buckets[y * columns + x].reversed().first { regions[$0].rect.contains(point) }.map { regions[$0].id }
    }
    public func rect(for id: NodeID) -> CGRect? { regions.first { $0.id == id }?.rect }
    public func writePNG(to url: URL) throws {
        guard let destination = CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil) else { throw CocoaError(.fileWriteUnknown) }
        CGImageDestinationAddImage(destination, image, nil)
        guard CGImageDestinationFinalize(destination) else { throw CocoaError(.fileWriteUnknown) }
    }
}

private struct Cushion {
    var ax = 0.0, bx = 0.0, ay = 0.0, by = 0.0
    func adding(_ rect: CGRect, depth: Int) -> Cushion {
        var result = self
        let height = min(rect.width, rect.height) * 0.30 * pow(0.78, Double(depth))
        let x = -8 * height / max(1, rect.width * rect.width)
        let y = -8 * height / max(1, rect.height * rect.height)
        result.ax += x; result.bx -= x * rect.midX
        result.ay += y; result.by -= y * rect.midY
        return result
    }
}
private struct Label { let text: String; let rect: CGRect; let directory: Bool }

public enum TreemapRenderer {
    public static func render(tree: DiskTree, root: NodeID = 0, options: RenderOptions = RenderOptions(), cancelled: @Sendable () -> Bool = { false }) -> RenderedMap? {
        let width = max(1, min(8192, options.width)), height = max(1, min(8192, options.height))
        let scale = max(1, options.pixelScale)
        let bytesPerRow = width * 4
        let pixels = UnsafeMutablePointer<UInt8>.allocate(capacity: height * bytesPerRow)
        defer { pixels.deallocate() }
        pixels.initialize(repeating: options.dark ? 23 : 221, count: height * bytesPerRow)
        guard let context = CGContext(data: pixels, width: width, height: height, bitsPerComponent: 8, bytesPerRow: bytesPerRow,
                                      space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue | CGBitmapInfo.byteOrder32Big.rawValue) else { return nil }
        var regions: [RenderRegion] = [], labels: [Label] = []
        var stopped = false
        func paint(_ rect: CGRect, color: RGB, surface: Cushion) {
            let x0 = max(0, Int(ceil(rect.minX))), x1 = min(width, Int(ceil(rect.maxX)))
            let y0 = max(0, Int(ceil(rect.minY))), y1 = min(height, Int(ceil(rect.maxY)))
            guard x1 > x0, y1 > y0 else { return }
            for y in y0..<y1 {
                let dy = -(surface.ay * (Double(y) + 0.5) + surface.by)
                var offset = y * bytesPerRow + x0 * 4
                for x in x0..<x1 {
                    var intensity = 0.92
                    if options.cushions {
                        let dx = -(surface.ax * (Double(x) + 0.5) + surface.bx)
                        let light = max(0, (dx * -0.35 + dy * -0.45 + 1) / sqrt(dx * dx + dy * dy + 1) / 1.1511)
                        intensity = 0.32 + 0.83 * light
                    }
                    pixels[offset] = UInt8(min(255, color.r * intensity * 255))
                    pixels[offset+1] = UInt8(min(255, color.g * intensity * 255))
                    pixels[offset+2] = UInt8(min(255, color.b * intensity * 255))
                    pixels[offset+3] = 255; offset += 4
                }
            }
        }
        func descend(_ id: NodeID, rect: CGRect, inherited: RGB, surface: Cushion, depth: Int, appBundle: Bool) {
            guard !stopped else { return }
            if regions.count % 256 == 0 && cancelled() { stopped = true; return }
            guard rect.width >= 1.5, rect.height >= 1.5 else { return }
            let node = tree[id], name = tree.name(of: id)
            regions.append(RenderRegion(id: id, rect: rect))
            let inAppBundle = appBundle || (node.isDirectory && ["app", "framework", "xpc", "bundle"].contains((name as NSString).pathExtension.lowercased()))
            let category = inAppBundle ? FileCategory.apps : node.isAggregate ? FileCategory.small : FileCategory.classify(name)
            let color = options.colorMode == .folder ? inherited : category.color
            let cushion = surface.adding(rect, depth: depth)
            paint(rect, color: color, surface: cushion)
            if node.isDirectory && depth < 256 {
                let showLabel = rect.width >= 105 * scale && rect.height >= 48 * scale
                let strip = showLabel ? 19.0 * scale : 0
                if showLabel { labels.append(Label(text: "\(name)  ·  \(formatBytes(node.size))", rect: CGRect(x: rect.minX, y: rect.minY, width: rect.width, height: strip), directory: true)) }
                var content = rect.insetBy(dx: 2 * scale, dy: 2 * scale)
                content.origin.y += strip; content.size.height -= strip
                guard content.width >= 3, content.height >= 3 else { return }
                let children = tree.children(of: id)
                let tiles = SquarifiedLayout.layout(children.map { WeightedItem(id: $0, size: tree[$0].size) }, in: content)
                for (rank, tile) in tiles.enumerated() {
                    let childColor = id == root ? FolderColors.color(at: rank) : inherited
                    let childRect = tile.rect.insetBy(dx: 0.5 * scale, dy: 0.5 * scale)
                    descend(tile.id, rect: childRect, inherited: childColor, surface: cushion, depth: depth + 1, appBundle: inAppBundle)
                }
            } else if rect.width >= 85 * scale && rect.height >= 33 * scale {
                labels.append(Label(text: "\(name)  ·  \(formatBytes(node.size))", rect: rect.insetBy(dx: 4 * scale, dy: 3 * scale), directory: false))
            }
        }
        let bounds = CGRect(x: 0, y: 0, width: width, height: height)
        descend(root, rect: bounds, inherited: FolderColors.color(at: 0), surface: Cushion(), depth: 0, appBundle: false)
        guard !stopped else { return nil }
        // Text shares the same render path for app snapshots and headless PNGs.
        context.translateBy(x: 0, y: CGFloat(height)); context.scaleBy(x: 1, y: -1)
        let font = CTFontCreateWithName(".AppleSystemUIFont" as CFString, 11 * scale, nil)
        for label in labels {
            context.saveGState(); context.clip(to: label.rect)
            if label.directory {
                context.setFillColor(CGColor(gray: options.dark ? 0.08 : 0.15, alpha: 0.94)); context.fill(label.rect)
            } else {
                let backing = CGRect(x: label.rect.minX - 2 * scale, y: label.rect.minY, width: label.rect.width + 4 * scale, height: 17 * scale)
                context.setFillColor(CGColor(gray: 0.05, alpha: 0.43)); context.fill(backing)
            }
            let string = NSAttributedString(string: label.text, attributes: [
                NSAttributedString.Key(kCTFontAttributeName as String): font,
                NSAttributedString.Key(kCTForegroundColorAttributeName as String): CGColor(gray: 1, alpha: 0.96)
            ])
            let line = CTLineCreateWithAttributedString(string)
            let text = CTLineCreateTruncatedLine(line, max(1, label.rect.width - 9 * scale), .end, CTLineCreateWithAttributedString(NSAttributedString(string: "…", attributes: string.attributes(at: 0, effectiveRange: nil)))) ?? line
            context.translateBy(x: label.rect.minX + (label.directory ? 5 : 2) * scale, y: label.rect.minY + 13 * scale)
            context.scaleBy(x: 1, y: -1); context.textPosition = .zero; CTLineDraw(text, context); context.restoreGState()
        }
        guard let image = context.makeImage() else { return nil }
        return RenderedMap(image: image, regions: regions)
    }
}
