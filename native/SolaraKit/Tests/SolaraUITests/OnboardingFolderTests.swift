import Foundation
import Testing
@testable import SolaraUI

@Suite(.serialized)
@MainActor
struct OnboardingFolderTests {
  @Test
  func folderDialogKeepsFailureSurfaceUntilSelection() async {
    let (model, services, _) = OnboardingFixture.make()
    let discovery = OnboardingFakeDiscovery()
    let joining = OnboardingFakeJoining()
    services.discovery = discovery
    services.joining = joining
    model.start(windowId: "w1", isFirstRunOnboarding: true)
    model.discoverSync()
    discovery.emit(.found([.init(cid: "sync", lastActivity: nil)]))
    model.pairWithAnotherMac()
    for _ in 0..<20 where joining.handles.isEmpty { await Task.yield() }
    joining.emit(.failed(.folderUnavailable))
    let task = Task { await model.chooseSyncFolder() }
    for _ in 0..<20 where services.folderChoiceContinuation == nil { await Task.yield() }
    #expect(services.folderChoiceContinuation != nil)
    #expect(model.syncRoute == .joining(.failed(.folderUnavailable)))
    #expect(joining.handles.first?.cancellations == 0)
    services.folderChoiceContinuation?.resume(returning: false)
    services.folderChoiceContinuation = nil
    await task.value
    #expect(model.syncRoute == .joining(.failed(.folderUnavailable)))
    #expect(joining.handles.first?.cancellations == 0)
    model.leaveSetup()
  }

  @Test
  func folderSelectionCancelsPairingBeforeStartingNewDiscovery() async {
    let (model, services, _) = OnboardingFixture.make()
    let discovery = OnboardingFakeDiscovery()
    let joining = OnboardingFakeJoining()
    services.discovery = discovery
    services.joining = joining
    model.start(windowId: "w1", isFirstRunOnboarding: true)
    model.discoverSync()
    discovery.emit(.found([.init(cid: "sync", lastActivity: nil)]))
    model.pairWithAnotherMac()
    for _ in 0..<20 where joining.handles.isEmpty { await Task.yield() }
    joining.emit(.failed(.folderUnavailable))
    let task = Task { await model.chooseSyncFolder() }
    for _ in 0..<20 where services.folderChoiceContinuation == nil { await Task.yield() }
    #expect(joining.handles.first?.cancellations == 0)
    services.folderChoiceContinuation?.resume(returning: true)
    services.folderChoiceContinuation = nil
    await task.value
    #expect(joining.handles.first?.cancellations == 1)
    #expect(model.syncRoute == .discovering)
    model.leaveSetup()
  }

  @Test
  func folderSelectionCannotChangeAnApprovedJoin() async {
    let (model, services, _) = OnboardingFixture.make()
    let discovery = OnboardingFakeDiscovery()
    let joining = OnboardingFakeJoining()
    services.discovery = discovery
    services.joining = joining
    model.start(windowId: "w1", isFirstRunOnboarding: true)
    model.discoverSync()
    discovery.emit(.found([.init(cid: "sync", lastActivity: nil)]))
    model.pairWithAnotherMac()
    for _ in 0..<20 where joining.handles.isEmpty { await Task.yield() }
    joining.emit(.failed(.folderUnavailable))
    let task = Task { await model.chooseSyncFolder() }
    for _ in 0..<20 where services.folderChoiceContinuation == nil { await Task.yield() }
    joining.emit(.approved)
    services.folderChoiceContinuation?.resume(returning: true)
    services.folderChoiceContinuation = nil
    await task.value
    #expect(services.folderChanges == 0)
    #expect(model.syncRoute == .joining(.approved))
    #expect(joining.handles.first?.cancellations == 0)
  }

}
