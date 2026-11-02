import AppKit
import Testing
@testable import SolaraUI

@Suite(.serialized)
@MainActor
struct SyncPairingAuthenticationTests {
  private func makeProbe() -> SyncPairingProbeView {
    let probe = SyncPairingProbeView()
    probe.notificationCenter = NotificationCenter()
    probe.workspaceNotificationCenter = NotificationCenter()
    probe.distributedNotificationCenter = NotificationCenter()
    probe.applicationIsActive = { true }
    return probe
  }

  private func postSoftLoss(_ loss: String, window: PairingProbeTestWindow, probe: SyncPairingProbeView) {
    if loss == "resignKey" {
      window.key = false
      probe.notificationCenter.post(name: NSWindow.didResignKeyNotification, object: window)
    } else if loss == "resignActive" {
      probe.applicationIsActive = { false }
      probe.notificationCenter.post(name: NSApplication.didResignActiveNotification, object: nil)
    } else {
      window.exposed = false
      probe.notificationCenter.post(name: NSWindow.didChangeOcclusionStateNotification, object: window)
    }
  }

  @Test(arguments: ["resignKey", "resignActive", "occlusion"])
  func authenticationSoftLossKeepsArmAndCompletes(loss: String) async throws {
    let service = TrustedPairingTestService()
    let model = SyncTrustedPairingModel(service: service, now: { service.clock })
    let window = PairingProbeTestWindow()
    let probe = makeProbe()
    model.attach(to: window)
    window.contentView = probe
    defer { probe.stopObserving(); model.teardown() }
    service.holdAllow = true
    model.connect()
    let arm = try #require(model.arm)
    let comparison = service.ready(model)
    model.setMatched(true, comparison: comparison, render: model.renderGeneration)
    let render = model.renderGeneration
    let action = model.actionGeneration
    model.captureAllow()()
    for _ in 0..<30 where service.heldAllow == nil { await Task.yield() }
    #expect(service.heldAllow != nil)
    probe.changed = model.captureSurfaceChange()
    postSoftLoss(loss, window: window, probe: probe)
    service.publish(phase: .comparing, arm: arm, comparison: comparison, foreground: false)
    #expect(model.arm === arm)
    #expect(model.phase == .authenticating)
    #expect(model.comparison === comparison)
    #expect(model.presentedComparison == nil)
    #expect(model.isPresented)
    #expect(model.renderGeneration == render)
    #expect(model.actionGeneration == action)
    #expect(service.ends.isEmpty)
    service.heldAllow?.resume()
    service.heldAllow = nil
    for _ in 0..<30 where service.granted.isEmpty { await Task.yield() }
    #expect(service.granted.count == 1)
    service.publish(phase: .sentUnconfirmed, arm: arm, foreground: false)
    #expect(model.phase == .sentUnconfirmed)
    #expect(!model.canAllow)
  }

  @Test func queuedAuthenticationSoftLossInterruptsBeforeService() async throws {
    let (service, model, window) = SyncTrustedPairingModelTests().setup()
    defer { _ = window.windowNumber; model.teardown() }
    model.connect()
    let comparison = service.ready(model)
    model.setMatched(true, comparison: comparison, render: model.renderGeneration)
    model.captureAllow()()
    model.surfaceChanged(.visibilityChanged)
    for _ in 0..<30 { await Task.yield() }
    #expect(service.allowed.isEmpty)
    #expect(service.granted.isEmpty)
    #expect(model.phase == .ended(.interrupted))
    #expect(model.arm == nil)
  }

  @Test(arguments: ["resignKey", "resignActive", "occlusion"])
  func softLossAfterReplyInterruptsBeforePublication(loss: String) async throws {
    let service = TrustedPairingTestService()
    let model = SyncTrustedPairingModel(service: service, now: { service.clock })
    let window = PairingProbeTestWindow()
    let probe = makeProbe()
    model.attach(to: window)
    window.contentView = probe
    defer { probe.stopObserving(); model.teardown() }
    service.holdAllow = true
    model.connect()
    let arm = try #require(model.arm)
    let comparison = service.ready(model)
    model.setMatched(true, comparison: comparison, render: model.renderGeneration)
    model.captureAllow()()
    for _ in 0..<30 where service.heldAllow == nil { await Task.yield() }
    service.livePanelArm = nil
    probe.changed = model.captureSurfaceChange()
    postSoftLoss(loss, window: window, probe: probe)
    #expect(model.phase == .ended(.interrupted))
    #expect(model.arm == nil)
    #expect(service.ends == [.cancel])
    service.heldAllow?.resume()
    service.heldAllow = nil
    for _ in 0..<30 { await Task.yield() }
    service.publish(phase: .sentUnconfirmed, arm: arm)
    #expect(model.phase == .ended(.interrupted))
    #expect(service.granted.isEmpty)
  }

