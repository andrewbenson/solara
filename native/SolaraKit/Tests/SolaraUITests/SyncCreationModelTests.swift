import Foundation
import Testing
@testable import SolaraUI

@MainActor
struct SyncCreationModelTests {
  final class Services: SyncCreationServices {
  func invalidatePairing(_ reason: String) {}
    var candidates: [String] = []
    var completeness = "complete"
    var created: [String] = []
    var hold: CheckedContinuation<SyncCreationInspection, Never>?
    var held = false
    var failure: String?
    var invalidated: [String] = []
    var creationHold: CheckedContinuation<String?, Never>?
    var holdCreation = false
    func invalidateSyncCreation(inspectionID: String) { invalidated.append(inspectionID) }

    func inspectSyncCreation(folder: String) async -> SyncCreationInspection {
      if held { return await withCheckedContinuation { hold = $0 } }
      return SyncCreationInspection(id: "inspection", folder: folder, candidates: candidates, completeness: completeness)
    }
    func createSync(folder: String, inspectionID: String) async -> String? {
      created.append("\(folder):\(inspectionID)")
      if holdCreation { return await withCheckedContinuation { creationHold = $0 } }
      return failure
    }
  }

  @Test func C01ExistingShowsWarningAndCancelHasNoEffects() async {
    let services = Services()
    services.candidates = ["cid"]
    let model = SyncCreationModel(services: services)
    await model.start(folder: "/sync")
    guard case .warning(let inspection) = model.state else { Issue.record("existing chain needs warning"); return }
    #expect(inspection.candidates == ["cid"])
    #expect(services.created.isEmpty)
    model.cancel()
    await model.confirmSeparateSync()
    #expect(services.created.isEmpty)
  }

  @Test func C02VerifiedEmptyUsesItsExactInspection() async {
    let services = Services()
    let model = SyncCreationModel(services: services)
    await model.start(folder: "/sync")
    #expect(services.created == ["/sync:inspection"])
    #expect(model.state == .created)
  }

  @Test func C03CancelInvalidatesHeldInspection() async {
    let services = Services()
    services.held = true
    let model = SyncCreationModel(services: services)
    let start = Task { await model.start(folder: "/old") }
    for _ in 0..<1000 where services.hold == nil { await Task.yield() }
    guard services.hold != nil else { Issue.record("inspection must start"); return }
    model.cancel()
    services.hold?.resume(returning: SyncCreationInspection(id: "old", folder: "/old", candidates: [], completeness: "complete"))
    await start.value
    #expect(model.state == .idle)
    #expect(services.invalidated == ["old"])
    #expect(services.created.isEmpty)
  }

  @Test func C04UnknownRefusesCreation() async {
    for completeness in ["unavailable", "permissionDenied", "needsHydration", "timedOut", "incomplete", "unknown"] {
      let services = Services()
      services.completeness = completeness
      let model = SyncCreationModel(services: services)
      await model.start(folder: "/sync")
      #expect(services.created.isEmpty)
      guard case .failed = model.state else { Issue.record("unknown listing must fail closed"); continue }
    }
  }

  @Test func C05DuplicateConfirmationCannotReuseConsent() async {
    let services = Services()
    services.candidates = ["cid"]
    let model = SyncCreationModel(services: services)
    await model.start(folder: "/sync")
    await model.confirmSeparateSync()
    await model.confirmSeparateSync()
    #expect(services.created == ["/sync:inspection"])
  }

  @Test func C06ExplicitSeparateShowsFailureWithoutAnotherAttempt() async {
    let services = Services()
    services.candidates = ["cid"]
    services.failure = "The folder changed. Check it again."
    let model = SyncCreationModel(services: services)
    await model.start(folder: "/sync")
    await model.confirmSeparateSync()
    #expect(model.state == .failed("The folder changed. Check it again."))
    #expect(services.created.count == 1)
  }
  @Test func C03CancelRevokesConsentWhileCreationIsHeld() async {
    let services = Services()
    services.candidates = ["cid"]
    services.holdCreation = true
    let model = SyncCreationModel(services: services)
    await model.start(folder: "/sync")
    let confirm = Task { await model.confirmSeparateSync() }
    for _ in 0..<1000 where services.creationHold == nil { await Task.yield() }
    guard services.creationHold != nil else { Issue.record("creation must start"); return }
    model.cancel()
    #expect(services.invalidated == ["inspection"])
    services.creationHold?.resume(returning: "Request cancelled")
    await confirm.value
    #expect(model.state == .idle)
  }

}
