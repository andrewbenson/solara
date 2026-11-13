import AppKit
import Dispatch
import SolaraModel
import SolaraStore

@MainActor
public final class TabSleepRunner {
  public typealias Clock = @MainActor () -> Double
  public typealias Schedule = @MainActor (Double, @escaping @MainActor () -> Void) -> (@MainActor () -> Void)
  public typealias ObservePressure = @MainActor (@escaping @MainActor (TabSleepPolicy.Pressure) -> Void) -> (@MainActor () -> Void)

  private static weak var activeRunner: TabSleepRunner?
  public static var hasActiveRunner: Bool { activeRunner?.isRunning == true }
  public private(set) var isRunning = false
  public private(set) var lastChromeReasons: [String: [String]] = [:]
  public private(set) var memoryPressure: TabSleepPolicy.Pressure = .normal

  private let store: Store
  private let pages: PageRegistry
  private let sleep: TabSleep
  public var policy: TabSleepPolicy.Configuration
  private let profileIdleMs: Double
  private let clock: Clock
  private let initiallyActive: Bool?
  private let notificationCenter: NotificationCenter
  private let schedule: Schedule
  private let observePressure: ObservePressure
  private let pendingPermission: @MainActor (String) -> Bool
  private var appActive = false
  private var activeSince: Double = 0
  private var activeTotal: Double = 0
  private var hiddenAt: [String: Double] = [:]
  private var unusedSince: [String: Double] = [:]
  private var lastShown: Set<String> = []
  private var trackedRevision = -1
  private var observedRevision = -1
  private var storeObserver: Int?
  private var pageObserver: UUID?
  private var appObservers: [NSObjectProtocol] = []
  private var cancelTick: (@MainActor () -> Void)?
  private var cancelPressure: (@MainActor () -> Void)?
  private var tickTask: Task<Void, Never>?
  private var pendingCalls: Set<UUID> = []
  private var runID = UUID()
  private var sweepID: UUID?

  @MainActor
  private final class CallTicket {
    var id: UUID?
    var completed = false
  }

  public init(
    store: Store,
    pages: PageRegistry = .shared,
    policy: TabSleepPolicy.Configuration = .init(),
    profileIdleMs: Double = 600_000,
    clock: @escaping Clock = { ProcessInfo.processInfo.systemUptime * 1_000 },
    initiallyActive: Bool? = nil,
    notificationCenter: NotificationCenter = .default,
    schedule: @escaping Schedule = TabSleepRunner.scheduleTicks,
    observePressure: @escaping ObservePressure = TabSleepRunner.observeSystemPressure,
    pendingPermission: @escaping @MainActor (String) -> Bool = { _ in true }
  ) {
    self.store = store
    self.pages = pages
    sleep = TabSleep(store: store)
    self.policy = policy
    self.profileIdleMs = profileIdleMs
    self.clock = clock
    self.initiallyActive = initiallyActive
    self.notificationCenter = notificationCenter
    self.schedule = schedule
    self.observePressure = observePressure
    self.pendingPermission = pendingPermission
  }

  isolated deinit { stop() }

  public var activeMilliseconds: Double {
    activeTotal + (appActive ? max(0, clock() - activeSince) : 0)
  }

