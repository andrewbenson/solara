import Foundation
import SolaraUI
import Testing

@Suite struct TabSleepPolicyTests {
  private struct Vectors: Decodable {
    let candidates: [CandidateVector]
    let unusedProfiles: [UnusedProfilesVector]
  }

  private struct CandidateVector: Decodable {
    let name: String
    let tabs: [TabSleepPolicy.Tab]
    let shownIds: Set<String>
    let discardedIds: Set<String>
    let loadedIds: [String]
    let hiddenAt: [String: Double]
    let now: Double
    let pressure: TabSleepPolicy.Pressure
    let unusedProfileIds: Set<String>
    let policy: TabSleepPolicy.Configuration
    let keepAliveReasons: [String: String]
    let expected: [String]
  }

  private struct UnusedProfilesVector: Decodable {
    let name: String
    let profileIds: [String]
    let shownProfileIds: Set<String>
    let unusedSince: [String: Double]
    let now: Double
    let idleMs: Double
    let expectedUnusedSince: [String: Double]
    let expectedEligibleIds: [String]
  }

  private func vectors() throws -> Vectors {
    let file = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
      .appendingPathComponent("../../../../apps/browser/src/lib/tabSleep.vectors.json").standardizedFileURL
    return try JSONDecoder().decode(Vectors.self, from: Data(contentsOf: file))
  }

  @Test func candidateSelectionMatchesJavaScript() throws {
    for vector in try vectors().candidates {
      let result = TabSleepPolicy.candidates(
        tabs: vector.tabs,
        shownIds: vector.shownIds,
        discardedIds: vector.discardedIds,
        loadedIds: vector.loadedIds,
        hiddenAt: vector.hiddenAt,
        now: vector.now,
        pressure: vector.pressure,
        unusedProfileIds: vector.unusedProfileIds,
        policy: vector.policy,
        keepAliveReasons: vector.keepAliveReasons
      )
      #expect(result == vector.expected, "\(vector.name)")
    }
  }

  @Test func unusedProfilesMatchJavaScript() throws {
    for vector in try vectors().unusedProfiles {
      let result = TabSleepPolicy.unusedProfiles(
        profileIds: vector.profileIds,
        shownProfileIds: vector.shownProfileIds,
        unusedSince: vector.unusedSince,
        now: vector.now,
        idleMs: vector.idleMs
      )
      #expect(result.unusedSince == vector.expectedUnusedSince, "\(vector.name)")
      #expect(result.eligibleIds == vector.expectedEligibleIds, "\(vector.name)")
    }
  }
}
