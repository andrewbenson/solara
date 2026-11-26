#if DEBUG
import Foundation
@testable import SolaraUI

@MainActor
final class ImportAdapter: ImportScriptPath {
  let direct = false
  var session = 17
  var swiftSession = 29
  static func runOutcome(_ value: Any?, kinds: [ImportKind]) -> ImportRunOutcome { ImportRunOutcome(status: [:]) }
  func scriptCancel() {}
  func scriptDispose() {}
  func scriptBookmarksHTML(target: String, session: Int) async -> ImportFileOutcome { .cancelled }
  func scriptSafari(_ source: ImportSafariSource, target: String, cookies: Bool, session: Int) async -> ImportFileOutcome { .cancelled }
}

@MainActor
enum SettingsAdapters {
  static var calls: [(String, [String: Any], Int)] = []
  static func js(_ name: String, _ payload: [String: Any], _ session: Int) async -> Any? {
    calls.append((name, payload, session))
    return [:]
  }
}

@MainActor
enum ImportRunEngine { static let shared = 1 }

@MainActor
final class ImportRuns {
  static let shared = ImportRuns()
  var swiftCalls = 0
  func route(of runId: String) -> ImportRoute? { .swift }
  func run(_ request: ImportRunRequest, session: Int, engine: Int, script: ImportAdapter, scriptSession: Int) async -> ImportRunOutcome {
    swiftCalls += 1
    return .cancelledRun
  }
}

@main
struct RoutingHost {
  @MainActor static func main() async {
    let request = ImportRunRequest(runId: "unchanged", browserId: "arc", profileIds: ["Profile 1", "Default"], spaceIds: ["s2", "s1", "unknown"], kinds: [.tabs, .spaces, .pinnedTabs, .favorites], target: "destination", withoutKey: true)
    let adapter = ImportAdapter()
    _ = await adapter.run(request)
    precondition(ImportRuns.shared.swiftCalls == 0)
    precondition(SettingsAdapters.calls.count == 1)
    let (name, payload, session) = SettingsAdapters.calls[0]
    precondition(name == "import.run" && session == 17)
    precondition(payload["runId"] as? String == request.runId)
    precondition(payload["browserId"] as? String == request.browserId)
    precondition(payload["profileIds"] as? [String] == request.profileIds)
    precondition(payload["spaceIds"] as? [String] == request.spaceIds)
    precondition(payload["kinds"] as? [String] == request.kinds.map { $0.rawValue })
    precondition(payload["target"] as? String == request.target)
    precondition(payload["withoutKey"] as? Bool == request.withoutKey)
    print("actual ImportAdapter fallback forwards the unchanged request")
  }
}
#endif
