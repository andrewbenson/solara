import Foundation
import SolaraUI

extension ImportAdapter {
  func run(_ request: ImportRunRequest) async -> ImportRunOutcome {
    let outcome: ImportRunOutcome
    if direct {
      outcome = await ImportRuns.shared.run(request, session: swiftSession, engine: ImportRunEngine.shared, script: self, scriptSession: session)
    } else {
      outcome = await scriptRun(request, session: session)
    }
    #if DEBUG
    if !(ProcessInfo.processInfo.environment["SOLARA_DATA_DIR"] ?? "").isEmpty {
      ImportRoutingDebug.outcome = outcome
      ImportRoutingDebug.route = direct ? ImportRuns.shared.route(of: request.runId)?.rawValue : "js"
    }
    #endif
    return outcome
  }

  func scriptRun(_ request: ImportRunRequest, session: Int) async -> ImportRunOutcome {
    let arg: [String: Any] = [
      "runId": request.runId,
      "browserId": request.browserId,
      "profileIds": request.profileIds,
      "spaceIds": request.spaceIds,
      "kinds": request.kinds.map(\.rawValue),
      "target": request.target,
      "withoutKey": request.withoutKey,
    ]
    return Self.runOutcome(await SettingsAdapters.js("import.run", arg, session), kinds: request.kinds)
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
