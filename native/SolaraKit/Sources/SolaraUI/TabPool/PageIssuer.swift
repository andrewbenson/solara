import Foundation
import SolaraModel
import SolaraStore
import Synchronization

public struct PageIdentity: Sendable, Hashable {
  public let tabId: String
  public let registrationGeneration: PageRegistrationGeneration
  public let sessionGeneration: String

  public init(tabId: String, registrationGeneration: PageRegistrationGeneration, sessionGeneration: String) {
    self.tabId = tabId
    self.registrationGeneration = registrationGeneration
    self.sessionGeneration = sessionGeneration
  }
}

public struct PageHostContext: Sendable, Equatable {
  public var navigationSeq: Int?
  public var contextRevision: Int
  public var wasNewTab: Bool
  public var newTabShownUrl: String?

  public init(navigationSeq: Int?, contextRevision: Int, wasNewTab: Bool, newTabShownUrl: String?) {
    self.navigationSeq = navigationSeq
    self.contextRevision = contextRevision
    self.wasNewTab = wasNewTab
    self.newTabShownUrl = newTabShownUrl
  }

  public init?(json: JSONValue) {
    guard let sequence = json["navigationSeq"], sequence.isNull || Self.safeInteger(sequence) != nil,
      let revision = Self.safeInteger(json["contextRevision"]), let wasNewTab = json["wasNewTab"]?.bool,
      let shown = json["newTabShownUrl"], shown.isNull || shown.string != nil else { return nil }
    self.init(navigationSeq: Self.safeInteger(sequence), contextRevision: revision,
      wasNewTab: wasNewTab, newTabShownUrl: shown.string)
  }

  public static func initial(navigationSeq: Int?, wasNewTab: Bool, cached: JSONValue?) -> PageHostContext {
    if let cached, let context = PageHostContext(json: cached), context.navigationSeq == navigationSeq { return context }
    return PageHostContext(navigationSeq: navigationSeq, contextRevision: 0, wasNewTab: wasNewTab, newTabShownUrl: nil)
  }

  private static func safeInteger(_ value: JSONValue?) -> Int? {
    guard let number = value?.number, number.isFinite, number.rounded() == number,
      number >= 0, number <= 9_007_199_254_740_991 else { return nil }
    return Int(exactly: number)
  }

  public var json: JSONObject {
    ["navigationSeq": navigationSeq.map { JSONValue($0) } ?? .null,
      "contextRevision": JSONValue(contextRevision), "wasNewTab": .bool(wasNewTab),
      "newTabShownUrl": newTabShownUrl.map(JSONValue.string) ?? .null]
  }
}

@MainActor
public final class PageHostBinding {
  public let tabId: String
  public let engine: PageEngine
  public let host: PageHost
  public let profile: String
  public let runtimeID: UUID?
  public let nativeTag: Int?
  public let sessionGeneration: String
  public weak var owner: AnyObject?
  public private(set) var registration: PageRegistration?
  public fileprivate(set) var context: PageHostContext
  public fileprivate(set) var executedNavigationSeq: Int?
  public fileprivate(set) var retired = false
  public fileprivate(set) var eventSeq = 0
  public fileprivate(set) var documentRevision = 0
  fileprivate var firstDeliveryRuntimeID: UUID?
  fileprivate var protectionHistoryLost = false
  public fileprivate(set) var navigation: JSONValue?
  public fileprivate(set) var establishmentSerial = 0
  fileprivate var windowId: String?
  fileprivate var movedNavigationSeq: Int?
  fileprivate var sameProfileMove = false
  fileprivate var associatedNativePage = false
  fileprivate var reportedMedia: Set<NowPlayingStore.Field> = []
  fileprivate let perform: PageRegistry.Perform
  fileprivate let onCreated: @MainActor (PageHostBinding, Bool) -> Void
  fileprivate let onClearNewTabShown: @MainActor (PageHostBinding, PageIssueGuard) -> Void
  fileprivate let onNeedsFollow: @MainActor (PageHostBinding) -> Void

  public var registrationGeneration: PageRegistrationGeneration { registration!.registrationGeneration }
  fileprivate func movedTo(_ navigationSeq: Int?) -> Bool {
    sameProfileMove || (movedNavigationSeq != nil && movedNavigationSeq == navigationSeq)
  }
  public var identity: PageIdentity {
    PageIdentity(tabId: tabId, registrationGeneration: registrationGeneration, sessionGeneration: sessionGeneration)
  }

  fileprivate init(tabId: String, engine: PageEngine, host: PageHost, profile: String, owner: AnyObject,
    runtimeID: UUID?, nativeTag: Int?, context: PageHostContext, executedNavigationSeq: Int?, perform: @escaping PageRegistry.Perform,
    onCreated: @escaping @MainActor (PageHostBinding, Bool) -> Void,
    onClearNewTabShown: @escaping @MainActor (PageHostBinding, PageIssueGuard) -> Void,
    onNeedsFollow: @escaping @MainActor (PageHostBinding) -> Void) {
    self.tabId = tabId
    self.engine = engine
    self.host = host
    self.profile = profile
    self.owner = owner
    self.runtimeID = runtimeID
    self.nativeTag = nativeTag
    self.context = context
    self.executedNavigationSeq = executedNavigationSeq
    self.perform = perform
    self.onCreated = onCreated
    self.onClearNewTabShown = onClearNewTabShown
    self.onNeedsFollow = onNeedsFollow
    sessionGeneration = UUID().uuidString
  }

