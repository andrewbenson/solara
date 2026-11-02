import Foundation
import Testing
@testable import SolaraUI

struct SettingsDevActionAdmissionTests {
  @Test func P302_fixtureActionAdmissionReflectsBuildAndScratchState() throws {
    let data = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("ac-pairing-admission-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: data, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: data) }
    try Data().write(to: data.appendingPathComponent(".solara-probe-scratch"))
    let environment = ["SOLARA_BACKGROUND": "1", "SOLARA_DATA_DIR": data.path, "SOLARA_SYNC_PAIRING_FIXTURE": "1", "SOLARA_TEST_REAUTH": "granted", "SOLARA_NATIVE_SETTINGS": "1", "SOLARA_PROBES": "1", "SOLARA_PAIRING_TEST_AUTH": "granted"]
    #if DEBUG
    #expect(SettingsDevActionAdmission.admits("pairingFixture", environment: environment))
    #else
    #expect(!SettingsDevActionAdmission.admits("pairingFixture", environment: environment))
    #endif
    #expect(!SettingsDevActionAdmission.admits("authorizePairing", environment: environment))
  }
}
