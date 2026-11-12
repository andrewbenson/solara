import AppKit
import SolaraModel
@testable import SolaraStore
@testable import SolaraUI
import Testing

@MainActor
@Suite(.serialized) struct TabSleepRunnerTests {
  @MainActor
  private final class Fixture {
    let store: Store
    let pages = PageRegistry()
    let notifications = NotificationCenter()
    var now: Double = 0
    var commands: [String: [PageCommand]] = [:]
    var replies: [String: Result<PageValue, PageRegistryError>] = [:]
    var outcomes: [String: String] = [:]
    var beforeReasons: ((String) -> Void)?
    var pendingPermission: Set<String> = []
    var scheduledTick: (@MainActor () -> Void)?
    var scheduledInterval: Double?
    var timerCancelled = false
    var epoch = 0

    init(count: Int = 1, pinned: Bool = false, backgroundSplit: Bool = false, registerPages: Bool = true) throws {
      var state = BrowserState()
      let profile = BrowserState.defaultProfile.id
      var window = BrowserWindow(id: "window", profileId: profile, incognito: false, frame: nil, createdAt: 0)
      window.tabIds = ["active"]
      window.activeTabIds[profile] = "active"
      var active = Tab(id: "active", windowId: window.id, profileId: profile, url: "https://active.example/", now: 100)
      active.navigation = Navigation(url: active.url, seq: 1)
      state.tabs[active.id] = active
      for index in 0..<count {
        let id = "target\(index)"
        var tab = Tab(id: id, windowId: window.id, profileId: profile, url: "https://\(id).example/", now: Double(index))
        tab.navigation = Navigation(url: tab.url, seq: 2 + Double(index))
        tab.pinned = pinned
        if pinned { tab.pinnedUrl = tab.url }
        state.tabs[id] = tab
        if pinned { window.tabIds.insert(id, at: index) }
        else { window.tabIds.append(id) }
      }
      state.windows[window.id] = window
      state.windowOrder = [window.id]
      state.ui.focusedWindowId = window.id
      if backgroundSplit {
        state.splits["background"] = SplitView(id: "background", windowId: "window", tabIds: ["target0", "target1"], orientation: "horizontal", sizes: [0.5, 0.5])
      }
      store = Store(state: state)
      epoch = store.registerKeepAliveRuntime()
      if registerPages {
        #expect(pages.configureSnapshot { capture in
          capture().map { descriptor in
            var descriptor = descriptor
            descriptor.protectionKnown = true
            return descriptor
          }
        })
      }
      for index in 0..<count {
        let id = "target\(index)"
        try report(id, ["type": "created", "generation": "G", "engine": "chromium",
          "navigationSeq": JSONValue(2 + index), "contextRevision": 1, "wasNewTab": false, "newTabShownUrl": .null])
        try report(id, ["type": "ready", "generation": "G", "browserId": JSONValue(100 + index)])
        try feed(id)
        if registerPages { register(id) }
      }
    }

    func register(_ id: String, generation: String = "G") {
      pages.register(tabID: id, engine: .chromium, host: .pooled, sessionGeneration: generation) { [weak self] command, finish in
        guard let self else { return }
        commands[id, default: []].append(command)
        if command == .reasonsNotToSleep {
          beforeReasons?(id)
          finish(replies[id] ?? .success(.array([])))
        } else {
          finish(.success(.string(outcomes[id] ?? "discarded")))
        }
      }
    }

    func report(_ id: String, _ report: JSONValue) throws {
      try store.dispatch(Command("pageReport", [.string(id), report]))
    }

    func feed(_ id: String, handled: Int = 0, keep: JSONValue? = nil, generation: String = "G") throws {
      try report(id, ["type": "keepAlive", "generation": .string(generation), "epoch": JSONValue(epoch), "seq": JSONValue(handled + 1), "handled": JSONValue(handled),
        "keep": keep ?? ["capturing": false, "newTabShown": false, "pip": false, "displayRequest": false, "media": "none"],
        "reveal": ["fullscreen": false, "crashed": false, "unresponsive": false, "scrolledDown": false, "sharing": false]])
    }

    func runner(idleMs: Double = 0, protectedRecent: Int = 0, perSweep: Int = 6) -> TabSleepRunner {
      TabSleepRunner(store: store, pages: pages,
        policy: .init(idleMs: idleMs, protectedRecent: protectedRecent, perSweep: perSweep),
        clock: { [unowned self] in now }, initiallyActive: true,
        notificationCenter: notifications,
        schedule: { [unowned self] interval, tick in
          scheduledInterval = interval
          scheduledTick = tick
          return { [weak self] in self?.timerCancelled = true }
        }, observePressure: { _ in {} },
        pendingPermission: { [unowned self] in pendingPermission.contains($0) })
    }
  }

  @Test(arguments: [false, true])
  func runtimeHistoryProtectsReloadSurvivorsUntilANewSession(_ reload: Bool) async throws {
    let fixture = try Fixture(pinned: true, registerPages: false)
    let issuer = PageIssuer(store: fixture.store, registry: fixture.pages)
    let owner = NSObject()
    let context = PageHostContext(navigationSeq: 2, contextRevision: 1, wasNewTab: false, newTabShownUrl: nil)
    let perform: PageRegistry.Perform = { command, finish in
      fixture.commands["target0", default: []].append(command)
      finish(.success(command == .reasonsNotToSleep ? .array([.string("pinnedTab")]) : .string("discarded")))
    }
    let binding = try #require(issuer.attach(tabId: "target0", engine: .chromium, host: .pooled,
      owner: owner, context: context, perform: perform))
    let firstRuntime = UUID()
    issuer.beginRuntime(firstRuntime)
    issuer.beginRuntime(firstRuntime)
    issuer.noteDelivery(binding)
    #expect(issuer.report(binding, report: ["type": "ready", "browserId": 100]))
    let mediaEvent = try #require(issuer.reserveEvent(binding, name: "onNowPlaying", payload: ["playbackState": "paused"]))
    issuer.noteDelivery(binding)
    fixture.epoch = fixture.store.registerKeepAliveRuntime()
    try fixture.feed("target0", handled: mediaEvent, keep: ["capturing": false, "newTabShown": false,
      "pip": false, "displayRequest": false, "media": "present"], generation: binding.sessionGeneration)
    let runner = fixture.runner()
    #expect(runner.start())
    defer { runner.stop() }
    #expect(await runner.sweep().isEmpty)
    if reload {
      issuer.endRuntime(firstRuntime)
      let nextRuntime = UUID()
      issuer.beginRuntime(nextRuntime)
      issuer.endRuntime(firstRuntime)
      fixture.epoch = fixture.store.registerKeepAliveRuntime()
      issuer.noteDelivery(binding)
      let status = try #require(issuer.reserveEvent(binding, name: "onStatus", payload: ["status": "ready"]))
      issuer.noteDelivery(binding)
      try fixture.feed("target0", handled: status, generation: binding.sessionGeneration)
      #expect(await runner.sweep().isEmpty)
      runner.setMemoryPressure(.critical)
      #expect(await runner.sweep().isEmpty)
      #expect(fixture.commands.isEmpty)
      let replacementOwner = NSObject()
      let replacement = try #require(issuer.attach(tabId: "target0", engine: .chromium, host: .pooled,
        owner: replacementOwner, context: context, perform: perform))
      issuer.noteDelivery(replacement)
      #expect(issuer.report(replacement, report: ["type": "ready", "browserId": 101]))
      try fixture.feed("target0", generation: replacement.sessionGeneration)
      #expect(await runner.sweep() == ["target0"])
    } else {
      let status = try #require(issuer.reserveEvent(binding, name: "onStatus", payload: ["status": "ready"]))
      issuer.noteDelivery(binding)
      try fixture.feed("target0", handled: status, generation: binding.sessionGeneration)
      #expect(await runner.sweep() == ["target0"])
    }
  }

  @Test func pinnedOnlyWaivesPinnedInOneEngineCallAndLeavesLiveFactsToReports() async throws {
    let fixture = try Fixture(pinned: true)
    fixture.replies["target0"] = .success(.array([.string("pinnedTab")]))
    let runner = fixture.runner()
    #expect(runner.start())
    defer { runner.stop() }
    let before = fixture.store.state
    #expect(await runner.sweep() == ["target0"])
    #expect(fixture.commands["target0"] == [.reasonsNotToSleep, .sleepIfEligible(true)])
    #expect(runner.lastChromeReasons["target0"] == ["pinnedTab"])
    #expect(fixture.store.state == before)
  }

  @Test(arguments: [["pinnedTab", "audible"], ["optedOut"]])
  func chromeProtectionIsNeverOverridden(_ reasons: [String]) async throws {
    let fixture = try Fixture(pinned: true)
    fixture.replies["target0"] = .success(.array(reasons.map(PageValue.string)))
    let runner = fixture.runner()
    #expect(runner.start())
    defer { runner.stop() }
    #expect(await runner.sweep().isEmpty)
    #expect(fixture.commands["target0"] == [.reasonsNotToSleep])
    #expect(runner.lastChromeReasons["target0"] == reasons)
  }

  @Test(arguments: [false, true])
  func retainedWindowKeepsItsSelectionAndSplitWhileEligibleBackgroundPagesSleep(criticalPressure: Bool) async throws {
    let fixture = try Fixture(count: 3, backgroundSplit: true)
    try fixture.store.dispatch(Command("setWindowKeptOnClose", ["window", true]))
    let before = fixture.store.state
    let runner = fixture.runner()
    #expect(runner.start())
    defer { runner.stop() }
    if criticalPressure { runner.setMemoryPressure(.critical) }
    #expect(await runner.sweep() == ["target2"])
    #expect(!(await runner.sleepOnRequest("active")))
    #expect(!(await runner.sleepOnRequest("target0")))
    #expect(!(await runner.sleepOnRequest("target1")))
    #expect(fixture.commands["active"] == nil)
    #expect(fixture.commands["target0"] == nil)
    #expect(fixture.commands["target1"] == nil)
    #expect(fixture.commands["target2"] == [.reasonsNotToSleep, .sleepIfEligible(false)])
    #expect(fixture.store.state.windows["window"]?.keptOnClose == true)
    #expect(fixture.store.state.windows["window"]?.activeTabIds == before.windows["window"]?.activeTabIds)
    #expect(fixture.store.state.splits["background"] == before.splits["background"])
    #expect(fixture.store.state == before)
  }

  @Test func backgroundSplitNeverReachesChrome() async throws {
    let fixture = try Fixture(count: 2, backgroundSplit: true)
    let runner = fixture.runner()
    #expect(runner.start())
    defer { runner.stop() }
    #expect(await runner.sweep().isEmpty)
    #expect(fixture.commands.isEmpty)
  }

  @Test(arguments: [Result<PageValue, PageRegistryError>.success(.null), .failure(.failed("unavailable"))])
  func unavailableChromeReasonsProtectThePage(_ reply: Result<PageValue, PageRegistryError>) async throws {
    let fixture = try Fixture()
    fixture.replies["target0"] = reply
    let runner = fixture.runner()
    #expect(runner.start())
    defer { runner.stop() }
    #expect(await runner.sweep().isEmpty)
    #expect(fixture.commands["target0"] == [.reasonsNotToSleep])
  }

  @Test func capCountsSuccessfulDiscards() async throws {
    let fixture = try Fixture(count: 3)
    fixture.outcomes["target0"] = "refused"
    let runner = fixture.runner(perSweep: 1)
    #expect(runner.start())
    defer { runner.stop() }
    #expect(await runner.sweep() == ["target1"])
    #expect(fixture.commands["target0"] == [.reasonsNotToSleep, .sleepIfEligible(false)])
    #expect(fixture.commands["target1"] == [.reasonsNotToSleep, .sleepIfEligible(false)])
    #expect(fixture.commands["target2"] == nil)
  }

  @Test func criticalPressureIgnoresRecentProtection() async throws {
    let fixture = try Fixture()
    let runner = fixture.runner(idleMs: 1_000, protectedRecent: 10)
    #expect(runner.start())
    defer { runner.stop() }
    #expect(await runner.sweep().isEmpty)
    runner.setMemoryPressure(.critical)
    #expect(await runner.sweep() == ["target0"])
  }

  @Test func selectionChangingDuringReasonsProtectsThePage() async throws {
    let fixture = try Fixture()
    fixture.beforeReasons = { [unowned fixture] id in try! fixture.store.dispatch(Command("activate", [.string(id)])) }
    let runner = fixture.runner()
    #expect(runner.start())
    defer { runner.stop() }
    #expect(await runner.sweep().isEmpty)
    #expect(fixture.commands["target0"] == [.reasonsNotToSleep])
  }

  @Test func registrationChangingDuringReasonsProtectsReplacement() async throws {
    let fixture = try Fixture()
    fixture.beforeReasons = { [unowned fixture] id in
      fixture.beforeReasons = nil
      fixture.register(id)
    }
    let runner = fixture.runner()
    #expect(runner.start())
    defer { runner.stop() }
    #expect(await runner.sweep().isEmpty)
    #expect(fixture.commands["target0"] == [.reasonsNotToSleep])
  }

  @Test func stoppingDuringReasonsPreventsDiscard() async throws {
    let fixture = try Fixture()
    let runner = fixture.runner()
    fixture.beforeReasons = { [weak runner] _ in runner?.stop() }
    #expect(runner.start())
    defer { runner.stop() }
    #expect(await runner.sweep().isEmpty)
    #expect(fixture.commands["target0"] == [.reasonsNotToSleep])
  }

  @Test func stoppingInsideEngineCallCancelsAnUnfinishedRequest() async throws {
    let fixture = try Fixture()
    var cancelled = false
    let pages = PageRegistry(scheduleTimeout: { _, _ in { cancelled = true } })
    let runner = TabSleepRunner(store: fixture.store, pages: pages,
      policy: .init(idleMs: 0, protectedRecent: 0), initiallyActive: true,
      schedule: { _, _ in {} }, observePressure: { _ in {} }, pendingPermission: { _ in false })
    pages.register(tabID: "target0", engine: .chromium, host: .pooled, sessionGeneration: "G") { _, finish in
      runner.stop()
      Task { @MainActor in
        #expect(cancelled)
        finish(.success(.array([])))
      }
    }
    #expect(runner.start())
    defer { runner.stop() }
    #expect(await runner.sweep().isEmpty)
  }

  @Test func replacementSessionDuringReasonsProtectsThePage() async throws {
    let fixture = try Fixture()
    fixture.beforeReasons = { [unowned fixture] id in
      try! fixture.report(id, ["type": "created", "generation": "replacement", "engine": "chromium",
        "navigationSeq": 2, "contextRevision": 1, "wasNewTab": false, "newTabShownUrl": .null])
    }
    let runner = fixture.runner()
    #expect(runner.start())
    defer { runner.stop() }
    #expect(await runner.sweep().isEmpty)
    #expect(fixture.commands["target0"] == [.reasonsNotToSleep])
  }

  @Test(arguments: ["capturing", "newTabShown", "pip", "displayRequest", "media"])
  func keepAliveFeedProtectsNativeAndHostActivity(_ reason: String) async throws {
    let fixture = try Fixture(pinned: true)
    var keep: JSONObject = ["capturing": false, "newTabShown": false, "pip": false, "displayRequest": false, "media": "none"]
    keep[reason] = reason == "media" ? "present" : true
    try fixture.feed("target0", handled: 1, keep: .object(keep))
    let runner = fixture.runner()
    #expect(runner.start())
    defer { runner.stop() }
    #expect(await runner.sweep().isEmpty)
    #expect(fixture.commands.isEmpty)
  }

  @Test func missingAndStaleKeepAliveFactsProtectThePage() async throws {
    let fixture = try Fixture()
    let runner = fixture.runner()
    #expect(runner.start())
    defer { runner.stop() }
    try fixture.report("target0", ["type": "latch", "generation": "G", "eventSeq": 3])
    #expect(await runner.sweep().isEmpty)
    #expect(fixture.commands.isEmpty)
    try fixture.feed("target0", handled: 3)
    #expect(await runner.sweep() == ["target0"])
    fixture.commands.removeAll()
    _ = fixture.store.registerKeepAliveRuntime()
    #expect(await runner.sweep().isEmpty)
    #expect(fixture.commands.isEmpty)
  }

  @Test func pendingNativePermissionProtectsThePage() async throws {
    let fixture = try Fixture()
    fixture.pendingPermission.insert("target0")
    let runner = fixture.runner()
    #expect(runner.start())
    defer { runner.stop() }
    #expect(await runner.sweep().isEmpty)
    #expect(fixture.commands.isEmpty)
  }

  @Test func appClockStopsWhileInactiveAndTimerCancels() async throws {
    let fixture = try Fixture()
    let runner = fixture.runner(idleMs: 1_000)
    #expect(runner.start())
    defer { runner.stop() }
    #expect(fixture.scheduledInterval == 30_000)
    fixture.now = 400
    fixture.notifications.post(name: NSApplication.didResignActiveNotification, object: nil)
    fixture.now = 10_000
    #expect(runner.activeMilliseconds == 400)
    #expect(await runner.sweep().isEmpty)
    fixture.notifications.post(name: NSApplication.didBecomeActiveNotification, object: nil)
    fixture.now = 10_600
    #expect(runner.activeMilliseconds == 1_000)
    #expect(await runner.sweep() == ["target0"])
    runner.stop()
    #expect(fixture.timerCancelled)
  }

  @Test func delayedSelectionCommitsResetTheHiddenClock() async throws {
    let fixture = try Fixture()
    let runner = fixture.runner(idleMs: 1_000)
    #expect(runner.start())
    defer { runner.stop() }
    fixture.now = 900
    #expect(fixture.store.pauseDeliveryForTesting())
    try fixture.store.dispatch(Command("activate", ["target0"]))
    try fixture.store.dispatch(Command("activate", ["active"]))
    #expect(await runner.sweep().isEmpty)
    fixture.store.resumeDeliveryForTesting()
    await withCheckedContinuation { continuation in DispatchQueue.main.async { continuation.resume() } }
    fixture.now = 1_000
    #expect(await runner.sweep().isEmpty)
    fixture.now = 1_900
    #expect(await runner.sweep() == ["target0"])
  }

  @Test func undeliveredSelectionCommitsProtectThePagePastItsOldDeadline() async throws {
    let fixture = try Fixture()
    let runner = fixture.runner(idleMs: 1_000)
    #expect(runner.start())
    defer { runner.stop() }
    fixture.now = 900
    #expect(fixture.store.pauseDeliveryForTesting())
    try fixture.store.dispatch(Command("activate", ["target0"]))
    try fixture.store.dispatch(Command("activate", ["active"]))
    fixture.now = 1_500
    #expect(await runner.sweep().isEmpty)
    #expect(fixture.commands.isEmpty)
    fixture.store.resumeDeliveryForTesting()
    await withCheckedContinuation { continuation in DispatchQueue.main.async { continuation.resume() } }
    #expect(await runner.sweep().isEmpty)
  }

  @Test func restartClearsReasonsForRegistrationsReplacedWhileStopped() async throws {
    let fixture = try Fixture()
    fixture.replies["target0"] = .success(.array([.string("optedOut")]))
    let runner = fixture.runner()
    #expect(runner.start())
    defer { runner.stop() }
    #expect(await runner.sweep().isEmpty)
    #expect(runner.lastChromeReasons["target0"] == ["optedOut"])
    runner.stop()
    fixture.register("target0")
    #expect(runner.start())
    #expect(runner.lastChromeReasons["target0"] == nil)
  }

  @Test func restartingResetsPressureUntilTheNewObserverReports() throws {
    let fixture = try Fixture()
    let runner = fixture.runner()
    #expect(runner.start())
    defer { runner.stop() }
    runner.setMemoryPressure(.critical)
    runner.stop()
    #expect(runner.start())
    #expect(runner.memoryPressure == .normal)
  }

  @Test func onlyOneRunnerCanStartAtATime() throws {
    let fixture = try Fixture()
    let first = fixture.runner()
    let second = fixture.runner()
    #expect(first.start())
    defer { first.stop(); second.stop() }
    #expect(!second.start())
    #expect(TabSleepRunner.hasActiveRunner)
    first.stop()
    #expect(second.start())
  }

  @Test func sleepOnRequestSleepsAPlainBackgroundTabWithoutWaitingForTheIdleTimer() async throws {
    let fixture = try Fixture()
    let runner = fixture.runner(idleMs: 36_000_000)
    #expect(runner.start())
    defer { runner.stop() }
    #expect(await runner.sweep().isEmpty)
    #expect(fixture.commands.isEmpty)
    #expect(await runner.sleepOnRequest("target0"))
    #expect(fixture.commands["target0"] == [.reasonsNotToSleep, .sleepIfEligible(false)])
  }

  @Test func sleepOnRequestRefusesAProtectedTabWithoutAskingChrome() async throws {
    let fixture = try Fixture()
    try fixture.feed("target0", handled: 1, keep: ["capturing": true, "newTabShown": false, "pip": false, "displayRequest": false, "media": "none"])
    let runner = fixture.runner()
    #expect(runner.start())
    defer { runner.stop() }
    #expect(!(await runner.sleepOnRequest("target0")))
    #expect(!(await runner.sleepOnRequest("active")))
    #expect(fixture.commands.isEmpty)
  }

  @Test func sleepOnRequestRefusesATabAskingForPermission() async throws {
    let fixture = try Fixture()
    fixture.pendingPermission = ["target0"]
    let runner = fixture.runner()
    #expect(runner.start())
    defer { runner.stop() }
    #expect(!(await runner.sleepOnRequest("target0")))
    #expect(fixture.commands.isEmpty)
  }

  @Test(arguments: [["siteException"], ["audible"], ["pinnedTab", "audible"]])
  func sleepOnRequestHonoursChromesReasonsIncludingSiteExceptions(_ reasons: [String]) async throws {
    let fixture = try Fixture()
    fixture.replies["target0"] = .success(.array(reasons.map(PageValue.string)))
    let runner = fixture.runner()
    #expect(runner.start())
    defer { runner.stop() }
    #expect(!(await runner.sleepOnRequest("target0")))
    #expect(fixture.commands["target0"] == [.reasonsNotToSleep])
    #expect(runner.lastChromeReasons["target0"] == reasons)
  }

  @Test func sleepOnRequestDoesNothingWhileTheRunnerIsStopped() async throws {
    let fixture = try Fixture()
    let runner = fixture.runner()
    #expect(!(await runner.sleepOnRequest("target0")))
    #expect(fixture.commands.isEmpty)
  }
}
