import AppKit
import KeymapCore
import SwiftUI
import ViaKit

/// Closing the main window quits the app, rather than leaving it running without a window.
final class QuitOnCloseDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        NotificationCenter.default.addObserver(forName: NSWindow.willCloseNotification, object: nil, queue: .main) { note in
            // The main window's title follows the selected panel, so it is known by the scene id SwiftUI gives it.
            guard let window = note.object as? NSWindow, window.identifier?.rawValue.hasPrefix("main") == true || window.title == "Keymap" else { return }
            NSApplication.shared.terminate(nil)
        }
    }
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }

    /// Lighting shown as a preview but never applied is put back on the keyboard before the app quits.
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard let model = AppModel.current, model.needsPreviewRestore else { return .terminateNow }
        Task { @MainActor in
            await model.restoreLivePreview()
            NSApplication.shared.reply(toApplicationShouldTerminate: true)
        }
        return .terminateLater
    }
}

@main
struct KeymapApp: App {
    @NSApplicationDelegateAdaptor(QuitOnCloseDelegate.self) private var appDelegate
    private let model = AppModel(transportFactory: { try IOKitHIDTransport() },
                                        backupDirectory: AppModel.defaultBackupDirectory)

    var body: some Scene {
        Window("Keymap", id: "main") {   // one window only: a second one would reconnect and reset the session
            MainView(model: model)
                .task {
                    NSApplication.shared.setActivationPolicy(.regular)
                    NSApplication.shared.activate(ignoringOtherApps: true)
                    model.applyStoredAppearance()
                    model.startAutoConnect()
                    await model.connect()
                }
        }
        .defaultSize(width: 1280, height: 800)
        Window("Keymap Help", id: "help") { HelpView(library: HelpLibrary.shared) }
            .defaultSize(width: 1040, height: 760)
        .commands {
            HelpCommands()
            CommandGroup(after: .toolbar) {
                Menu("Appearance") {
                    Picker("Appearance", selection: Binding(get: { model.appearance }, set: { model.appearance = $0 })) {
                        ForEach(AppModel.Appearance.allCases, id: \.self) { Label($0.title, systemImage: $0.icon).tag($0) }
                    }
                    .pickerStyle(.inline)
                    .labelsHidden()
                }
            }
        }
    }
}

/// Help menu: one item per document, each opening the Help window on that document.
struct HelpCommands: Commands {
    @Environment(\.openWindow) private var openWindow

    var body: some Commands {
        CommandGroup(replacing: .help) {
            ForEach(HelpLibrary.Doc.allCases) { doc in
                Button(doc.title) {
                    HelpLibrary.shared.selected = doc
                    openWindow(id: "help")
                }
            }
        }
    }
}
