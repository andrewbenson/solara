import Foundation
import SolaraModel
import Testing
@testable import SolaraUI

@MainActor
struct OnboardingSetupWorkTests {
  func settle() async {
    for _ in 0..<30 { await Task.yield() }
  }

  func fixture() -> (OnboardingModel, OnboardingFakeServices, OnboardingFakeDiscovery, OnboardingFakeJoining) {
    let (model, services, _) = OnboardingFixture.make()
    let discovery = OnboardingFakeDiscovery()
    let joining = OnboardingFakeJoining()
    services.discovery = discovery
    services.joining = joining
    model.maybeStart(windowId: "w1")
    discovery.emit(.empty)
    return (model, services, discovery, joining)
  }

  @Test func switchingToSyncCancelsAnImportBeforeItCanWrite() async {
    let (model, services, _, _) = fixture()
    model.go(.source)
    await model.loadSources()
    model.chooseSource(.arc)
    model.startImport()
    #expect(services.imports == ["arc"])
    model.discoverSync()
    await settle()
    services.completeImport()
    #expect(services.importCancelled)
    #expect(services.importedWrites == 0)
  }

  @Test func staleDefaultCallbackClearsBusyAfterLeavingSetup() async {
    let (model, services, _, _) = fixture()
    model.go(.home)
    model.system = OnboardingSystemState(isDefault: false, inDock: true, loginEnabled: false)
    var continuation: CheckedContinuation<Bool, Never>?
    services.defaultOperation = { await withCheckedContinuation { continuation = $0 } }
    let task = Task { await model.applySystem() }
    await settle()
    #expect(continuation != nil)
    #expect(model.busy)
    model.discoverSync()
    continuation?.resume(returning: true)
    await task.value
    #expect(!model.busy)
    #expect(model.syncRoute == .discovering)
  }

  @Test(arguments: ["default", "login", "dock"])
  func joinWaitsForAnAdmittedSystemOperation(operation: String) async {
    let (model, services, discovery, joining) = fixture()
    model.go(.home)
    model.system = OnboardingSystemState(isDefault: operation != "default", inDock: operation != "dock", loginEnabled: false)
    model.setExtras { $0.setDefault = operation == "default"; $0.login = operation == "login"; $0.dock = operation == "dock" }
    var continuation: CheckedContinuation<Void, Never>?
    let hold: () async -> Void = { await withCheckedContinuation { continuation = $0 } }
    services.defaultOperation = { await hold(); return true }
    services.loginOperation = hold
    services.dockOperation = hold
    let task = Task { await model.applySystem() }
    await settle()
    #expect(continuation != nil)
    model.discoverSync()
    discovery.emit(.found([OnboardingDiscoveryCandidate(cid: "chain", lastActivity: nil)]))
    model.pairWithAnotherMac()
    await settle()
    #expect(joining.cids.isEmpty)
    continuation?.resume()
    await task.value
    await settle()
    #expect(joining.cids == ["chain"])
    #expect(!model.busy)
    #expect(services.setDefaultCalls == (operation == "default" ? 1 : 0))
    #expect(services.loginCalls == (operation == "login" ? [true] : []))
    #expect(services.dockCalls == (operation == "dock" ? 1 : 0))
  }
}
