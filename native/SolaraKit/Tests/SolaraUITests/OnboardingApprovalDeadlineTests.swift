import Foundation
import Testing
@testable import SolaraUI

@MainActor
struct OnboardingApprovalDeadlineTests {
  func approvedJoin(token: String? = "join-token") async -> (OnboardingModel, OnboardingFakeServices, OnboardingFakeJoining, OnboardingFakeScheduler) {
    let store = OnboardingFakeStore()
    let services = OnboardingFakeServices(store: store)
    let discovery = OnboardingFakeDiscovery()
    let joining = OnboardingFakeJoining()
    let scheduler = OnboardingFakeScheduler()
    services.discovery = discovery
    services.joining = joining
    let model = OnboardingModel(services: services, store: store, appName: "Solara", scheduler: scheduler)
    model.maybeStart()
    discovery.emit(.found([OnboardingDiscoveryCandidate(cid: "peer", lastActivity: nil)]))
    model.pairWithAnotherMac()
    for _ in 0..<20 { await Task.yield() }
    services.committedOnboardingJoinToken = token
    joining.committedResult = true
    joining.committedState = .approved
    joining.emit(.approved)
    return (model, services, joining, scheduler)
  }

  @Test func remountAfterOriginalDeadlineImmediatelyShowsDownloading() async {
    let (model, services, _, scheduler) = await approvedJoin()
    scheduler.advance(.seconds(59))
    model.leaveSetup()
    scheduler.advance(.seconds(2))
    let remount = OnboardingModel(services: services, store: services.store, appName: "Solara", scheduler: scheduler)
    remount.maybeStart()
    #expect(remount.syncRoute == .downloading)
    #expect(remount.isActive)
    #expect(services.joinedWrites == 0)
    remount.leaveSetup()
  }

  @Test func remountBeforeOriginalDeadlineUsesOnlyRemainingTime() async {
    let (model, services, joining, scheduler) = await approvedJoin()
    scheduler.advance(.seconds(58))
    model.leaveSetup()
    scheduler.advance(.seconds(1))
    let remount = OnboardingModel(services: services, store: services.store, appName: "Solara", scheduler: scheduler)
    remount.maybeStart()
    #expect(remount.syncRoute == .joining(.approved))
    joining.emitCommitted(.approved)
    scheduler.advance(.seconds(1))
    #expect(remount.syncRoute == .downloading)
    remount.leaveSetup()
  }

  @Test(arguments: [false, true]) func terminalJoinClearsApprovalTime(installed: Bool) async {
    let (model, services, joining, scheduler) = await approvedJoin()
    scheduler.advance(.seconds(59))
    joining.emit(installed ? .installed : .failed(.folderUnavailable))
    for _ in 0..<20 { await Task.yield() }
    joining.committedResult = false
    model.leaveSetup()
    scheduler.advance(.seconds(2))
    services.document = nil
    joining.committedResult = true
    let remount = OnboardingModel(services: services, store: services.store, appName: "Solara", scheduler: scheduler)
    remount.maybeStart()
    #expect(remount.syncRoute == .joining(.approved))
    scheduler.advance(.seconds(59))
    #expect(remount.syncRoute == .joining(.approved))
    scheduler.advance(.seconds(1))
    #expect(remount.syncRoute == .downloading)
    remount.leaveSetup()
  }

  @Test func replacementTokenStartsItsOwnApprovalDeadline() async {
    let (model, services, _, scheduler) = await approvedJoin()
    scheduler.advance(.seconds(59))
    model.leaveSetup()
    scheduler.advance(.seconds(2))
    services.committedOnboardingJoinToken = "replacement-token"
    let remount = OnboardingModel(services: services, store: services.store, appName: "Solara", scheduler: scheduler)
    remount.maybeStart()
    #expect(remount.syncRoute == .joining(.approved))
    scheduler.advance(.seconds(59))
    #expect(remount.syncRoute == .joining(.approved))
    scheduler.advance(.seconds(1))
    #expect(remount.syncRoute == .downloading)
    remount.leaveSetup()
  }