  fileprivate func setRegistration(_ registration: PageRegistration) { self.registration = registration }
}

@MainActor
public final class PageIssuer {
  public static var shared: PageIssuer?
  public static var consumeLittleWindowEvent: (@MainActor (PageIssuer, PageHostBinding, String) -> Bool)?
  public static var consumePageOpen: (@MainActor (PageIssuer, PageHostBinding, JSONObject) -> Void)?
  public static var consumePeekEscape: (@MainActor (PageIssuer, PageHostBinding) -> Bool)?
  public static var consumeLifecycleEvent: (@MainActor (PageIssuer, PageHostBinding, String, JSONValue) -> Bool)?
  public static var consumePromptEvent: (@MainActor (PageIssuer, PageHostBinding, String, JSONValue) -> Bool)?
  public static var lifecycleEvent: (@MainActor (PageIssuer, PageHostBinding, String, JSONValue) -> Void)?
  public static var lifecycleObservers: [@MainActor (PageIssuer, PageHostBinding, String, JSONValue) -> Void] = []
  private struct RuntimeOwner {
    weak var owner: AnyObject?
    let id: UUID
  }
  private static var runtimeOwners: [ObjectIdentifier: RuntimeOwner] = [:]

  public static func runtimeID(for owner: AnyObject) -> UUID {
    runtimeOwners = runtimeOwners.filter { $0.value.owner != nil }
    let key = ObjectIdentifier(owner)
    if let runtime = runtimeOwners[key], runtime.owner === owner { return runtime.id }
    let id = UUID()
    runtimeOwners[key] = RuntimeOwner(owner: owner, id: id)
    return id
  }

  public var onBrowserReady: ((PageHostBinding, Int) -> Void)?
  public let store: Store
  public let registry: PageRegistry
  public private(set) var deliveryConfigured: Bool
  private struct NativeExecution {
    weak var page: AnyObject?
    let binding: PageHostBinding
    var media: NowPlayingStore.Snapshot? = nil
  }

  private var nativeExecutions: [ObjectIdentifier: NativeExecution] = [:]
  var retainedNativeExecutions: Int { nativeExecutions.count }
  private let deliver: PageRegistry.Deliver
  private var bindings: [String: PageHostBinding] = [:]
  private struct RNFollowRequest: Equatable {
    let windowId: String
    let navigation: Navigation?
  }

  private var rnFollowRequests: [PageIdentity: RNFollowRequest] = [:]
  private var rnFollowSubscription: Int?
  private var scheduledRNFollows: Set<PageIdentity> = []
  private var protectionRuntimeID: UUID?
  private var hasBegunRuntime = false
  private var mediaEnded = false
  private nonisolated let cleanProtection = Mutex<[String: String]>([:])
  private var registrations: [PageRegistration: PageHostBinding] = [:]

  public init(store: Store, registry: PageRegistry = .shared, deliver: PageRegistry.Deliver? = nil) {
    self.store = store
    self.registry = registry
    self.deliver = deliver ?? { work in
      store.afterSequence {
        if Thread.isMainThread { MainActor.assumeIsolated { work() } }
        else { DispatchQueue.main.async { work() } }
      }
    }
    deliveryConfigured = registry.configureDelivery(self.deliver)
    #if DEBUG
      precondition(deliveryConfigured, "PageRegistry delivery must be configured before registration")
    #endif
    if !deliveryConfigured { NSLog("[store] PageRegistry delivery configuration failed; page registration refused") }
    let snapshotConfigured = registry.configureSnapshot { [weak self] capture in
      guard let self else { return [] }
      return self.store.sequence {
        for binding in self.bindings.values { _ = self.ensurePageEstablished(binding) }
        return capture().compactMap { descriptor in
          guard let binding = self.registrations[descriptor.registration] else { return descriptor.sessionGeneration == nil ? descriptor : nil }
          guard self.currentInScope(binding, requirePage: true),
            let snapshot = try? self.store.pageHostSnapshotInScope(binding.tabId, generation: binding.sessionGeneration) else { return nil }
          var copy = descriptor
          copy.protectionKnown = self.protectionKnown(binding)
          copy.ready = snapshot.facts?.ready
          copy.navigation = binding.navigation
          return copy
        }
      }
    }
    #if DEBUG
      precondition(snapshotConfigured, "PageRegistry snapshots must be configured before registration")
    #endif
    if !snapshotConfigured { NSLog("[store] PageRegistry snapshot configuration failed") }
    let callConfigured = registry.configureCallScope { action in store.sequence(action) }
    #if DEBUG
      precondition(callConfigured, "PageRegistry call scope must be configured before registration")
    #endif
    deliveryConfigured = deliveryConfigured && snapshotConfigured && callConfigured
    if !callConfigured { NSLog("[store] PageRegistry call configuration failed; page registration refused") }

  }

  deinit {
    if let rnFollowSubscription { store.unsubscribe(rnFollowSubscription) }
  }

