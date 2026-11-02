import AppKit
import Foundation
import SwiftUI

public struct SettingsPlace {}
@MainActor public protocol SettingsPaneProvider {
  func isLoaded(_ place: SettingsPlace) -> Bool
  func prepare(_ place: SettingsPlace) async
  func view(_ place: SettingsPlace) -> AnyView
}
struct SyncPane: View {
  let model: SyncPaneModel
  var body: some View { EmptyView() }
}
enum SyncText { static func folderLabel(_ value: SyncFolderInfo) -> String { value.path } }

final class Evidence: @unchecked Sendable {
  let lock = NSLock()
  let reached = DispatchSemaphore(value: 0)
  let release = DispatchSemaphore(value: 0)
  private var events: [String] = []
  var guarded = false
  func record(_ value: String) { lock.lock(); events.append(value); lock.unlock() }
  func snapshot() -> [String] { lock.lock(); defer { lock.unlock() }; return events }
}

@MainActor final class Pairing: TrustedPairingService {
  let evidence: Evidence
  init(_ evidence: Evidence) { self.evidence = evidence }
  func observe(on surface: TrustedSurface?, _ receive: @escaping @MainActor (TrustedSnapshot) -> Void) -> TrustedSubscription {
    receive(TrustedSnapshot(revision: 1, eligible: true, openMarkerVerified: true, foreground: true))
    return TrustedSubscription({})
  }
  func attach(to settingsWindow: NSWindow) -> TrustedSurface { TrustedSurface() }
  func arm(on surface: TrustedSurface, reviewing: TrustedRequest?, options: TrustedArmOptions) throws -> TrustedArm { TrustedArm(deadline: TrustedPairingClock.now() + 100) }
  func select(_ request: TrustedRequest, in arm: TrustedArm) async throws {}
  func present(_ arm: TrustedArm, on surface: TrustedSurface) throws {}
  func toleratesSoftLoss(_ arm: TrustedArm) -> Bool { false }
  func panelLive(_ arm: TrustedArm) -> Bool { false }
  func surfaceChanged(_ surface: TrustedSurface, event: TrustedSurfaceEvent) { block("surfaceChanged") }
  func acknowledge(_ comparison: TrustedComparison, matched: Bool, on surface: TrustedSurface) -> TrustedAuthorization? { nil }
  func allow(_ authorization: TrustedAuthorization, on surface: TrustedSurface) async throws {}
  func end(_ arm: TrustedArm?, on surface: TrustedSurface, disposition: TrustedEnd) { block("end") }
  private func block(_ value: String) {
    evidence.record(value)
    evidence.reached.signal()
    precondition(evidence.release.wait(timeout: .now() + 3) == .success)
  }
}

@MainActor final class Sync: SyncServices {
  let evidence: Evidence
  init(_ evidence: Evidence) { self.evidence = evidence }
  func invalidatePairing(_ reason: String) { evidence.record("invalidate:" + reason) }
  func currentSyncState() async -> SyncState { SyncState(status: .off, enabled: false, folder: nil) }
  func syncStateUpdates() -> AsyncStream<SyncState> { AsyncStream { $0.finish() } }
  func chooseSyncFolder() async -> String? { evidence.record("service-entry"); return nil }
  func turnOnSync(folder: String) async -> String? { evidence.record("service-entry"); return nil }
  func enterRecoveryPhrase(folder: String, text: String) async -> SyncPhraseResult { evidence.record("service-entry"); return .unavailable }
  func stopSync(deleteData: Bool) async { evidence.record("service-entry") }
  func syncNow() async {}
  func setTypeSynced(_ type: SyncDataType, _ on: Bool) {}
  func setProfileSynced(_ profileId: String, _ on: Bool) {}
  func addRemoteProfile(_ syncId: String) {}
  func folderInfo(path: String?) async -> SyncFolderInfo? { nil }
  func recoveryWords() async -> [String]? { nil }
  func phraseUnavailable() async -> String? { nil }
  func recoveryQRCode() async -> Data? { nil }
  func recoveryKitPreview(width: Double) async -> Data? { nil }
  func saveRecoveryKit(_ format: SyncKitFormat) async -> String? { nil }
  func copyRecoveryKit() async {}
  func shareRecoveryKit() async {}
  func copyRecoveryPhrase() async {}
  func revealFolder(_ path: String) async {}
  func openICloudSettings() {}
}

@MainActor final class Creation: SyncCreationServices {
  func invalidatePairing(_ reason: String) { evidence.record("invalidate:" + reason) }
  let evidence: Evidence
  init(_ evidence: Evidence) { self.evidence = evidence }
  func inspectSyncCreation(folder: String) async -> SyncCreationInspection {
    SyncCreationInspection(id: "inspection", folder: folder, candidates: ["cid"], completeness: "complete")
  }
  func createSync(folder: String, inspectionID: String) async -> String? {
    evidence.record("creation-start")
    evidence.reached.signal()
    precondition(evidence.release.wait(timeout: .now() + 3) == .success)
    return nil
  }
  func invalidateSyncCreation(inspectionID: String) {
    evidence.record("creation-cancel")
    evidence.reached.signal()
    precondition(evidence.release.wait(timeout: .now() + 3) == .success)
  }
}

