import Foundation
import Testing

@testable import SolaraSyncCore

@Suite struct SyncCoreTests {
  let pod = URL(fileURLWithPath: #filePath).deletingLastPathComponent().appending(path: "../../../../packages/sync/ios/Core").standardized
  let shared = URL(fileURLWithPath: #filePath).deletingLastPathComponent().appending(path: "../../Sources/SolaraSyncCore").standardized

  @Test func everySourceIsTheSolaraSyncAdapterPodsOwnFile() throws {
    let names = try FileManager.default.contentsOfDirectory(atPath: shared.path).filter { $0.hasSuffix(".swift") }.sorted()
    let coreNames = try FileManager.default.contentsOfDirectory(atPath: pod.path).filter { $0.hasSuffix(".swift") }.sorted()
    let coordinatorNames = ["PairingCoordinator.swift", "PairingInstallationHost.swift", "PairingService.swift"]
    #expect(names == (coreNames + coordinatorNames).sorted())
    for name in names {
      let link = shared.appending(path: name)
      let source = coordinatorNames.contains(name) ? pod.deletingLastPathComponent().appending(path: name) : pod.appending(path: name)
      #expect(link.resolvingSymlinksInPath().path == source.resolvingSymlinksInPath().path)
      #expect(try Data(contentsOf: link) == Data(contentsOf: source))
    }
  }

  @Test func aSealedFileOpensOnlyUnderItsOwnName() throws {
    let entropy = Data((0..<16).map { UInt8($0) })
    let keys = SyncKeys(entropy: entropy)
    let scope = keys.scopeTag("app")
    let sealed = try keys.seal(Data("{\"v\":1}".utf8), scopeTag: scope, fileId: "f1")
    #expect(sealed.count % 1024 == 4 + 12 + 16)
    #expect(try keys.open(sealed, scopeTag: scope, fileId: "f1") == Data("{\"v\":1}".utf8))
    #expect(throws: SyncKeys.Failure.authentication) { try keys.open(sealed, scopeTag: scope, fileId: "f2") }
    #expect(SyncKeys(entropy: entropy).chainTag == keys.chainTag)
    #expect(keys.chainTag.count == 26)
  }

  @Test func aRecoveryPhraseRoundTrips() throws {
    let entropy = RecoveryPhrase.generateEntropy()
    #expect(try RecoveryPhrase.entropy(from: RecoveryPhrase.words(for: entropy).joined(separator: " ")) == entropy)
  }
}