  public func startFollowingRNPage(_ binding: PageHostBinding) {
    guard binding.host == .reactNative, rnFollowRequests[binding.identity] == nil,
      isCurrent(binding), let tab = store.state.tabs[binding.tabId] else { return }
    rnFollowRequests[binding.identity] = RNFollowRequest(windowId: tab.windowId, navigation: tab.navigation)
    if rnFollowSubscription == nil {
      rnFollowSubscription = store.subscribe { [weak self] commit in
        let ids = commit.changes.tabs.upserted
        guard !ids.isEmpty else { return }
        DispatchQueue.main.async { [weak self] in self?.followChangedRNPages(ids) }
      }
    }
    scheduleRNFollow(binding)
  }

  private func followChangedRNPages(_ ids: [String]) {
    let state = store.state
    for id in ids {
      guard let binding = bindings[id], let previous = rnFollowRequests[binding.identity],
        let tab = state.tabs[id] else { continue }
      let request = RNFollowRequest(windowId: tab.windowId, navigation: tab.navigation)
      guard request != previous else { continue }
      rnFollowRequests[binding.identity] = request
      scheduleRNFollow(binding)
    }
  }

  private func scheduleRNFollow(_ binding: PageHostBinding) {
    let identity = binding.identity
    guard scheduledRNFollows.insert(identity).inserted else { return }
    DispatchQueue.main.async { [weak self, weak binding] in
      guard let self else { return }
      self.scheduledRNFollows.remove(identity)
      guard let binding, self.rnFollowRequests[identity] != nil else { return }
      _ = self.follow(binding)
    }
  }

  public func beginRuntime(_ id: UUID) {
    store.sequence {
      guard protectionRuntimeID != id else { return }
      if let old = protectionRuntimeID { endRuntime(old) }
      protectionRuntimeID = id
      hasBegunRuntime = true
      publishProtectionInScope()
    }
  }

  public func endRuntime(_ id: UUID) {
    store.sequence {
      guard protectionRuntimeID == id else { return }
      for binding in bindings.values { binding.protectionHistoryLost = true }
      protectionRuntimeID = nil
      publishProtectionInScope()
    }
  }

  public func noteDelivery(_ binding: PageHostBinding) {
    store.sequence {
      guard let runtime = protectionRuntimeID else { return }
      noteDelivery(binding, runtimeID: runtime)
    }
  }

  public func noteDelivery(_ binding: PageHostBinding, runtimeID: UUID?, eventName: String? = nil) {
    store.sequence {
      guard currentInScope(binding, requirePage: true), !binding.protectionHistoryLost else { return }
      if runtimeID == nil, let eventName,
        !["onNowPlaying", "onPictureInPicture", "onDisplayMediaRequest", "onMediaAccess", "onFullscreen",
          "onCrashed", "onUnresponsive", "onResponsive", "onPageMessage", "onPageIssue"].contains(eventName) { return }
      guard let runtimeID, binding.host != .reactNative || binding.runtimeID == runtimeID else {
        binding.protectionHistoryLost = true
        publishProtectionInScope(binding)
        return
      }
      if binding.firstDeliveryRuntimeID == nil { binding.firstDeliveryRuntimeID = runtimeID }
      if let current = protectionRuntimeID, current != runtimeID { binding.protectionHistoryLost = true }
      publishProtectionInScope(binding)
    }
  }

  public nonisolated func protectionHistoryKnown(tabId: String, sessionGeneration: String) -> Bool {
    cleanProtection.withLock { $0[tabId] == sessionGeneration }
  }

  private func protectionHistoryClean(_ binding: PageHostBinding) -> Bool {
    !binding.retired && bindings[binding.tabId] === binding && !binding.protectionHistoryLost &&
      protectionRuntimeID != nil && binding.firstDeliveryRuntimeID == protectionRuntimeID
  }

  private func publishProtectionInScope(_ binding: PageHostBinding) {
    let clean = protectionHistoryClean(binding)
    cleanProtection.withLock { table in
      if clean { table[binding.tabId] = binding.sessionGeneration }
      else if table[binding.tabId] == binding.sessionGeneration { table[binding.tabId] = nil }
    }
  }

  private func publishProtectionInScope() {
    let table = Dictionary(uniqueKeysWithValues: bindings.values.filter(protectionHistoryClean).map { ($0.tabId, $0.sessionGeneration) })
    cleanProtection.withLock { $0 = table }
  }

  public func protectionKnown(_ binding: PageHostBinding) -> Bool {
    store.sequence {
      currentInScope(binding, requirePage: true) && !binding.protectionHistoryLost &&
        protectionRuntimeID != nil && binding.firstDeliveryRuntimeID == protectionRuntimeID
    }
  }

  public func afterSequence(_ work: @escaping @MainActor () -> Void) { deliver(work) }

  public func afterIngress(_ work: @escaping @MainActor () -> Void) { afterSequence(work) }

  public func binding(tabId: String) -> PageHostBinding? {
    store.sequence { bindings[tabId] }
  }

  public func binding(identity: PageIdentity) -> PageHostBinding? {
    store.sequence { exactBinding(identity) }
  }