  @Test(arguments: ["resignKey", "resignActive", "occlusion"])
  func panelTailAfterReplyThenRegainPublishes(loss: String) async throws {
    let service = TrustedPairingTestService()
    let model = SyncTrustedPairingModel(service: service, now: { service.clock })
    let window = PairingProbeTestWindow()
    let probe = makeProbe()
    model.attach(to: window)
    window.contentView = probe
    defer { probe.stopObserving(); model.teardown() }
    service.holdAllow = true
    model.connect()
    let comparison = service.ready(model)
    model.setMatched(true, comparison: comparison, render: model.renderGeneration)
    model.captureAllow()()
    for _ in 0..<30 where service.heldAllow == nil { await Task.yield() }
    window.key = false
    window.exposed = false
    service.livePanelArm = nil
    service.toleratingSoftLoss = true
    probe.changed = model.captureSurfaceChange()
    postSoftLoss(loss, window: window, probe: probe)
    window.key = true
    window.exposed = true
    probe.applicationIsActive = { true }
    probe.notificationCenter.post(name: NSWindow.didBecomeKeyNotification, object: window)
    probe.notificationCenter.post(name: NSApplication.didBecomeActiveNotification, object: nil)
    #expect(model.phase == .authenticating)
    #expect(service.ends.isEmpty)
    service.heldAllow?.resume()
    service.heldAllow = nil
    for _ in 0..<30 where service.granted.isEmpty { await Task.yield() }
    #expect(service.granted.count == 1)
  }

  @Test func hardLossEndsArmDuringAuthentication() throws {
    let (service, model, window) = SyncTrustedPairingModelTests().setup()
    defer { _ = window.windowNumber; model.teardown() }
    model.connect()
    let arm = try #require(model.arm)
    let comparison = service.ready(model)
    service.publish(phase: .authenticating, arm: arm, comparison: comparison)
    model.surfaceChanged(.unavailable)
    #expect(model.phase == .ended(.interrupted))
    #expect(model.arm == nil)
    #expect(service.ends == [.cancel])
  }

  @Test(arguments: ["hidden", "miniaturized", "parentNotVisible", "sheetNotVisible", "remounted", "offSpace", "sessionResign", "screensSleep", "systemSleep", "screensaver"])
  func comparingHardLossKeepsArmAndExplicitPresentationReturnsUnchecked(loss: String) async throws {
    let service = TrustedPairingTestService()
    let model = SyncTrustedPairingModel(service: service, now: { service.clock })
    let parent = PairingProbeTestWindow()
    let window = PairingProbeTestWindow()
    parent.fixtureSheets = [window]
    window.fixtureParent = parent
    let probe = makeProbe()
    probe.sensitive = true
    model.attach(to: window)
    window.contentView = probe
    defer { probe.stopObserving(); model.teardown() }
    model.connect()
    let arm = try #require(model.arm)
    let comparison = service.ready(model)
    model.setMatched(true, comparison: comparison, render: model.renderGeneration)
    #expect(model.canAllow)
    let oldAllow = model.captureAllow()
    let oldToggle = model.captureToggle()
    probe.changed = model.captureSurfaceChange()
    switch loss {
    case "hidden": probe.notificationCenter.post(name: NSApplication.didHideNotification, object: nil)
    case "miniaturized": probe.notificationCenter.post(name: NSWindow.didMiniaturizeNotification, object: window)
    case "parentNotVisible": parent.setVisible(false)
    case "sheetNotVisible": window.setVisible(false)
    case "remounted":
      window.contentView = nil
      window.contentView = probe
    case "offSpace":
      window.activeSpace = false
      probe.workspaceNotificationCenter.post(name: NSWorkspace.activeSpaceDidChangeNotification, object: nil)
    case "sessionResign": probe.workspaceNotificationCenter.post(name: NSWorkspace.sessionDidResignActiveNotification, object: nil)
    case "screensSleep": probe.workspaceNotificationCenter.post(name: NSWorkspace.screensDidSleepNotification, object: nil)
    case "systemSleep": probe.workspaceNotificationCenter.post(name: NSWorkspace.willSleepNotification, object: nil)
    default: probe.distributedNotificationCenter.post(name: Notification.Name("com.apple.screensaver.didstart"), object: nil)
    }
    #expect(service.events == [loss == "remounted" ? .remounted : .unavailable])
    #expect(model.arm === arm)
    #expect(model.phase == .comparing)
    #expect(model.comparison == nil)
    #expect(model.requiresExplicitPresentation)
    #expect(!model.matched)
    #expect(!model.canAllow)
    #expect(service.ends.isEmpty)
    parent.setVisible(true)
    window.setVisible(true)
    window.activeSpace = true
    service.publish(phase: .comparing, arm: arm, comparison: comparison)
    #expect(model.comparison == nil)
    #expect(!model.canAllow)
    model.present()
    let freshComparison = service.ready(model)
    #expect(model.arm === arm)
    #expect(service.arms.count == 1)
    #expect(service.presentations.count == 1)
    #expect(service.presentations.first === arm)
    #expect(model.isPresented)
    #expect(model.comparison === freshComparison)
    #expect(model.presentedComparison === freshComparison)
    #expect(!model.requiresExplicitPresentation)
    #expect(!model.matched)
    #expect(!model.canAllow)
    oldToggle(true)
    oldAllow()
    await Task.yield()
    #expect(!model.matched)
    #expect(service.allowed.isEmpty)
  }

