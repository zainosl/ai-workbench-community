import AppKit
import SwiftUI

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var store: WorkbenchStore?
    private var panelController: WorkbenchPanelController?

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
        let store = WorkbenchStore()
        let controller = WorkbenchPanelController(store: store)
        self.store = store
        self.panelController = controller
        store.start()
        if !store.configuration.configured { controller.show() }
    }

    func applicationWillTerminate(_ notification: Notification) {
        panelController?.tearDown()
        store?.stop()
    }
}

@main
enum AIWorkbenchNextMain {
    private static var delegate: AppDelegate?

    @MainActor
    static func main() {
        if ProcessInfo.processInfo.arguments.contains("--diagnose") {
            AppDiagnostics.run()
            return
        }
        let app = NSApplication.shared
        let delegate = AppDelegate()
        self.delegate = delegate
        app.delegate = delegate
        app.run()
    }
}