@main struct Probe {
  @MainActor static func main() async {
    NSApplication.shared.setActivationPolicy(.prohibited)
    let dispatchEvidence = Evidence()
    let dispatchModel = SyncPaneModel(services: Sync(dispatchEvidence))
    dispatchModel.invalidatePairing("stop")
    let dispatchRow: [String: Any] = ["action": "dispatchBarrier", "guarded": dispatchEvidence.snapshot().first == "invalidate:stop", "events": dispatchEvidence.snapshot()]
    print(String(data: try! JSONSerialization.data(withJSONObject: dispatchRow, options: [.sortedKeys]), encoding: .utf8)!)
    let idleEvidence = Evidence()
    SyncCreationModel(services: Creation(idleEvidence)).cancel()
    let idleRow: [String: Any] = ["action": "idleCreationCancel", "guarded": idleEvidence.snapshot().isEmpty, "events": idleEvidence.snapshot(), "expectsInvalidation": false]
    print(String(data: try! JSONSerialization.data(withJSONObject: idleRow, options: [.sortedKeys]), encoding: .utf8)!)
    let unchangedEvidence = Evidence()
    let unchangedModel = SyncPaneModel(services: Sync(unchangedEvidence))
    let off = SyncState(status: .off, enabled: false, folder: nil)
    unchangedModel.state = off
    unchangedModel.apply(off)
    let unchangedRow: [String: Any] = ["action": "unchangedOff", "guarded": unchangedEvidence.snapshot().isEmpty, "events": unchangedEvidence.snapshot(), "expectsInvalidation": false]
    print(String(data: try! JSONSerialization.data(withJSONObject: unchangedRow, options: [.sortedKeys]), encoding: .utf8)!)
    let window = NSWindow(contentRect: .zero, styleMask: [], backing: .buffered, defer: true)
    for action in ["stop", "stop-v1", "stop-null", "chooseFolder", "changeFolderForPhrase", "submitPhrase", "turnOn", "creationCancel", "directCreationCancel", "confirmSeparate", "surfaceRemoved", "stateChanged", "sheetDismiss"] {
      let evidence = Evidence()
      let service = Sync(evidence)
      let creationOnly = action == "creationCancel" || action == "directCreationCancel" || action == "confirmSeparate"
      let model = SyncPaneModel(services: service, pairingService: creationOnly ? nil : Pairing(evidence), creationService: creationOnly ? Creation(evidence) : nil)
      model.info = SyncFolderInfo(path: "/fixture", defaultPath: "/fixture", iCloudAvailable: false, inICloud: false, exists: true, writable: true, hasSyncData: false)
      if action == "stateChanged" { model.state = SyncState(status: .updated, enabled: true, folder: "/fixture") }
      if action == "stop-v1" { model.state = SyncState(status: .updated, enabled: true, folder: "/fixture") }
      if creationOnly {
        await model.creation?.start(folder: "/fixture")
        model.sheet = .separateSync(inspectionID: "inspection")
      } else {
        model.pairingSurfaceAvailable(to: window)
        model.pairing?.connect()
      }
      if action == "sheetDismiss" { model.sheet = .trustedPairing(surfaceID: UUID()) }
      DispatchQueue.global().async {
        precondition(evidence.reached.wait(timeout: .now() + 3) == .success)
        evidence.guarded = evidence.snapshot().first?.hasPrefix("invalidate:") == true
        evidence.release.signal()
      }
      switch action {
      case "stop", "stop-v1", "stop-null": await model.stop(deleteData: false)
      case "chooseFolder": await model.chooseFolder()
      case "changeFolderForPhrase": await model.changeFolderForPhrase()
      case "submitPhrase": _ = await model.submitPhrase("fixture")
      case "confirmSeparate": await model.confirmSeparateSync(inspectionID: "inspection")
      case "creationCancel": model.sheet = nil
      case "directCreationCancel": model.creation?.cancel()
      case "sheetDismiss": model.sheet = nil
      case "surfaceRemoved": model.pairingSurfaceRemoved()
      case "stateChanged": model.apply(SyncState(status: .off, enabled: false, folder: nil))
      default: await model.turnOn()
      }
      let value: [String: Any] = ["action": action, "guarded": evidence.guarded, "events": evidence.snapshot()]
      print(String(data: try! JSONSerialization.data(withJSONObject: value, options: [.sortedKeys]), encoding: .utf8)!)
    }
  }
}