  public func attach(tabId: String, engine: PageEngine, host: PageHost, owner: AnyObject, runtimeID: UUID? = nil, nativeTag: Int? = nil,
    context: PageHostContext, executedNavigationSeq: Int? = nil,
    onCreated: @escaping @MainActor (PageHostBinding, Bool) -> Void = { _, _ in },
    onClearNewTabShown: @escaping @MainActor (PageHostBinding, PageIssueGuard) -> Void = { _, _ in },
    onNeedsFollow: @escaping @MainActor (PageHostBinding) -> Void = { _ in },
    perform: @escaping PageRegistry.Perform) -> PageHostBinding? {
    store.sequence {
      guard deliveryConfigured else { return nil }
      let state = store.state
      guard let tab = state.tabs[tabId], eligible(tab, state: state, engine: engine),
        context.navigationSeq == tab.navigation.flatMap({ Int(exactly: $0.seq) }) else { return nil }
      if let old = bindings[tabId], old.owner === owner, old.host == host, old.runtimeID == runtimeID,
        old.engine == engine, old.profile == state.engineProfile(tab.profileId), !old.retired {
        return ensurePageEstablished(old) ? old : nil
      }
      if let old = bindings[tabId] { retireInScope(old) }
      let binding = PageHostBinding(tabId: tabId, engine: engine, host: host, profile: state.engineProfile(tab.profileId),
        owner: owner, runtimeID: runtimeID, nativeTag: nativeTag, context: context, executedNavigationSeq: executedNavigationSeq,
        perform: perform, onCreated: onCreated, onClearNewTabShown: onClearNewTabShown, onNeedsFollow: onNeedsFollow)
      let registration = registry.register(tabID: tabId, engine: engine, host: host, nativeTag: nativeTag, sessionGeneration: binding.sessionGeneration) { [weak self, weak binding] command, finish in
        guard let self, let binding else { finish(.failure(.noPage(tabId))); return }
        _ = self.ensurePageEstablished(binding)
        self.issueInScope(tabId: tabId, identity: binding.identity, command: command, completion: finish)
      }
      binding.protectionHistoryLost = hasBegunRuntime && protectionRuntimeID == nil
      binding.setRegistration(registration)
      bindings[tabId] = binding
      registrations[registration] = binding
      publishProtectionInScope(binding)
      guard establishInScope(binding, reestablished: false) else {
        retireInScope(binding)
        return nil
      }
      return binding
    }
  }

  public func retire(_ binding: PageHostBinding) { store.sequence { retireInScope(binding) } }

  private func retireInScope(_ binding: PageHostBinding) {
    guard !binding.retired else { return }
    binding.retired = true
    if rnFollowRequests.removeValue(forKey: binding.identity) != nil, rnFollowRequests.isEmpty,
      let subscription = rnFollowSubscription {
      store.unsubscribe(subscription)
      rnFollowSubscription = nil
    }
    if bindings[binding.tabId] === binding {
      bindings[binding.tabId] = nil
      if !mediaEnded {
        rememberMediaInScope(binding)
        NowPlayingStore.shared.end(tabId: binding.tabId)
      }
    }
    publishProtectionInScope(binding)
    if let registration = binding.registration {
      registrations[registration] = nil
      registry.retire(registration)
    }
    store.enqueuePageReport(id: binding.tabId, report: ["type": "gone", "generation": .string(binding.sessionGeneration)])
    store.sequence {}
  }

  public func isCurrent(_ binding: PageHostBinding, eligible: Bool = true) -> Bool {
    store.sequence { currentInScope(binding, requirePage: eligible) }
  }

  public func ensurePageEstablished(_ binding: PageHostBinding) -> Bool {
    store.sequence {
      guard currentInScope(binding, requirePage: false), refreshContextInScope(binding),
        let snapshot = try? store.pageHostSnapshotInScope(binding.tabId, generation: binding.sessionGeneration),
        snapshot.producerCurrent else { return false }
      if let facts = snapshot.facts { return facts.generation == binding.sessionGeneration }
      return establishInScope(binding, reestablished: true)
    }
  }

  private func establishInScope(_ binding: PageHostBinding, reestablished: Bool) -> Bool {
    guard binding.establishmentSerial < 9_007_199_254_740_991, refreshContextInScope(binding) else { return false }
    var report = binding.context.json
    report["type"] = "created"
    report["generation"] = .string(binding.sessionGeneration)
    report["engine"] = .string(binding.engine.rawValue)
    report["handoffSeq"] = binding.executedNavigationSeq.map { JSONValue($0) } ?? .null
    if reestablished { report["reestablished"] = true }
    store.enqueuePageReport(id: binding.tabId, report: .object(report))
    store.sequence {}
    guard currentInScope(binding, requirePage: true) else { return false }
    binding.establishmentSerial += 1
    if reestablished { binding.navigation = nil }
    afterSequence { [weak self, weak binding] in
      guard let self, let binding, self.isCurrent(binding) else { return }
      binding.onCreated(binding, reestablished)
    }
    return true
  }