  @Test(arguments: ["removed", "miniaturized", "hidden", "parentNotVisible", "sheetNotVisible", "remounted", "offSpace", "sessionResign", "screensSleep", "systemSleep", "screensaver"])
  func authenticationHardLossEndsAndLateSuccessGrantsNothing(loss: String) async throws {
    let (service, model, window) = SyncTrustedPairingModelTests().setup()
    defer { _ = window.windowNumber; model.teardown() }
    service.holdAllow = true
    model.connect()
    let arm = try #require(model.arm)
    let comparison = service.ready(model)
    model.setMatched(true, comparison: comparison, render: model.renderGeneration)
    model.captureAllow()()
    for _ in 0..<30 where service.heldAllow == nil { await Task.yield() }
    #expect(service.heldAllow != nil)
    let event: TrustedSurfaceEvent = loss == "removed" ? .removed : loss == "remounted" ? .remounted : .unavailable
    model.surfaceChanged(event)
    #expect(model.phase == .ended(.interrupted))
    #expect(model.arm == nil)
    #expect(model.comparison == nil)
    #expect(!model.isPresented)
    service.heldAllow?.resume()
    service.heldAllow = nil
    for _ in 0..<30 { await Task.yield() }
    service.publish(phase: .sentUnconfirmed, arm: arm)
    #expect(service.granted.isEmpty)
    #expect(model.phase == .ended(.interrupted))
  }

  @Test(arguments: [TrustedSurfaceEvent.unavailable, .removed, .remounted])
  func queuedAuthenticationHardLossNeverEntersService(event: TrustedSurfaceEvent) async throws {
    let (service, model, window) = SyncTrustedPairingModelTests().setup()
    defer { _ = window.windowNumber; model.teardown() }
    model.connect()
    let comparison = service.ready(model)
    model.setMatched(true, comparison: comparison, render: model.renderGeneration)
    model.captureAllow()()
    model.surfaceChanged(event)
    for _ in 0..<30 { await Task.yield() }
    #expect(model.phase == .ended(.interrupted))
    #expect(model.arm == nil)
    #expect(service.allowed.isEmpty)
  }

  @Test(arguments: [TrustedPhase.choosing, .preparing, .comparing])
  func softLossOutsideAuthenticationStillHides(phase: TrustedPhase) async throws {
    let (service, model, window) = SyncTrustedPairingModelTests().setup()
    defer { _ = window.windowNumber; model.teardown() }
    model.connect()
    let arm = try #require(model.arm)
    let comparison = service.ready(model)
    service.publish(phase: phase, arm: arm, comparison: comparison)
    let allow = model.captureAllow()
    model.surfaceChanged(.visibilityChanged)
    allow()
    for _ in 0..<30 { await Task.yield() }
    #expect(model.arm === arm)
    #expect(model.comparison == nil)
    #expect(model.requiresExplicitPresentation)
    #expect(!model.canAllow)
    #expect(service.allowed.isEmpty)
    #expect(service.events == [.visibilityChanged])
  }