  @discardableResult
  public func start() -> Bool {
    if isRunning { return true }
    guard Self.activeRunner == nil else { return false }
    Self.activeRunner = self
    isRunning = true
    runID = UUID()
    activeTotal = 0
    activeSince = clock()
    appActive = initiallyActive ?? NSApplication.shared.isActive
    memoryPressure = .normal
    lastChromeReasons.removeAll()
    hiddenAt.removeAll()
    unusedSince.removeAll()
    lastShown.removeAll()
    trackedRevision = -1
    let run = runID
    storeObserver = store.subscribe { [weak self] commit in
      DispatchQueue.main.async {
        MainActor.assumeIsolated {
          guard let self, self.isCurrent(run) else { return }
          self.track(commit.state, revision: commit.rev)
          self.observedRevision = max(self.observedRevision, commit.rev)
        }
      }
    }
    trackCurrent()
    observedRevision = trackedRevision
    pageObserver = pages.observe { [weak self] event in
      guard let self, isRunning else { return }
      switch event {
      case .registered(let descriptor): lastChromeReasons.removeValue(forKey: descriptor.tabID)
      case .retired(let registration): lastChromeReasons.removeValue(forKey: registration.tabID)
      }
      trackCurrent()
    }
    for (name, active) in [(NSApplication.didBecomeActiveNotification, true), (NSApplication.didResignActiveNotification, false)] {
      appObservers.append(notificationCenter.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
        MainActor.assumeIsolated { self?.setAppActive(active) }
      })
    }
    cancelTick = schedule(30_000) { [weak self] in self?.scheduleSweep() }
    cancelPressure = observePressure { [weak self] pressure in
      guard let self, isRunning else { return }
      let rose = pressure != .normal && pressure != memoryPressure
      setMemoryPressure(pressure)
      if rose { scheduleSweep() }
    }
    return true
  }

  public func stop() {
    guard isRunning else { return }
    isRunning = false
    runID = UUID()
    sweepID = nil
    cancelTick?()
    cancelTick = nil
    cancelPressure?()
    cancelPressure = nil
    tickTask?.cancel()
    tickTask = nil
    if let storeObserver { store.unsubscribe(storeObserver) }
    storeObserver = nil
    if let pageObserver { pages.removeObserver(pageObserver) }
    pageObserver = nil
    for observer in appObservers { notificationCenter.removeObserver(observer) }
    appObservers.removeAll()
    let calls = pendingCalls
    pendingCalls.removeAll()
    for id in calls { pages.cancel(id) }
    if Self.activeRunner === self { Self.activeRunner = nil }
  }

  public func setMemoryPressure(_ pressure: TabSleepPolicy.Pressure) {
    memoryPressure = pressure
  }

  public func sweep() async -> [String] {
    guard isRunning, Self.activeRunner === self, sweepID == nil else { return [] }
    let sweep = UUID()
    sweepID = sweep
    let run = runID
    defer { if sweepID == sweep { sweepID = nil } }
    let candidates = store.sequence { candidateIDs() }
    var slept: [String] = []
    for id in candidates {
      guard isCurrent(run), !Task.isCancelled, slept.count < policy.perSweep else { break }
      guard let descriptor = store.sequence({ eligibleDescriptor(id) }) else { continue }
      do {
        guard let reasons = try await request(descriptor, .reasonsNotToSleep, run: run) else {
          if isCurrent(run) { lastChromeReasons.removeValue(forKey: id) }
          continue
        }
        guard isCurrent(run), pages.descriptor(descriptor.registration) == descriptor else { continue }
        lastChromeReasons[id] = reasons
        guard reasons.allSatisfy({ $0 == "pinnedTab" }) else { continue }
        let command: PageRequest<PageDiscardOutcome> = .sleepIfEligible(waivingPinned: reasons.contains("pinnedTab"))
        let outcome = try await request(descriptor, command, run: run)
        if outcome == .discarded { slept.append(id) }
      } catch {
        continue
      }
    }
    return slept
  }

  public func sleepOnRequest(_ id: String) async -> Bool {
    guard isRunning, Self.activeRunner === self else { return false }
    let run = runID
    guard let descriptor = store.sequence({ requestable(id) ? eligibleDescriptor(id) : nil }) else { return false }
    do {
      guard let reasons = try await request(descriptor, .reasonsNotToSleep, run: run, candidate: false), isCurrent(run) else { return false }
      lastChromeReasons[id] = reasons
      guard reasons.allSatisfy({ $0 == "pinnedTab" }) else { return false }
      let command: PageRequest<PageDiscardOutcome> = .sleepIfEligible(waivingPinned: reasons.contains("pinnedTab"))
      let outcome = try await request(descriptor, command, run: run, candidate: false)
      return outcome == .discarded
    } catch {
      return false
    }
  }

  private func requestable(_ id: String) -> Bool {
    let state = store.state
    return state.tabs[id] != nil && !shownIDs(state).contains(id) && state.live[id]?.discarded != true
  }

  private func request<Output>(_ descriptor: PageDescriptor, _ request: PageRequest<Output>, run: UUID, candidate: Bool = true) async throws -> Output {
    let value: PageValue = try await withCheckedThrowingContinuation { continuation in
      store.sequence {
        guard isCurrent(run), !Task.isCancelled,
          pages.descriptor(descriptor.registration) == descriptor,
          eligibleDescriptor(descriptor.tabID)?.registration == descriptor.registration,
          candidate ? candidateIDs().contains(descriptor.tabID) : requestable(descriptor.tabID) else {
          continuation.resume(throwing: PageRegistryError.cancelled(descriptor.registration))
          return
        }
        let ticket = CallTicket()
        ticket.id = pages.call(descriptor.registration, command: request.command) { [weak self] result in
          ticket.completed = true
          if let id = ticket.id { self?.pendingCalls.remove(id) }
          continuation.resume(with: result)
        }
        if !ticket.completed, let id = ticket.id {
          if isCurrent(run), !Task.isCancelled { pendingCalls.insert(id) }
          else { pages.cancel(id) }
        }
      }
    }
    return try request.decode(value)
  }

  private func isCurrent(_ run: UUID) -> Bool {
    isRunning && Self.activeRunner === self && runID == run
  }

  private func scheduleSweep() {
    guard isRunning, sweepID == nil else { return }
    tickTask = Task { @MainActor [weak self] in _ = await self?.sweep() }
  }

  private func setAppActive(_ active: Bool) {
    guard isRunning, appActive != active else { return }
    if appActive { activeTotal += max(0, clock() - activeSince) }
    else { activeSince = clock() }
    appActive = active
  }

  private func trackCurrent() {
    store.sequence { track(store.state, revision: store.rev) }
  }

  private func track(_ state: BrowserState, revision: Int) {
    guard isRunning else { return }
    let shown = shownIDs(state)
    let now = activeMilliseconds
    guard revision >= trackedRevision else {
      for id in shown where hiddenAt[id] != nil && !lastShown.contains(id) { hiddenAt[id] = now }
      return
    }
    trackedRevision = revision
    for id in lastShown where !shown.contains(id) { hiddenAt[id] = now }
    for id in shown { hiddenAt.removeValue(forKey: id) }
    for descriptor in pages.descriptors where !shown.contains(descriptor.tabID) && hiddenAt[descriptor.tabID] == nil {
      hiddenAt[descriptor.tabID] = now
    }
    hiddenAt = hiddenAt.filter { state.tabs[$0.key] != nil }
    lastChromeReasons = lastChromeReasons.filter { state.tabs[$0.key] != nil }
    lastShown = shown
  }

  private func shownIDs(_ state: BrowserState) -> Set<String> {
    var shown: Set<String> = []
    for window in state.windows.values {
      guard let active = state.activeTabId(window.id) else { continue }
      shown.insert(active)
      if let peek = state.peeks[window.id]?.tabId { shown.insert(peek) }
      if let held = state.tabs[active]?.pageIn, !held.isEmpty { shown.insert(held) }
      shown.formUnion(Splits.splitOf(state, active)?.tabIds ?? [])
    }
    return shown
  }

  private func candidateIDs() -> [String] {
    let cursor = store.deliveryCursor()
    guard cursor.committed == cursor.delivered, observedRevision >= cursor.committed else { return [] }
    let state = store.state
    track(state, revision: store.rev)
    let now = activeMilliseconds
    let unused = TabSleepPolicy.unusedProfiles(profileIds: state.profiles.keys,
      shownProfileIds: Set(state.windows.values.map(\.profileId)), unusedSince: unusedSince, now: now, idleMs: profileIdleMs)
    unusedSince = unused.unusedSince
    let descriptors = pages.descriptors
    var keepAlive: [String: String] = [:]
    for descriptor in descriptors {
      if let reason = keepAliveReason(descriptor, state: state) { keepAlive[descriptor.tabID] = reason }
    }
    return TabSleepPolicy.candidates(
      tabs: state.tabs.values.map { .init(id: $0.id, url: $0.url, profileId: $0.profileId, lastActiveAt: $0.lastActiveAt) },
      shownIds: shownIDs(state), discardedIds: Set(state.live.compactMap { $0.value.discarded ? $0.key : nil }),
      loadedIds: descriptors.map(\.tabID), hiddenAt: hiddenAt, now: now, pressure: memoryPressure,
      unusedProfileIds: Set(unused.eligibleIds), policy: policy, keepAliveReasons: keepAlive)
  }

  private func eligibleDescriptor(_ id: String) -> PageDescriptor? {
    guard let descriptor = pages.descriptors.first(where: { $0.tabID == id }),
      keepAliveReason(descriptor, state: store.state) == nil else { return nil }
    return descriptor
  }

  private func keepAliveReason(_ descriptor: PageDescriptor, state: BrowserState) -> String? {
    let id = descriptor.tabID
    guard descriptor.protectionKnown else { return "awaiting runtime page facts" }
    if let reason = sleep.solaraReasonNotToSleep(id) { return reason }
    if Splits.splitOf(state, id) != nil { return "in a split" }
    guard descriptor.engine == .chromium, let tab = state.tabs[id], let live = state.live[id] else { return "no page" }
    if live.discarded { return "discarded" }
    if live.playingAudio { return "playing audio" }
    if live.isLoading { return "loading" }
    if pendingPermission(id) { return "asking for permission" }
    guard let facts = store.pageFacts(id), facts.generation == descriptor.sessionGeneration,
      facts.ready != nil, let feed = facts.keepAlive,
      feed.handled >= max(facts.latchedThrough, facts.newestEventSeq) else { return "awaiting page facts" }
    if feed.keep.capturing { return "capturing" }
    if feed.keep.newTabShown { return "kept for Forward" }
    if feed.keep.pip { return "picture in picture" }
    if feed.keep.displayRequest { return "choosing a screen to share" }
    if feed.keep.media == .playing || (tab.pinned && feed.keep.media == .present) { return "media" }
    return nil
  }

  public static func scheduleTicks(_ intervalMs: Double, _ tick: @escaping @MainActor () -> Void) -> @MainActor () -> Void {
    let interval = intervalMs / 1_000
    let now = Date().timeIntervalSinceReferenceDate
    let firstOnSharedGrid = Date(timeIntervalSinceReferenceDate: (floor(now / interval) + 1) * interval)
    let timer = Timer(fire: firstOnSharedGrid, interval: interval, repeats: true) { _ in MainActor.assumeIsolated { tick() } }
    timer.tolerance = interval / 10
    RunLoop.main.add(timer, forMode: .common)
    return { timer.invalidate() }
  }

  public static func observeSystemPressure(_ receive: @escaping @MainActor (TabSleepPolicy.Pressure) -> Void) -> @MainActor () -> Void {
    let source = DispatchSource.makeMemoryPressureSource(eventMask: [.normal, .warning, .critical], queue: .main)
    source.setEventHandler {
      MainActor.assumeIsolated {
        let flags = source.data
        receive(flags.contains(.critical) ? .critical : flags.contains(.warning) ? .warning : .normal)
      }
    }
    source.resume()
    return {
      source.setEventHandler(handler: nil)
      source.cancel()
    }
  }
}