  public func updateContext(_ binding: PageHostBinding, context: PageHostContext) -> Bool {
    store.sequence {
      guard ensurePageEstablished(binding),
        let snapshot = try? store.pageHostSnapshotInScope(binding.tabId, generation: binding.sessionGeneration),
        let tab = snapshot.state.tabs[binding.tabId],
        context.navigationSeq == tab.navigation.flatMap({ Int(exactly: $0.seq) }),
        context.contextRevision >= binding.context.contextRevision else { return false }
      if context.contextRevision == binding.context.contextRevision && context != binding.context { return false }
      var payload = context.json
      payload["type"] = "context"
      binding.context = context
      return report(binding, report: .object(payload))
    }
  }

  @discardableResult
  public func report(_ binding: PageHostBinding, report: JSONValue) -> Bool {
    store.sequence {
      guard ensurePageEstablished(binding), var payload = report.object else { return false }
      payload["generation"] = .string(binding.sessionGeneration)
      for (key, value) in binding.context.json where payload[key] == nil { payload[key] = value }
      store.enqueuePageReport(id: binding.tabId, report: .object(payload))
      store.sequence {}
      guard currentInScope(binding, requirePage: true) else { return false }
      if payload["type"]?.string == "navigation" { binding.navigation = .object(payload) }
      if payload["type"]?.string == "ready", binding.engine == .chromium,
        let browserId = payload["browserId"]?.int, browserId != 0, let onBrowserReady {
        afterSequence { [weak self, weak binding] in
          guard let self, let binding, self.store.sequence({
            self.currentInScope(binding, requirePage: true)
              && (try? self.store.pageHostSnapshotInScope(binding.tabId, generation: binding.sessionGeneration))?.facts?.ready?.browserId == browserId
          }) else { return }
          onBrowserReady(binding, browserId)
        }
      }
      return true
    }
  }

  public func reserveEvent(_ binding: PageHostBinding, name: String, payload: JSONValue) -> Int? {
    if name == "onNowPlaying" || name == "onPictureInPicture" {
      store.sequence {
        guard !mediaEnded, ensurePageEstablished(binding), currentInScope(binding, requirePage: true) else { return }
        if name == "onNowPlaying" {
          binding.reportedMedia.insert(.session)
          NowPlayingStore.shared.report(tabId: binding.tabId, NowPlayingReport(json: payload))
        } else if let kind = payload["kind"]?.string, let active = payload["active"]?.bool {
          if kind == "video" || kind == "document" { binding.reportedMedia.insert(.pictureInPicture(kind)) }
          NowPlayingStore.shared.setPictureInPicture(tabId: binding.tabId, kind: kind, active: active)
        }
      }
      return nil
    }
    if ["onDocumentCommitted", "onDiscarded", "onCrashed"].contains(name) {
      store.sequence {
        if currentInScope(binding, requirePage: true) { binding.documentRevision &+= 1 }
      }
    }
    if Self.consumePromptEvent?(self, binding, name, payload) == true { return nil }
    if name == "onOpenWindow", let request = payload.object, let consume = Self.consumePageOpen {
      store.sequence {
        guard ensurePageEstablished(binding), currentInScope(binding, requirePage: true) else { return }
        consume(self, binding, request)
      }
      return nil
    }
    let escape = name == "onCommand" && payload["command"]?.string == "escape"
    if escape || name == "onWindowClose", store.sequence({
      guard ensurePageEstablished(binding), currentInScope(binding, requirePage: true) else { return false }
      if escape, Self.consumeLifecycleEvent?(self, binding, name, payload) == true || Self.consumePeekEscape?(self, binding) == true {
        return true
      }
      return Self.consumeLittleWindowEvent?(self, binding, name) == true
    }) { return nil }
    let sequence = reserveEventInScope(binding, name: name, payload: payload)
    if !mediaEnded, sequence != nil, name == "onMediaAccess" {
      binding.reportedMedia.insert(.capture)
      let kind: TabCapture? = payload["screen"]?.bool == true ? .screen
        : payload["camera"]?.bool == true || payload["microphone"]?.bool == true ? .camera : nil
      NowPlayingStore.shared.setCapture(tabId: binding.tabId, kind)
    }
    if !escape, sequence != nil, Self.consumeLifecycleEvent?(self, binding, name, payload) == true { return nil }
    if sequence != nil {
      Self.lifecycleEvent?(self, binding, name, payload)
      for observer in Self.lifecycleObservers { observer(self, binding, name, payload) }
    }
    return sequence
  }

  private func reserveEventInScope(_ binding: PageHostBinding, name: String, payload: JSONValue) -> Int? {
    store.sequence {
      guard ensurePageEstablished(binding), currentInScope(binding, requirePage: true),
        binding.eventSeq < 9_007_199_254_740_991 else { return nil }
      binding.eventSeq += 1
      let sequence = binding.eventSeq
      if name == "onDownloadNavigation", dismissDownloadingPeekInScope(binding, payload: payload) { return nil }
      if var report = PageNativeReport.report(name: name, payload: payload)?.object {
        report["eventSeq"] = JSONValue(sequence)
        guard self.report(binding, report: .object(report)) else { return nil }
      }
      applyRendererEventInScope(binding, name: name, payload: payload)
      store.enqueuePageReport(id: binding.tabId, report: ["type": "latch",
        "generation": .string(binding.sessionGeneration), "eventSeq": JSONValue(sequence)])
      store.sequence {}
      guard currentInScope(binding, requirePage: true) else { return nil }
      return sequence
    }
  }