  @Test(arguments: ["marker", "foreignArm", "missingComparison", "replacementComparison", "phase", "expired"])
  func authenticationInvalidationCancelsPendingGrant(row: String) async throws {
    let (service, model, window) = SyncTrustedPairingModelTests().setup()
    defer { _ = window.windowNumber; model.teardown() }
    service.holdAllow = true
    model.connect()
    let arm = try #require(model.arm)
    let comparison = service.ready(model)
    model.setMatched(true, comparison: comparison, render: model.renderGeneration)
    model.captureAllow()()
    for _ in 0..<30 where service.heldAllow == nil { await Task.yield() }
    #expect(service.heldAllow != nil)
    let replacement = TrustedComparison(arm: arm, surface: service.surface, presentation: TrustedPresentation(), code: "DEF567", claimedName: "Other Mac", nameWarning: false)
    if row == "expired" { service.clock = arm.deadline }
    service.publish(phase: row == "phase" ? .preparing : .comparing, arm: row == "foreignArm" ? TrustedArm(deadline: 130) : arm, comparison: row == "missingComparison" ? nil : row == "replacementComparison" ? replacement : comparison, foreground: false, verified: row != "marker")
    #expect(model.arm == nil)
    #expect(model.comparison == nil)
    #expect(service.ends == [.cancel])
    service.heldAllow?.resume()
    service.heldAllow = nil
    for _ in 0..<30 { await Task.yield() }
    #expect(service.granted.isEmpty)
    service.publish(phase: .sentUnconfirmed, arm: arm)
    #expect(model.phase == .ended(row == "expired" ? .expired : .verificationFailed))
  }

  @Test(arguments: ["foreground", "resignKey", "resignActive", "occlusion", "closed", "miniaturized", "hidden", "parentNotVisible", "sheetNotVisible", "offSpace"])
  func windowStateClassification(row: String) {
    let state = SyncPairingWindowState.classify(attached: row != "closed", visible: row != "sheetNotVisible", parentVisible: row != "parentNotVisible", miniaturized: row == "miniaturized", hidden: row == "hidden", active: row != "resignActive", key: row != "resignKey", occluded: row == "occlusion", onActiveSpace: row != "offSpace")
    let expected: SyncPairingWindowState = row == "foreground" ? .foreground : ["resignKey", "resignActive", "occlusion"].contains(row) ? .softLoss : .hardLoss
    #expect(state == expected)
    #expect(state.event == (expected == .foreground ? nil : expected == .softLoss ? .visibilityChanged : .unavailable))
  }
  @Test(arguments: ["closed", "miniaturized", "hidden", "offSpace", "session", "screensSleep", "systemSleep", "screensaver"])
  func probeHardLifecycleEndsLiveAuthentication(row: String) async throws {
    let service = TrustedPairingTestService()
    let model = SyncTrustedPairingModel(service: service, now: { service.clock })
    let window = PairingProbeTestWindow()
    let probe = makeProbe()
    model.attach(to: window)
    window.contentView = probe
    defer { probe.stopObserving(); model.teardown() }
    service.holdAllow = true
    model.connect()
    let comparison = service.ready(model)
    model.setMatched(true, comparison: comparison, render: model.renderGeneration)
    model.captureAllow()()
    for _ in 0..<30 where service.heldAllow == nil { await Task.yield() }
    #expect(service.heldAllow != nil)
    probe.changed = model.captureSurfaceChange()
    switch row {
    case "closed": probe.notificationCenter.post(name: NSWindow.willCloseNotification, object: window)
    case "miniaturized": probe.notificationCenter.post(name: NSWindow.didMiniaturizeNotification, object: window)
    case "hidden": probe.notificationCenter.post(name: NSApplication.didHideNotification, object: nil)
    case "offSpace":
      window.activeSpace = false
      probe.workspaceNotificationCenter.post(name: NSWorkspace.activeSpaceDidChangeNotification, object: nil)
    case "session": probe.workspaceNotificationCenter.post(name: NSWorkspace.sessionDidResignActiveNotification, object: nil)
    case "screensSleep": probe.workspaceNotificationCenter.post(name: NSWorkspace.screensDidSleepNotification, object: nil)
    case "systemSleep": probe.workspaceNotificationCenter.post(name: NSWorkspace.willSleepNotification, object: nil)
    default: probe.distributedNotificationCenter.post(name: Notification.Name("com.apple.screensaver.didstart"), object: nil)
    }
    for _ in 0..<30 where model.arm != nil { try? await Task.sleep(for: .milliseconds(10)) }
    #expect(model.phase == .ended(.interrupted))
    #expect(model.arm == nil)
    #expect(service.ends == (row == "closed" ? [] : [.cancel]))
    service.heldAllow?.resume()
    service.heldAllow = nil
    for _ in 0..<30 { await Task.yield() }
    #expect(service.granted.isEmpty)
  }