  @Test func approvalWhileNoModelIsMountedKeepsItsOriginalDeadline() async {
    let store = OnboardingFakeStore()
    let services = OnboardingFakeServices(store: store)
    let discovery = OnboardingFakeDiscovery()
    let joining = OnboardingFakeJoining()
    let scheduler = OnboardingFakeScheduler()
    services.discovery = discovery
    services.joining = joining
    var model: OnboardingModel? = OnboardingModel(services: services, store: store, appName: "Solara", scheduler: scheduler)
    model?.maybeStart()
    discovery.emit(.found([OnboardingDiscoveryCandidate(cid: "peer", lastActivity: nil)]))
    model?.pairWithAnotherMac()
    for _ in 0..<20 { await Task.yield() }
    services.committedOnboardingJoinToken = "join-token"
    joining.committedResult = true
    joining.handles.last?.cancelResult = .alreadyCommitted
    model?.leaveSetup()
    weak var released = model
    model = nil
    #expect(released == nil)
    scheduler.advance(.seconds(10))
    joining.emitCommitted(.approved)
    scheduler.advance(.seconds(61))
    joining.committedState = .approved
    let remount = OnboardingModel(services: services, store: store, appName: "Solara", scheduler: scheduler)
    remount.maybeStart()
    #expect(remount.syncRoute == .downloading)
    remount.leaveSetup()
  }

  @Test func detachedOldFailureDoesNotClearReplacementDeadline() async {
    var (model, services, joining, scheduler): (OnboardingModel?, OnboardingFakeServices, OnboardingFakeJoining, OnboardingFakeScheduler) = await approvedJoin()
    model?.leaveSetup()
    weak var released = model
    model = nil
    #expect(released == nil)
    scheduler.advance(.seconds(10))
    services.committedOnboardingJoinToken = "replacement-token"
    let replacement = OnboardingModel(services: services, store: services.store, appName: "Solara", scheduler: scheduler)
    replacement.maybeStart()
    scheduler.advance(.seconds(59))
    replacement.leaveSetup()
    joining.emit(.failed(.folderUnavailable), request: 0)
    scheduler.advance(.seconds(2))
    let remount = OnboardingModel(services: services, store: services.store, appName: "Solara", scheduler: scheduler)
    remount.maybeStart()
    #expect(remount.syncRoute == .downloading)
    remount.leaveSetup()
  }

  @Test func tokenlessRemountKeepsOriginalApprovalDeadline() async {
    let (model, services, _, scheduler) = await approvedJoin(token: nil)
    scheduler.advance(.seconds(59))
    model.leaveSetup()
    scheduler.advance(.seconds(2))
    let remount = OnboardingModel(services: services, store: services.store, appName: "Solara", scheduler: scheduler)
    remount.maybeStart()
    #expect(remount.syncRoute == .downloading)
    remount.leaveSetup()
  }

  @Test func newTokenlessPairingStartsItsOwnApprovalDeadline() async {
    let (model, services, joining, scheduler) = await approvedJoin(token: nil)
    scheduler.advance(.seconds(59))
    model.leaveSetup()
    scheduler.advance(.seconds(2))
    joining.committedResult = false
    let replacement = OnboardingModel(services: services, store: services.store, appName: "Solara", scheduler: scheduler)
    replacement.maybeStart()
    services.discovery?.emit(.found([OnboardingDiscoveryCandidate(cid: "replacement", lastActivity: nil)]))
    replacement.pairWithAnotherMac()
    for _ in 0..<20 { await Task.yield() }
    joining.emit(.approved)
    #expect(replacement.syncRoute == .joining(.approved))
    scheduler.advance(.seconds(59))
    #expect(replacement.syncRoute == .joining(.approved))
    scheduler.advance(.seconds(1))
    #expect(replacement.syncRoute == .downloading)
    replacement.leaveSetup()
  }
}
