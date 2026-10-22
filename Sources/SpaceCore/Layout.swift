import Foundation
import CoreGraphics

public struct WeightedItem: Sendable {
    public let id: NodeID
    public let size: UInt64
    public init(id: NodeID, size: UInt64) { self.id = id; self.size = size }
}
public struct Tile: Sendable {
    public let id: NodeID
    public let rect: CGRect
}

public enum SquarifiedLayout {
    /// Bruls, Huizing & van Wijk: add to a row only while its worst aspect ratio improves.
    public static func layout(_ items: [WeightedItem], in bounds: CGRect) -> [Tile] {
        let positive = items.filter { $0.size > 0 }.sorted { $0.size == $1.size ? $0.id < $1.id : $0.size > $1.size }
        let total = positive.reduce(0.0) { $0 + Double($1.size) }
        guard total > 0, bounds.width > 0, bounds.height > 0 else { return [] }
        let scale = bounds.width * bounds.height / total
        var remaining = bounds, row: [WeightedItem] = [], rowArea = 0.0, output: [Tile] = []
        func worst(_ row: [WeightedItem], area: Double, side: Double) -> Double {
            guard let first = row.first, let last = row.last, area > 0, side > 0 else { return .infinity }
            let big = Double(first.size) * scale, small = Double(last.size) * scale, square = side * side
            return max(square * big / (area * area), area * area / (square * small))
        }
        func place() {
            guard rowArea > 0 else { return }
            let vertical = remaining.width >= remaining.height
            let side = vertical ? remaining.height : remaining.width
            let thickness = min(vertical ? remaining.width : remaining.height, rowArea / side)
            var offset = vertical ? remaining.minY : remaining.minX
            for (index, item) in row.enumerated() {
                let length = index == row.count - 1 ? (vertical ? remaining.maxY : remaining.maxX) - offset : Double(item.size) * scale / thickness
                let rect = vertical ? CGRect(x: remaining.minX, y: offset, width: thickness, height: length)
                                    : CGRect(x: offset, y: remaining.minY, width: length, height: thickness)
                output.append(Tile(id: item.id, rect: rect)); offset += length
            }
            if vertical { remaining.origin.x += thickness; remaining.size.width = max(0, remaining.width - thickness) }
            else { remaining.origin.y += thickness; remaining.size.height = max(0, remaining.height - thickness) }
            row.removeAll(keepingCapacity: true); rowArea = 0
        }
        for item in positive {
            let area = Double(item.size) * scale, side = min(remaining.width, remaining.height)
            let candidate = row + [item]
            if !row.isEmpty && worst(candidate, area: rowArea + area, side: side) > worst(row, area: rowArea, side: side) { place() }
            row.append(item); rowArea += area
        }
        place(); return output
    }
}