  @Test(arguments: ["closed", "miniaturized", "hidden", "parentNotVisible", "sheetNotVisible", "offSpace", "session", "screensSleep", "systemSleep", "screensaver"], ["tail", "foreground", "regained"])
  func hardLossAtEveryReplyPointCancelsPendingGrant(loss: String, point: String) async throws {
    let service = TrustedPairingTestService()
    let model = SyncTrustedPairingModel(service: service, now: { service.clock })
    let parent = PairingProbeTestWindow()
    let window = PairingProbeTestWindow()
    parent.fixtureSheets = [window]
    window.fixtureParent = parent
    let probe = makeProbe()
    probe.sensitive = true
    model.attach(to: parent)
    window.contentView = probe
    defer { probe.stopObserving(); model.teardown() }
    service.holdAllow = true
    model.connect()
    let comparison = service.ready(model)
    model.setMatched(true, comparison: comparison, render: model.renderGeneration)
    model.captureAllow()()
    for _ in 0..<30 where service.heldAllow == nil { await Task.yield() }
    service.livePanelArm = nil
    service.toleratingSoftLoss = point != "foreground"
    probe.changed = model.captureSurfaceChange()
    if point == "tail" { parent.key = false; window.key = false; window.exposed = false }
    if point == "regained" { probe.notificationCenter.post(name: NSWindow.didBecomeKeyNotification, object: window) }
    switch loss {
    case "closed": probe.notificationCenter.post(name: NSWindow.willCloseNotification, object: window)
    case "miniaturized": probe.notificationCenter.post(name: NSWindow.didMiniaturizeNotification, object: window)
    case "hidden": probe.notificationCenter.post(name: NSApplication.didHideNotification, object: nil)
    case "parentNotVisible": parent.setVisible(false)
    case "sheetNotVisible": window.setVisible(false)
    case "offSpace":
      window.activeSpace = false
      probe.workspaceNotificationCenter.post(name: NSWorkspace.activeSpaceDidChangeNotification, object: nil)
    case "session": probe.workspaceNotificationCenter.post(name: NSWorkspace.sessionDidResignActiveNotification, object: nil)
    case "screensSleep": probe.workspaceNotificationCenter.post(name: NSWorkspace.screensDidSleepNotification, object: nil)
    case "systemSleep": probe.workspaceNotificationCenter.post(name: NSWorkspace.willSleepNotification, object: nil)
    default: probe.distributedNotificationCenter.post(name: Notification.Name("com.apple.screensaver.didstart"), object: nil)
    }
    #expect(model.phase == .ended(.interrupted))
    #expect(model.arm == nil)
    service.heldAllow?.resume()
    service.heldAllow = nil
    for _ in 0..<30 { await Task.yield() }
    #expect(service.granted.isEmpty)
  }

  @Test func probeRejectsOffSpaceThroughWorkspaceObserver() {
    let window = PairingProbeTestWindow()
    let probe = makeProbe()
    var events: [TrustedSurfaceEvent] = []
    probe.changed = { events.append($0) }
    window.contentView = probe
    defer { probe.stopObserving() }
    events.removeAll()
    window.activeSpace = false
    probe.workspaceNotificationCenter.post(name: NSWorkspace.activeSpaceDidChangeNotification, object: nil)
    #expect(events == [.unavailable])
  }

