import AppKit
import Foundation

@MainActor enum Mascot {
    // Use the same generated image in the empty state, About panel and app icon.
    static let image: NSImage = {
        guard let url = Bundle.module.url(forResource: "where-dat-space", withExtension: "png"),
              let image = NSImage(contentsOf: url) else {
            return NSImage(systemSymbolName: "internaldrive", accessibilityDescription: nil) ?? NSImage()
        }
        return image
    }()
}