  private func dismissDownloadingPeekInScope(_ binding: PageHostBinding, payload: JSONValue) -> Bool {
    if let committed = payload["committedUrl"], !committed.isNull {
      guard let url = committed.string, url.isEmpty || url == "about:blank" else { return false }
    }
    if let skipped = payload["skipped"], skipped.bool == nil { return false }
    let state = store.state
    guard let tab = state.tabs[binding.tabId], state.peeks[tab.windowId]?.tabId == binding.tabId else { return false }
    return (try? store.dispatch(Command("closePeek", [.string(tab.windowId)]), origin: .engine)) != nil
  }

  private func applyRendererEventInScope(_ binding: PageHostBinding, name: String, payload: JSONValue) {
    let id = binding.tabId
    let command: Command
    switch name {
    case "onZoom":
      guard let zoom = payload["zoom"]?.number, zoom.isFinite, zoom > 0 else { return }
      command = Command("updateTab", [.string(id), ["zoom": .number(zoom)]])
    case "onFindResult":
      guard let count = payload["count"]?.int, let active = payload["active"]?.int else { return }
      command = Command("setFind", [.string(id), ["count": JSONValue(count), "active": JSONValue(active)]])
    case "onPageFocus", "onPagePress":
      let state = store.state
      guard let tab = state.tabs[id], state.activeTabId(tab.windowId) != id else { return }
      command = Command("activateVisiblePane", [.string(tab.windowId), .string(id)])
    default:
      return
    }
    _ = try? store.dispatch(command, origin: .engine)
  }

  public func eventEnvelope(_ binding: PageHostBinding, name: String, payload: JSONValue, eventSeq: Int? = nil) -> JSONValue? {
    store.sequence {
      guard currentInScope(binding, requirePage: true) else { return nil }
      return ["tabId": .string(binding.tabId), "registrationGeneration": JSONValue(Double(binding.registrationGeneration)),
        "sessionGeneration": .string(binding.sessionGeneration), "name": .string(name), "payload": payload,
        "eventSeq": eventSeq.map { JSONValue($0) } ?? .null]
    }
  }

  public func endPrivateSession(engineProfiles: [String]) {
    store.sequence {
      nativeExecutions = nativeExecutions.filter { entry in
        entry.value.page != nil && !(entry.value.binding.retired && engineProfiles.contains(entry.value.binding.profile))
      }
    }
  }

  public func associateNativePage(_ binding: PageHostBinding, page: AnyObject) {
    store.sequence {
      guard currentInScope(binding, requirePage: true) else { return }
      let key = ObjectIdentifier(page)
      let previous = nativeExecutions[key]
      let replaced = binding.associatedNativePage && (previous?.binding !== binding || previous?.page !== page)
      if replaced {
        nativeExecutions = nativeExecutions.filter { $0.value.binding !== binding }
        binding.reportedMedia.removeAll()
        if !mediaEnded { NowPlayingStore.shared.end(tabId: binding.tabId) }
      }
      nativeExecutions = nativeExecutions.filter { $0.value.page != nil }
      if let source = nativeExecutions[key], source.page === page,
        source.binding !== binding, source.binding.engine == binding.engine, source.binding.profile == binding.profile {
        transferExecutionInScope(from: source, to: binding)
      }
      binding.associatedNativePage = true
      nativeExecutions[key] = NativeExecution(page: page, binding: binding)
      if replaced {
        binding.documentRevision &+= 1
        for observer in Self.lifecycleObservers { observer(self, binding, "onPagePhysicalReplaced", .null) }
      }
    }
  }

  private func transferExecutionInScope(from source: NativeExecution, to binding: PageHostBinding) {
    if !mediaEnded, source.binding.tabId == binding.tabId, let media = source.media,
      source.binding.context.navigationSeq == binding.context.navigationSeq ||
      movedMediaWindowInScope(source.binding, windowId: binding.windowId) {
      NowPlayingStore.shared.restore(media, tabId: binding.tabId, excluding: binding.reportedMedia)
    }
    binding.executedNavigationSeq = source.binding.executedNavigationSeq
    binding.sameProfileMove = true
    try? store.rebasePageExecutionInScope(binding.tabId, generation: binding.sessionGeneration,
      executedNavigationSeq: binding.executedNavigationSeq)
  }

  public func noteExecuted(_ binding: PageHostBinding, navigationSeq: Int?) {
    store.sequence {
      guard currentInScope(binding, requirePage: true),
        navigationSeq.map({ $0 >= 0 && $0 <= 9_007_199_254_740_991 }) ?? true else { return }
      binding.executedNavigationSeq = navigationSeq
      try? store.confirmPageExecutionInScope(binding.tabId, generation: binding.sessionGeneration)
    }
  }

  public func preview(_ binding: PageHostBinding) -> PreparedPageIssue? {
    store.sequence {
      guard ensurePageEstablished(binding) else { return nil }
      return prepareInScope(binding)
    }
  }

  @discardableResult
  public func follow(_ binding: PageHostBinding) -> Bool {
    store.sequence {
      guard ensurePageEstablished(binding), let prepared = prepareInScope(binding) else { return false }
      return finishInScope(binding, guardValue: prepared.guardValue)
    }
  }

