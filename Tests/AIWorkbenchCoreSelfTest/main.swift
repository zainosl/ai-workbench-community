import AIWorkbenchCore
import Foundation

let root = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
    .appendingPathComponent("Resources/Templates", isDirectory: true)
let business = try BusinessContextScanner.scan(entryURL: root.appendingPathComponent("business.md"))
let radar = try AssumptionRadarScanner.scan(
    assumptionsURL: root.appendingPathComponent("assumptions.md"),
    dependenciesURL: root.appendingPathComponent("dependencies.md"),
    milestoneURL: root.appendingPathComponent("milestone.md"),
    priorityURL: root.appendingPathComponent("priorities.md"),
    businessContext: business
)
precondition(business.stages.count == 5, "five-step canvas did not parse")
precondition(!radar.assumptions.isEmpty, "assumption template did not parse")
print("Template self-test passed: \(business.stages.count) stages, \(radar.assumptions.count) assumptions")
