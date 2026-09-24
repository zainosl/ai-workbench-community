import Foundation

struct ProjectSource: Codable, Identifiable, Equatable {
    var id: String
    var name: String
    var rootPath: String
    var overview: String
    var progress: String
    var preferences: String
    var assumptions: String
    var result: String
}

struct WorkbenchConfiguration: Codable, Equatable {
    var schemaVersion: Int
    var configured: Bool
    var workspacePath: String
    var displayName: String
    var projects: [ProjectSource]

    static func bootstrap(at root: URL) throws -> WorkbenchConfiguration {
        let manager = FileManager.default
        try manager.createDirectory(at: root, withIntermediateDirectories: true)
        let configURL = root.appendingPathComponent("config.json")
        let workspaceURL = root.appendingPathComponent("Workspace", isDirectory: true)
        try manager.createDirectory(at: workspaceURL, withIntermediateDirectories: true)

        for name in Self.templateNames {
            let target = workspaceURL.appendingPathComponent(name)
            guard !manager.fileExists(atPath: target.path) else { continue }
            if let bundled = Bundle.main.url(forResource: name, withExtension: nil, subdirectory: "Templates") {
                try manager.copyItem(at: bundled, to: target)
            } else if let local = Self.localTemplateURL(name: name),
                      manager.fileExists(atPath: local.path) {
                try manager.copyItem(at: local, to: target)
            } else {
                try "# 请在这里填写你的资料\n".write(to: target, atomically: true, encoding: .utf8)
            }
        }

        if manager.fileExists(atPath: configURL.path) {
            let data = try Data(contentsOf: configURL)
            return try JSONDecoder().decode(Self.self, from: data)
        }
        let value = Self(
            schemaVersion: 1,
            configured: false,
            workspacePath: workspaceURL.path,
            displayName: "我的工作台",
            projects: []
        )
        try value.save(at: root)
        return value
    }

    func save(at root: URL) throws {
        let data = try JSONEncoder.pretty.encode(self)
        try data.write(to: root.appendingPathComponent("config.json"), options: .atomic)
    }

    var workspaceURL: URL {
        let expanded = (workspacePath as NSString).expandingTildeInPath
        return URL(fileURLWithPath: expanded, isDirectory: true)
    }

    func fileURL(_ name: String) -> URL {
        workspaceURL.appendingPathComponent(name)
    }

    func projectURL(_ path: String, rootPath: String) -> URL {
        let expanded = (path as NSString).expandingTildeInPath
        if expanded.hasPrefix("/") { return URL(fileURLWithPath: expanded) }
        return URL(fileURLWithPath: (rootPath as NSString).expandingTildeInPath)
            .appendingPathComponent(path)
    }

    static let templateNames = [
        "business.md", "assumptions.md", "dependencies.md",
        "milestone.md", "priorities.md", "emerging.md"
    ]

    private static func localTemplateURL(name: String) -> URL? {
        let cwd = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
        let candidate = cwd.appendingPathComponent("Resources/Templates/\(name)")
        return FileManager.default.fileExists(atPath: candidate.path) ? candidate : nil
    }
}

private extension JSONEncoder {
    static var pretty: JSONEncoder {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return encoder
    }
}
