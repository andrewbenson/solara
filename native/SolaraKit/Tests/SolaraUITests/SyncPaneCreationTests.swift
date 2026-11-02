import Testing
@testable import SolaraUI

@MainActor
struct SyncPaneCreationTests {
  final class Creation: SyncCreationServices {
  func invalidatePairing(_ reason: String) {}
    var serial = 0
    var creations: [String] = []
    func inspectSyncCreation(folder: String) async -> SyncCreationInspection {
      serial += 1
      return SyncCreationInspection(id: "inspection-\(serial)", folder: folder, candidates: ["cid-\(serial)"], completeness: "complete")
    }
    func createSync(folder: String, inspectionID: String) async -> String? { creations.append(inspectionID); return nil }
  }

  @Test func C03_C05_oldWarningCallbackCannotConfirmReplacementInspection() async {
    let creation = Creation()
    let services = FakeSyncServices(state: SyncState(status: .off, enabled: false, folder: "/old"))
    let pane = SyncPaneModel(services: services, creationService: creation)
    await pane.prepare(SettingsPlace(pane: .sync))
    await pane.turnOn()
    guard case .separateSync(let oldID) = pane.sheet else { Issue.record("warning A missing"); return }
    pane.creation?.cancel()
    pane.sheet = nil
    await pane.reloadInfo(path: "/new")
    await pane.turnOn()
    guard case .separateSync(let newID) = pane.sheet else { Issue.record("warning B missing"); return }
    #expect(oldID != newID)
    await pane.confirmSeparateSync(inspectionID: oldID)
    #expect(creation.creations.isEmpty)
    #expect(pane.sheet == .separateSync(inspectionID: newID))
    await pane.confirmSeparateSync(inspectionID: newID)
    #expect(creation.creations == [newID])
  }
}
