import Foundation

struct ProfileSummary: Equatable {
  let id: String
}

final class StoreSource {
  var model = Model()
  struct Model {
    var profiles = [ProfileSummary(id: "default"), ProfileSummary(id: "named")]
  }
}

enum Failure: Error {
  case unwritableLedger
}

final class SettingsJS {
  static let shared = SettingsJS()
  var pending: CheckedContinuation<Any?, Error>?

  func invoke(_ name: String, _ args: [Any]) async throws -> Any? {
    try await withCheckedThrowingContinuation { pending = $0 }
  }
}

var failures: [String] = []
func NSLog(_ format: String, _ name: String, _ error: String) {
  failures.append(name + ": " + error)
}

struct ProfileDeletePrompt {
  let profileId: String
  let fromDetails = true
  let canDelete = true
}

@MainActor
final class SettingsNavigation {
  var profileId: String? = "named"
  enum Pane { case profiles }
  func go(_ pane: Pane) { profileId = nil }
}

__PRODUCTION__

MainActor.assumeIsolated {
var results: [[String: Any]] = []
for refused in [true, false] {
  failures = []
  let adapter = ProfilesAdapter()
  let model = ProfilesPaneModel(services: adapter)
  let navigation = SettingsNavigation()
  let expected = adapter.profiles
  model.confirmDelete(ProfileDeletePrompt(profileId: "named"), navigation: navigation)
  let deadline = Date(timeIntervalSinceNow: 2)
  while SettingsJS.shared.pending == nil && Date() < deadline {
    RunLoop.current.run(until: Date(timeIntervalSinceNow: 0.005))
  }
  let visibleBeforeReply = adapter.profiles == expected
  let detailsBeforeReply = navigation.profileId == "named"
  if refused {
    SettingsJS.shared.pending?.resume(throwing: Failure.unwritableLedger)
  } else {
    adapter.store.model.profiles.removeAll { $0.id == "named" }
    SettingsJS.shared.pending?.resume(returning: nil)
  }
  SettingsJS.shared.pending = nil
  while (refused ? failures.isEmpty : navigation.profileId != nil) && Date() < deadline {
    RunLoop.current.run(until: Date(timeIntervalSinceNow: 0.005))
  }
  results.append([
    "refused": refused,
    "visibleBeforeReply": visibleBeforeReply,
    "detailsBeforeReply": detailsBeforeReply,
    "detailsAfterReply": navigation.profileId == "named",
    "noBlankPane": navigation.profileId == nil || model.profile("named") != nil,
    "failed": failures == ["profiles.delete: unwritableLedger"],
  ])
}
let output = try! JSONSerialization.data(withJSONObject: results)
print(String(data: output, encoding: .utf8)!)
}
