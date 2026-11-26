import Foundation
import SolaraUI

extension ImportAdapter {
  func run(_ request: ImportRunRequest) async -> ImportRunOutcome {
    let outcome = await ImportRuns.shared.run(request, session: swiftSession, engine: ImportRunEngine.shared)
    #if DEBUG
    if !(ProcessInfo.processInfo.environment["SOLARA_DATA_DIR"] ?? "").isEmpty {
      ImportRoutingDebug.outcome = outcome
      ImportRoutingDebug.route = "swift"
    }
    #endif
    return outcome
  }

}

#if DEBUG
@MainActor
enum ImportRoutingDebug {
  static var outcome: ImportRunOutcome?
  static var route: String?

  static var snapshot: [String: Any] {
    guard let outcome else { return [:] }
    return [
      "cancelled": outcome.cancelled,
      "status": Dictionary(uniqueKeysWithValues: outcome.status.map { ($0.key.rawValue, $0.value.rawValue) }),
      "counts": ["tabs": outcome.counts.tabs, "bookmarks": outcome.counts.bookmarks, "history": outcome.counts.history, "passwords": outcome.counts.passwords, "cookies": outcome.counts.cookies, "addresses": outcome.counts.addresses, "cards": outcome.counts.cards],
      "failures": outcome.failures.map { ["kind": $0.kind.rawValue, "profiles": $0.profiles] as [String: Any] },
      "notes": outcome.notes,
      "extensionsProfile": outcome.extensionsProfile,
      "extensions": outcome.extensions.map { ["id": $0.id, "name": $0.name, "webStoreUrl": $0.webStoreUrl] }
    ]
  }
}
#endif
