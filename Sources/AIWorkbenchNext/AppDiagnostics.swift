import AIWorkbenchCore
import Foundation

enum AppDiagnostics {
    @MainActor
    static func run() {
        let store = WorkbenchStore()
        print("AI Workbench Community \(store.appVersion)")
        print("Configured: \(store.configuration.configured)")
        print("Workspace: \(store.configuration.workspaceURL.path)")
        for name in WorkbenchConfiguration.templateNames {
            let url = store.configuration.fileURL(name)
            print("\(name): \(FileManager.default.fileExists(atPath: url.path) ? "found" : "missing")")
        }
        print("Project sources: \(store.configuration.projects.count)")
        let result = SessionScanner.scan(limit: 10, candidateFloor: 10)
        print("Codex tasks scanned: \(result.tasks.count)")
    }
}
