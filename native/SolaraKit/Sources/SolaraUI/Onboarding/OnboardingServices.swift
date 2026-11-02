import AppKit
import Foundation
import SolaraModel

@MainActor
public protocol OnboardingServices: AnyObject {
  var onboardingDiscovery: OnboardingDiscovering? { get }
  var pairingJoining: PairingJoining? { get }
  var onboardingSyncFolder: String? { get }
  var committedOnboardingJoinToken: String? { get }
  var onboardingJoinedWriter: OnboardingJoinedWriter? { get }
  func cancelOnboardingImport()
  func drainOnboardingPreviews() async throws
  func writeJoinedOnboardingDocument(_ json: String) async throws
  func openOnboardingRecoveryPhrase() -> Bool
  func chooseOnboardingFolder(beforeChange: @MainActor () -> Bool) async -> Bool
  func openOnboardingICloudSettings()

  func readOnboardingDocument() -> String?
  func readDurableOnboardingDocument() -> String?
  func writeOnboardingDocument(_ json: String)
  func hasSessionDocument() -> Bool
  var startsOnFirstLaunch: Bool { get }
  func now() -> Double

  func resolveWindowId(_ windowId: String?) -> String?
  func windowTabLayout(_ windowId: String?) -> String
  func setWindowTabLayout(_ windowId: String, _ layout: String)
  func previewSettings(_ patch: JSONObject)
  func profileColor(_ windowId: String) -> ProfileColorValue?
  func isIncognito(_ windowId: String) -> Bool
  func setProfileColor(_ windowId: String, _ color: ProfileColorValue)

  func endToolTour()
  func startToolTour(_ windowId: String)

  func playIntroMusic(_ cues: IntroMusicCues, muted: Bool)
  func setIntroMusicMuted(_ muted: Bool)
  func stopIntroMusic(fade: Double)

  func fileExists(_ path: String) -> Bool
  func fileIcon(_ path: String, size: Int) async -> NSImage?
  var importAvailable: Bool { get }
  func openImport(_ browserId: String)

  var backgroundInstance: Bool { get }
  func isDefaultBrowser() async -> Bool
  func isInDock() async -> Bool
  func loginItemStatus() async -> LoginItemStatus
  func setAsDefaultBrowser() async -> Bool
  func setLaunchAtLogin(_ on: Bool) async
  func addToDock() async

  func appIcons(size: Int) async -> [OnboardingAppIcon]
  func currentAppIcon() async -> String?
  func setAppIcon(_ id: String) async

  func pinnedHosts(_ windowId: String) -> Set<String>
  func history(_ windowId: String) -> [OnboardingHistoryVisit]
  func openPinnedTabs(_ windowId: String, _ sites: [PinnableSite])

  func favicon(_ url: String) async -> NSImage?
}

public extension OnboardingServices {
  var onboardingDiscovery: OnboardingDiscovering? { nil }
  var pairingJoining: PairingJoining? { nil }
  var onboardingSyncFolder: String? { nil }
  var committedOnboardingJoinToken: String? { nil }
  var onboardingJoinedWriter: OnboardingJoinedWriter? { nil }
  func cancelOnboardingImport() {}
  func drainOnboardingPreviews() async throws {}
  func writeJoinedOnboardingDocument(_ json: String) async throws {
    throw CocoaError(.fileWriteUnknown)
  }
  func openOnboardingRecoveryPhrase() -> Bool { false }
  func chooseOnboardingFolder(beforeChange: @MainActor () -> Bool) async -> Bool { false }
  func openOnboardingICloudSettings() {}
}

@MainActor
public final class OnboardingJoinedWriter {
  private enum ApprovalIdentity: Hashable {
    case token(String)
    case callback(UUID)
  }

  var task: Task<Void, Error>?
  var generation = 0
  private var approvedAt: [ApprovalIdentity: ContinuousClock.Instant] = [:]
  private var activeApprovalIdentity: UUID?
  private var mayLandBrowserEntry = false
  private var mayLandToken: String?
  private var mayLandCompletedAt: Double?

  public init() {}

  func beginApprovalIdentity() -> UUID {
    let identity = UUID()
    activeApprovalIdentity = identity
    return identity
  }

  func resumeApprovalIdentity() -> UUID {
    activeApprovalIdentity ?? beginApprovalIdentity()
  }

  func approvalDeadline(token: String?, callbackID: UUID, now: ContinuousClock.Instant) -> ContinuousClock.Instant {
    let fallback = ApprovalIdentity.callback(callbackID)
    let identity = token.map(ApprovalIdentity.token) ?? fallback
    let previous = identity == fallback ? approvedAt[fallback] : approvedAt.removeValue(forKey: fallback)
    var first = approvedAt[identity] ?? previous ?? now
    if let previous { first = min(first, previous) }
    approvedAt[identity] = first
    return first + .seconds(60)
  }

  func clearApproval(token: String?, callbackID: UUID) {
    approvedAt.removeValue(forKey: .callback(callbackID))
    if let token { approvedAt.removeValue(forKey: .token(token)) }
    if activeApprovalIdentity == callbackID { activeApprovalIdentity = nil }
  }

  func write(services: OnboardingServices, token: String?, installed: Bool, enterBrowser: Bool) async throws {
    let previous = task
    generation += 1
    let generation = self.generation
    let next = Task { @MainActor in
      _ = try? await previous?.value
      let saved = OnboardingDocument.parse(services.readOnboardingDocument())
      let completion = saved?["joinedCompletionToken"]?.string
      let sameJoin = { (other: String?) in other == nil || other == token }
      let entered = enterBrowser || (mayLandBrowserEntry && sameJoin(mayLandToken)) || (sameJoin(completion) && saved?["joinedEnteredBrowser"]?.bool == true)
      let completedAt = saved?["completedAt"]?.number ?? mayLandCompletedAt ?? (entered ? services.now() : nil)
      var patch: JSONObject = [
        "completedAt": completedAt.map(JSONValue.number) ?? .null,
        "joinedEnteredBrowser": .bool(entered),
        "source": .null,
        "picked": .object([:]),
      ]
      if installed {
        guard let token, !token.isEmpty else { throw CocoaError(.fileWriteUnknown) }
        patch["joinedCompletionToken"] = .string(token)
        patch["joinedCompletionAt"] = completion == token ? saved?["joinedCompletionAt"]?.number.map(JSONValue.number) ?? .number(services.now()) : .number(services.now())
      } else if enterBrowser, completion != token {
        patch["joinedCompletionToken"] = .null
        patch["joinedCompletionAt"] = .null
      }
      let written = OnboardingDocument.merged(saved, patch)
      let document = OnboardingDocument.stringify(.object(written))
      mayLandBrowserEntry = entered
      mayLandToken = written["joinedCompletionToken"]?.string
      mayLandCompletedAt = completedAt
      try await services.writeJoinedOnboardingDocument(document)
    }
    task = next
    defer { if generation == self.generation { task = nil } }
    try await next.value
  }
}
