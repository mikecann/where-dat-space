import SwiftUI
import AppKit

/// Folders opened with the app (`open -a`, the CLI's `--open`, or dropped on the Dock icon).
/// They can arrive before the window exists, so the last one waits until someone's listening.
@MainActor final class AppDelegate: NSObject, NSApplicationDelegate {
    private var pending: URL?
    var onOpen: ((URL) -> Void)? {
        didSet { if let pending, let onOpen { self.pending = nil; onOpen(pending) } }
    }
    func application(_ application: NSApplication, open urls: [URL]) {
        guard let url = urls.first else { return }
        if let onOpen { onOpen(url) } else { pending = url }
    }
}

struct WhereDatSpaceApp: App {
    @NSApplicationDelegateAdaptor private var delegate: AppDelegate
    @State private var model = AppModel()
    init() {
        NSApplication.shared.setActivationPolicy(.regular)
    }
    var body: some Scene {
        WindowGroup("Where Dat Space?") {
            ContentView(model: model).onAppear {
                NSApplication.shared.activate(ignoringOtherApps: true)
                model.scanLaunchFolder()
                delegate.onOpen = { [model] in model.scan($0.path) }
            }
        }
            .defaultSize(width: 1280, height: 850)
            .commands {
                CommandGroup(replacing: .appInfo) {
                    Button("About Where Dat Space?") {
                        NSApplication.shared.orderFrontStandardAboutPanel(options: [
                            .applicationName: "Where Dat Space?",
                            .applicationIcon: Mascot.image,
                            .credits: NSAttributedString(string: "A little disk-space detective from Mikerosoft.\nmikerosoft.app")
                        ])
                    }
                }
                CommandGroup(replacing: .newItem) {
                    Button("Open Folder…", action: model.chooseFolder).keyboardShortcut("o")
                    Button("Rescan", action: model.rescan).keyboardShortcut("r").disabled(model.scanning)
                    Button("Go Up", action: model.goUp).keyboardShortcut(.upArrow, modifiers: .command)
                }
            }
    }
}