  public func dismissMedia(tabId: String, identity: PageIdentity) {
    guard !mediaEnded, let binding = self.binding(identity: identity), tabId == identity.tabId, isCurrent(binding),
      let entry = NowPlayingStore.shared.entries[tabId], !entry.removed else { return }
    NowPlayingStore.shared.remove(tabId)
    if entry.report.playing {
      issue(tabId: tabId, identity: identity, command: .mediaCommand("pause", 0)) { _ in }
    }
  }

  public func toggleMediaPictureInPicture(tabId: String, identity: PageIdentity, clickAt: Double, control: Int = 0) {
    guard !mediaEnded, clickAt.isFinite, clickAt >= 0, clickAt > 0 || control > 0, let binding = self.binding(identity: identity),
      tabId == identity.tabId, isCurrent(binding) else { return }
    guard let kind = NowPlayingStore.shared.pictureInPicture[tabId], let press = NowPlayingStore.shared.pipReceipt(tabId: tabId) else {
      issue(tabId: tabId, identity: identity, command: .requestPictureInPicture(clickAt, control)) { _ in }
      return
    }
    issue(tabId: tabId, identity: identity, command: .takeControlPress(clickAt, control)) { [weak self] result in
      guard let self, case .success(.bool(true)) = result,
        !self.mediaEnded, NowPlayingStore.shared.pipReceipt(tabId: tabId) == press else { return }
      let command: PageCommand = kind == "document" ? .executeJavaScript("window.documentPictureInPicture?.window?.close()") : .exitPictureInPicture
      self.issue(tabId: tabId, identity: identity, command: command) { _ in }
    }
  }

  public func pruneMedia() {
    store.sequence {
      guard !mediaEnded else { return }
      let media = NowPlayingStore.shared
      for id in Set(media.entries.keys).union(media.pictureInPicture.keys).union(media.capture.keys) {
        guard let binding = bindings[id], !currentInScope(binding, requirePage: true) else { continue }
        if movedMediaWindowInScope(binding, windowId: store.state.tabs[id]?.windowId) {
          rememberMediaInScope(binding)
        }
        media.end(tabId: id)
      }
    }
  }

  private func movedMediaWindowInScope(_ source: PageHostBinding, windowId: String?) -> Bool {
    guard let windowId, source.windowId != windowId, let tab = store.state.tabs[source.tabId],
      store.state.engineProfile(tab.profileId) == source.profile, let navigation = tab.navigation else { return false }
    return navigation.url == tab.url && navigation.userInitiated != true
  }

  private func rememberMediaInScope(_ binding: PageHostBinding) {
    guard let media = NowPlayingStore.shared.snapshot(tabId: binding.tabId) else { return }
    for key in Array(nativeExecutions.keys) where nativeExecutions[key]?.binding === binding {
      nativeExecutions[key]?.media = media
    }
  }

  public func endMedia() {
    store.sequence {
      guard !mediaEnded else { return }
      mediaEnded = true
      for id in Array(nativeExecutions.keys) { nativeExecutions[id]?.media = nil }
      for id in bindings.keys { NowPlayingStore.shared.end(tabId: id) }
    }
  }

  public func issue(tabId: String, identity: PageIdentity, command: PageCommand, completion: @escaping PageRegistry.Completion) {
    store.sequence {
      guard tabId == identity.tabId, let registration = exactBinding(identity)?.registration else {
        afterSequence { completion(.failure(.retired(PageRegistration(tabID: identity.tabId, registrationGeneration: identity.registrationGeneration)))) }
        return
      }
      registry.call(registration, command: command, completion: completion)
    }
  }

  public func issueInScope(tabId: String, identity: PageIdentity, command: PageCommand, completion: @escaping PageRegistry.Completion) {
    do {
      try store.withinSequence {
        guard tabId == identity.tabId, let binding = exactBinding(identity), currentInScope(binding, requirePage: true) else {
          afterSequence { completion(.failure(.retired(PageRegistration(tabID: identity.tabId, registrationGeneration: identity.registrationGeneration)))) }
          return
        }
        guard command.supports(engine: binding.engine) else {
          afterSequence { completion(.failure(.unsupported(binding.engine, command.method))) }
          return
        }
        if command == .nativeTag {
          let value = binding.nativeTag.map { PageValue.number(Double($0)) } ?? .null
          afterSequence { [weak self, weak binding] in
            guard let self, let binding, self.isCurrent(binding) else {
              completion(.failure(.retired(PageRegistration(tabID: identity.tabId, registrationGeneration: identity.registrationGeneration))))
              return
            }
            completion(.success(value))
          }
          return
        }
        if command == .livePage {
          let snapshot = try store.pageHostSnapshotInScope(binding.tabId, generation: binding.sessionGeneration)
          let ready = snapshot.facts?.ready.map { PageValue.object(["browserId": .number(Double($0.browserId)), "tabId": $0.tabId.map { .number(Double($0)) } ?? .null]) } ?? .null
          let value: PageValue = .object(["tabId": .string(binding.tabId), "engine": .string(binding.engine.rawValue),
            "host": .string(binding.host.rawValue), "registrationGeneration": .number(Double(binding.registrationGeneration)),
            "sessionGeneration": .string(binding.sessionGeneration), "ready": ready,
            "navigation": PageValue(json: binding.navigation ?? .null)])
          afterSequence { [weak self, weak binding] in
            guard let self, let binding, self.isCurrent(binding) else {
              completion(.failure(.retired(PageRegistration(tabID: identity.tabId, registrationGeneration: identity.registrationGeneration))))
              return
            }
            completion(.success(value))
          }
          return
        }
        if case .finishPageIssue(let guardValue) = command {
          let accepted = finishInScope(binding, guardValue: guardValue)
          afterSequence { completion(.success(.object(["accepted": .bool(accepted)]))) }
          return
        }
        binding.perform(command) { [weak self, weak binding] result in
          guard let self else { return }
          self.afterSequence {
            guard let binding, self.isCurrent(binding) else {
              completion(.failure(.retired(PageRegistration(tabID: identity.tabId, registrationGeneration: identity.registrationGeneration))))
              return
            }
            completion(result)
          }
        }
      }
    } catch {
      afterSequence { completion(.failure(.failed("Page issuance requires the caller's Store sequence"))) }
    }
  }