  @Test(arguments: ["key", "active", "occlusion"])
  func probeObservesRecomputedSoftLoss(row: String) {
    let window = PairingProbeTestWindow()
    let probe = makeProbe()
    var events: [TrustedSurfaceEvent] = []
    probe.changed = { events.append($0) }
    window.contentView = probe
    defer { probe.stopObserving() }
    events.removeAll()
    let name = row == "key" ? NSWindow.didResignKeyNotification : row == "active" ? NSApplication.didResignActiveNotification : NSWindow.didChangeOcclusionStateNotification
    if row == "key" { window.key = false }
    if row == "active" { probe.applicationIsActive = { false } }
    if row == "occlusion" { window.exposed = false }
    probe.notificationCenter.post(name: name, object: row == "active" ? nil : window)
    #expect(events == [.visibilityChanged])
  }

  @Test(arguments: [NSWindow.didBecomeKeyNotification, NSApplication.didBecomeActiveNotification, NSWindow.didDeminiaturizeNotification, NSApplication.didUnhideNotification])
  func probeGainDoesNotBecomeSoftLoss(name: Notification.Name) {
    let window = PairingProbeTestWindow()
    let probe = makeProbe()
    var events: [TrustedSurfaceEvent] = []
    probe.changed = { events.append($0) }
    window.contentView = probe
    defer { probe.stopObserving() }
    events.removeAll()
    window.key = false
    window.exposed = false
    probe.notificationCenter.post(name: name, object: window)
    #expect(events.isEmpty)
  }

  @Test(arguments: [NSWindow.didBecomeKeyNotification, NSApplication.didBecomeActiveNotification, NSWindow.didChangeOcclusionStateNotification])
  func probeReportsGainOnlyForCompleteForegroundState(name: Notification.Name) {
    let window = PairingProbeTestWindow()
    let probe = makeProbe()
    var events: [TrustedSurfaceEvent] = []
    probe.changed = { events.append($0) }
    window.contentView = probe
    defer { probe.stopObserving() }
    for missing in ["key", "active", "occlusion"] {
      window.key = missing != "key"
      window.exposed = missing != "occlusion"
      probe.applicationIsActive = { missing != "active" }
      events.removeAll()
      probe.notificationCenter.post(name: name, object: name == NSApplication.didBecomeActiveNotification ? nil : window)
      #expect(!events.contains(.foreground))
    }
    window.key = true
    window.exposed = true
    probe.applicationIsActive = { true }
    events.removeAll()
    probe.notificationCenter.post(name: name, object: name == NSApplication.didBecomeActiveNotification ? nil : window)
    #expect(events == [.foreground])
  }

  @Test(arguments: ["resignKey", "resignActive", "occlusion"])
  func regainedForegroundThenNewLossCancelsPendingGrant(loss: String) async throws {
    let service = TrustedPairingTestService()
    let model = SyncTrustedPairingModel(service: service, now: { service.clock })
    let window = PairingProbeTestWindow()
    let probe = makeProbe()
    model.attach(to: window)
    window.contentView = probe
    defer { probe.stopObserving(); model.teardown() }
    service.holdAllow = true
    model.connect()
    let comparison = service.ready(model)
    model.setMatched(true, comparison: comparison, render: model.renderGeneration)
    model.captureAllow()()
    for _ in 0..<30 where service.heldAllow == nil { await Task.yield() }
    service.livePanelArm = nil
    service.toleratingSoftLoss = true
    probe.changed = model.captureSurfaceChange()
    probe.notificationCenter.post(name: NSWindow.didBecomeKeyNotification, object: window)
    postSoftLoss(loss, window: window, probe: probe)
    #expect(model.phase == .ended(.interrupted))
    #expect(model.arm == nil)
    service.heldAllow?.resume()
    service.heldAllow = nil
    for _ in 0..<30 { await Task.yield() }
    #expect(service.granted.isEmpty)
  }

  @Test func probeParentToSheetKeyHandoffKeepsComparison() {
    let parent = PairingProbeTestWindow()
    let sheet = PairingProbeTestWindow()
    parent.fixtureSheets = [sheet]
    sheet.fixtureParent = parent
    parent.key = false
    sheet.key = true
    let probe = makeProbe()
    var events: [TrustedSurfaceEvent] = []
    probe.changed = { events.append($0) }
    parent.contentView = probe
    defer { probe.stopObserving() }
    events.removeAll()
    probe.notificationCenter.post(name: NSWindow.didResignKeyNotification, object: parent)
    #expect(events == [.foreground])
  }

