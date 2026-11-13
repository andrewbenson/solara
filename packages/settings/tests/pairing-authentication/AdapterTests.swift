import AppKit
import Testing
import SolaraUI
import SolaraSyncAdapter
@testable import Adapter

@MainActor final class SurfaceWindow: NSWindow {
  var fixtureVisible = true
  var activeSpace = true
  var minimized = false
  var key = true
  var exposed = true
  weak var fixtureParent: NSWindow?
  var fixtureSheet: NSWindow?
  init() { super.init(contentRect: .zero, styleMask: .borderless, backing: .buffered, defer: true) }
  override var isVisible: Bool { fixtureVisible }
  override var isKeyWindow: Bool { key }
  override var occlusionState: NSWindow.OcclusionState { exposed ? [.visible] : [] }
  override var isMiniaturized: Bool { minimized }
  override var isOnActiveSpace: Bool { activeSpace }
  override var sheetParent: NSWindow? { fixtureParent }
  override var attachedSheet: NSWindow? { fixtureSheet }
  override var sheets: [NSWindow] { fixtureSheet.map { [$0] } ?? [] }
}

@Suite(.serialized) @MainActor struct AdapterBoundaryTests {
  func setup() throws -> (PairingAdapter, TrustedSurface, TrustedAuthorization, SurfaceWindow, SurfaceWindow, TrustedSubscription) {
    NSApplication.shared.setActivationPolicy(.prohibited)
    PairingServices.shared = PairingServices()
    HarnessEnvironment.foreground = true
    HarnessEnvironment.hidden = false
    let adapter = PairingAdapter()
    let parent = SurfaceWindow()
    let sheet = SurfaceWindow()
    parent.fixtureSheet = sheet
    sheet.fixtureParent = parent
    let surface = adapter.attach(to: parent)
    var latest: TrustedSnapshot?
    let subscription = adapter.observe(on: surface) { latest = $0 }
    let arm = try adapter.arm(on: surface, reviewing: nil, options: .init())
    try adapter.present(arm, on: surface)
    let comparison = try #require(latest?.comparison)
    let authorization = try #require(adapter.acknowledge(comparison, matched: true, on: surface))
    return (adapter, surface, authorization, parent, sheet, subscription)
  }

  @Test func foregroundLossAtAllowEntryRefusesNativeCall() async throws {
    let (adapter, surface, authorization, parent, sheet, subscription) = try setup()
    defer { subscription.cancel(); withExtendedLifetime((parent, sheet)) {} }
    HarnessEnvironment.foreground = false
    do { try await adapter.allow(authorization, on: surface); Issue.record("Allow entered native service without foreground") } catch {}
    #expect(PairingServices.shared.allows == 0)
  }

  @Test func livePanelToleratesSoftLossButReplyEndsExemption() async throws {
    let (adapter, surface, authorization, parent, sheet, subscription) = try setup()
    defer { subscription.cancel(); withExtendedLifetime((parent, sheet)) {} }
    try await adapter.allow(authorization, on: surface)
    adapter.surfaceChanged(surface, event: .visibilityChanged)
    #expect(PairingServices.shared.hides == 0)
    PairingServices.shared.live = false
    adapter.surfaceChanged(surface, event: .visibilityChanged)
    #expect(PairingServices.shared.hides == 1)
  }

  @Test func replySnapshotAndGainUseCompleteRealWindowState() async throws {
    let (adapter, surface, authorization, parent, sheet, subscription) = try setup()
    defer { subscription.cancel(); withExtendedLifetime((parent, sheet)) {} }
    try await adapter.allow(authorization, on: surface)
    HarnessEnvironment.foreground = false
    parent.key = false
    sheet.key = false
    parent.exposed = false
    sheet.exposed = false
    PairingServices.shared.reply()
    #expect(PairingServices.shared.foregroundAtReply == false)
    adapter.surfaceChanged(surface, event: .visibilityChanged)
    #expect(PairingServices.shared.hides == 0)
    sheet.key = true
    sheet.exposed = true
    adapter.surfaceChanged(surface, event: .foreground)
    adapter.surfaceChanged(surface, event: .visibilityChanged)
    #expect(PairingServices.shared.hides == 0)
    HarnessEnvironment.foreground = true
    adapter.surfaceChanged(surface, event: .foreground)
    HarnessEnvironment.foreground = false
    adapter.surfaceChanged(surface, event: .visibilityChanged)
    #expect(PairingServices.shared.hides == 1)
  }

  @Test func foregroundReplyUsesVisibleKeySheetEvenWhenParentIsOccluded() async throws {
    let (adapter, surface, authorization, parent, sheet, subscription) = try setup()
    defer { subscription.cancel(); withExtendedLifetime((parent, sheet)) {} }
    try await adapter.allow(authorization, on: surface)
    parent.key = false
    parent.exposed = false
    PairingServices.shared.reply()
    #expect(PairingServices.shared.foregroundAtReply == true)
    sheet.key = false
    adapter.surfaceChanged(surface, event: .visibilityChanged)
    #expect(PairingServices.shared.hides == 1)
  }