  private func exactBinding(_ identity: PageIdentity) -> PageHostBinding? {
    let registration = PageRegistration(tabID: identity.tabId, registrationGeneration: identity.registrationGeneration)
    guard let binding = registrations[registration], binding.sessionGeneration == identity.sessionGeneration,
      bindings[identity.tabId] === binding, !binding.retired else { return nil }
    return binding
  }

  private func eligible(_ tab: Tab, state: BrowserState, engine: PageEngine) -> Bool {
    tab.unloaded != true && (tab.pageIn ?? "").isEmpty && state.windows[tab.windowId] != nil &&
      store.pageEngine(tab.id, in: state) == engine.rawValue
  }

  private func currentInScope(_ binding: PageHostBinding, requirePage: Bool) -> Bool {
    guard !binding.retired, binding.owner != nil, let registration = binding.registration,
      bindings[binding.tabId] === binding, registrations[registration] === binding,
      let snapshot = try? store.pageHostSnapshotInScope(binding.tabId, generation: binding.sessionGeneration),
      let tab = snapshot.state.tabs[binding.tabId], eligible(tab, state: snapshot.state, engine: binding.engine),
      snapshot.state.engineProfile(tab.profileId) == binding.profile else { return false }
    return !requirePage || (snapshot.producerCurrent && snapshot.facts?.generation == binding.sessionGeneration)
  }

  private func refreshContextInScope(_ binding: PageHostBinding) -> Bool {
    guard let snapshot = try? store.pageHostSnapshotInScope(binding.tabId, generation: binding.sessionGeneration),
      let tab = snapshot.state.tabs[binding.tabId] else { return false }
    let sequence = tab.navigation.flatMap { Int(exactly: $0.seq) }
    if let previous = binding.windowId, previous != tab.windowId, sequence != binding.context.navigationSeq { binding.movedNavigationSeq = sequence }
    binding.windowId = tab.windowId
    if binding.context.navigationSeq != sequence {
      binding.context.navigationSeq = sequence
    }
    return true
  }

  private func prepareInScope(_ binding: PageHostBinding) -> PreparedPageIssue? {
    guard refreshContextInScope(binding),
      let snapshot = try? store.pageHostSnapshotInScope(binding.tabId, generation: binding.sessionGeneration),
      let tab = snapshot.state.tabs[binding.tabId] else { return nil }
    var report = binding.context.json
    report["generation"] = .string(binding.sessionGeneration)
    if let navigation = tab.navigation {
      report["navigation"] = ["seq": JSONValue(navigation.seq), "url": .string(navigation.url),
        "userInitiated": .bool(navigation.userInitiated ?? false)]
    } else { report["navigation"] = .null }
    report["startedEarly"] = .bool(binding.executedNavigationSeq != nil && binding.executedNavigationSeq == binding.context.navigationSeq)
    report["sameProfileMove"] = .bool(binding.movedTo(binding.context.navigationSeq))
    return try? store.preparePageIssueInScope(id: binding.tabId, report: .object(report))
  }

  private func finishInScope(_ binding: PageHostBinding, guardValue: PageIssueGuard) -> Bool {
    guard currentInScope(binding, requirePage: true), let prepared = prepareInScope(binding),
      prepared.guardValue == guardValue, currentInScope(binding, requirePage: true),
      store.consumePooledIssue(id: binding.tabId, prepared: prepared) else {
      afterSequence { [weak binding] in if let binding, !binding.retired { binding.onNeedsFollow(binding) } }
      return false
    }
    for action in prepared.actions.array ?? [] {
      if action["type"]?.string == "clearNewTabShown" {
        binding.context.newTabShownUrl = nil
        let consumed = prepared.guardValue
        afterSequence { [weak self, weak binding] in
          guard let self, let binding, self.isCurrent(binding) else { return }
          binding.onClearNewTabShown(binding, consumed)
        }
      } else if action["type"]?.string == "load", let url = action["url"]?.string {
        binding.perform(.loadUrl(url, action["userInitiated"]?.bool ?? false)) { _ in }
      }
    }
    binding.sameProfileMove = false
    binding.movedNavigationSeq = nil
    return true
  }
}