  @Test func probeParentOcclusionDoesNotHideForegroundSheet() {
    let parent = PairingProbeTestWindow()
    let sheet = PairingProbeTestWindow()
    parent.fixtureSheets = [sheet]
    sheet.fixtureParent = parent
    let probe = makeProbe()
    probe.sensitive = true
    var events: [TrustedSurfaceEvent] = []
    probe.changed = { events.append($0) }
    sheet.contentView = probe
    defer { probe.stopObserving() }
    events.removeAll()
    parent.exposed = false
    probe.notificationCenter.post(name: NSWindow.didChangeOcclusionStateNotification, object: parent)
    #expect(events == [.foreground])
    events.removeAll()
    parent.exposed = true
    probe.notificationCenter.post(name: NSWindow.didChangeOcclusionStateNotification, object: parent)
    #expect(events == [.foreground])
  }

  @Test func probeVisibilityGainDoesNotBecomeSoftLoss() {
    let window = PairingProbeTestWindow()
    let probe = makeProbe()
    var events: [TrustedSurfaceEvent] = []
    probe.changed = { events.append($0) }
    window.contentView = probe
    defer { probe.stopObserving() }
    window.setVisible(false)
    #expect(events == [.unavailable])
    events.removeAll()
    window.exposed = false
    window.setVisible(true)
    #expect(events.isEmpty)
  }

  @Test(arguments: [TrustedSurfaceEvent.visibilityChanged, .removed])
  func publicationAlreadySentAtInterruptionKeepsSentResult(event: TrustedSurfaceEvent) async throws {
    let (service, model, window) = SyncTrustedPairingModelTests().setup()
    defer { _ = window.windowNumber; model.teardown() }
    service.holdAllow = true
    model.connect()
    let arm = try #require(model.arm)
    let comparison = service.ready(model)
    model.setMatched(true, comparison: comparison, render: model.renderGeneration)
    model.captureAllow()()
    for _ in 0..<30 where service.heldAllow == nil { await Task.yield() }
    service.livePanelArm = nil
    service.onSurfaceChanged = { service.publish(phase: .sentUnconfirmed, arm: arm, foreground: false) }
    model.surfaceChanged(event)
    #expect(model.phase == .sentUnconfirmed)
    #expect(model.arm == nil)
    service.onSurfaceChanged = nil
    service.heldAllow?.resume()
    service.heldAllow = nil
  }

  @Test(arguments: [NSWindow.didBecomeKeyNotification, NSApplication.didBecomeActiveNotification])
  func replyThenGainAllowsPublication(name: Notification.Name) async throws {
    let service = TrustedPairingTestService()
    let model = SyncTrustedPairingModel(service: service, now: { service.clock })
    let window = PairingProbeTestWindow()
    let probe = makeProbe()
    model.attach(to: window)
    window.contentView = probe
    defer { probe.stopObserving(); model.teardown() }
    service.holdAllow = true
    model.connect()
    let comparison = service.ready(model)
    model.setMatched(true, comparison: comparison, render: model.renderGeneration)
    model.captureAllow()()
    for _ in 0..<30 where service.heldAllow == nil { await Task.yield() }
    service.livePanelArm = nil
    probe.changed = model.captureSurfaceChange()
    probe.notificationCenter.post(name: name, object: window)
    #expect(model.phase == .authenticating)
    #expect(service.ends.isEmpty)
    service.heldAllow?.resume()
    service.heldAllow = nil
    for _ in 0..<30 where service.granted.isEmpty { await Task.yield() }
    #expect(service.granted.count == 1)
  }

}


@MainActor
private final class PairingProbeTestWindow: NSWindow {
  weak var fixtureParent: NSWindow?
  var fixtureSheets: [NSWindow] = []
  override var sheetParent: NSWindow? { fixtureParent }
  override var sheets: [NSWindow] { fixtureSheets }
  var activeSpace = true
  var exposed = true
  var key = true
  private var showing = true
  func setVisible(_ value: Bool) {
    willChangeValue(forKey: "visible")
    showing = value
    didChangeValue(forKey: "visible")
  }
  init() {
    super.init(contentRect: NSRect(x: 0, y: 0, width: 100, height: 100), styleMask: [.titled], backing: .buffered, defer: true)
  }
  override var isVisible: Bool { showing }
  override var isMiniaturized: Bool { false }
  override var isOnActiveSpace: Bool { activeSpace }
  override var isKeyWindow: Bool { key }
  override var occlusionState: NSWindow.OcclusionState { exposed ? [.visible] : [] }
}