  @Test func finalReplyRejectsOffSpace() async throws {
    let (adapter, surface, authorization, parent, sheet, subscription) = try setup()
    defer { subscription.cancel(); withExtendedLifetime((parent, sheet)) {} }
    try await adapter.allow(authorization, on: surface)
    PairingServices.shared.live = false
    sheet.activeSpace = false
    let accepted = await withCheckedContinuation { continuation in PairingServices.shared.validate! { continuation.resume(returning: $0) } }
    #expect(!accepted)
  }

  @Test(arguments: [TrustedSurfaceEvent.visibilityChanged, .removed])
  func publishedGrantIsReportedDuringInterruption(event: TrustedSurfaceEvent) async throws {
    let (adapter, surface, authorization, parent, sheet, subscription) = try setup()
    var delivered: TrustedPhase?
    let observer = adapter.observe(on: surface) { if $0.phase == .sentUnconfirmed { delivered = $0.phase } }
    defer { observer.cancel(); subscription.cancel(); withExtendedLifetime((parent, sheet)) {} }
    try await adapter.allow(authorization, on: surface)
    PairingServices.shared.live = false
    PairingServices.shared.phase = "sentUnconfirmed"
    HarnessEnvironment.foreground = false
    adapter.surfaceChanged(surface, event: event)
    #expect(delivered == .sentUnconfirmed)
  }

  @Test func finalReplyAllowsLossOfKeyAndOcclusionOnActiveSpace() async throws {
    let (adapter, surface, authorization, parent, sheet, subscription) = try setup()
    defer { subscription.cancel(); withExtendedLifetime((parent, sheet)) {} }
    try await adapter.allow(authorization, on: surface)
    PairingServices.shared.live = false
    HarnessEnvironment.foreground = false
    let accepted = await withCheckedContinuation { continuation in PairingServices.shared.validate! { continuation.resume(returning: $0) } }
    #expect(accepted)
  }
}

@Suite(.serialized) @MainActor struct AdapterPollingTests {
  func spin(_ seconds: TimeInterval) { RunLoop.main.run(until: Date().addingTimeInterval(seconds)) }

  func fresh() -> PairingAdapter {
    NSApplication.shared.setActivationPolicy(.prohibited)
    PairingServices.shared = PairingServices()
    HarnessEnvironment.foreground = true
    HarnessEnvironment.hidden = false
    return PairingAdapter()
  }

  @Test func observerWithoutAShownSurfaceDoesNotPoll() {
    let adapter = fresh()
    var count = 0
    let subscription = adapter.observe(on: nil) { _ in count += 1 }
    defer { subscription.cancel() }
    spin(0.45)
    #expect(count == 1)
  }

  @Test func shownSurfacePollsAndHidingItStops() {
    let adapter = fresh()
    let window = SurfaceWindow()
    defer { withExtendedLifetime(window) {} }
    let surface = adapter.attach(to: window)
    var count = 0
    let subscription = adapter.observe(on: surface) { _ in count += 1 }
    defer { subscription.cancel() }
    spin(0.45)
    #expect(count >= 3)
    window.fixtureVisible = false
    spin(0.25)
    let stopped = count
    spin(0.45)
    #expect(count == stopped)
  }

  @Test func aFullyCoveredSurfaceStopsPolling() {
    let adapter = fresh()
    let window = SurfaceWindow()
    defer { withExtendedLifetime(window) {} }
    let surface = adapter.attach(to: window)
    var count = 0
    let subscription = adapter.observe(on: surface) { _ in count += 1 }
    defer { subscription.cancel() }
    spin(0.3)
    #expect(count >= 2)
    window.exposed = false
    spin(0.25)
    let stopped = count
    spin(0.45)
    #expect(count == stopped)
  }

  @Test func showingTheSurfaceAgainPublishesAndResumesPolling() {
    let adapter = fresh()
    let window = SurfaceWindow()
    defer { withExtendedLifetime(window) {} }
    window.fixtureVisible = false
    let surface = adapter.attach(to: window)
    var count = 0
    let subscription = adapter.observe(on: surface) { _ in count += 1 }
    defer { subscription.cancel() }
    spin(0.3)
    #expect(count == 1)
    window.fixtureVisible = true
    NotificationCenter.default.post(name: NSWindow.didChangeOcclusionStateNotification, object: window)
    #expect(count == 2)
    spin(0.45)
    #expect(count >= 5)
  }

  @Test func aLiveArmKeepsPollingWhileItsWindowIsHidden() throws {
    let adapter = fresh()
    let window = SurfaceWindow()
    defer { withExtendedLifetime(window) {} }
    let surface = adapter.attach(to: window)
    var count = 0
    let subscription = adapter.observe(on: surface) { _ in count += 1 }
    defer { subscription.cancel() }
    _ = try adapter.arm(on: surface, reviewing: nil, options: .init())
    window.fixtureVisible = false
    let before = count
    spin(0.45)
    #expect(count >= before + 3)
  }
}
