import AppKit
import SolaraModel
import SolaraShell
import SolaraStore
import SolaraUI

@MainActor
enum NativePinnedPageCommands {
  static let changed = Notification.Name("SolaraPinnedPagePresentationChanged")
  private static var listener: Int?
  private static var lifecycle: Int?
  private static var subscribedStore: Store?
  private static var serial = 0
  private static var interactions = PinnedPageCommand.Interactions()
  private static var latest: [String: Int] = [:]
  private static var families: [String: Int] = [:]
  private static var pictures: [String: String] = [:]
  private static var bridges: [String: (copy: String, uri: String)] = [:]
  private static var painted: [String: () -> Void] = [:]
  private static var committing = false

  static func start() {
    guard lifecycle == nil else { return }
    lifecycle = NativeStoreHandle.subscribeLifecycle { bindStore() }
  }

  private static func bindStore() {
    let store = NativeStoreHandle.ownsWorkspace ? NativeStoreHandle.store : nil
    guard store !== subscribedStore else { return }
    if let listener { subscribedStore?.unsubscribe(listener) }
    listener = nil
    subscribedStore = store
    serial += 1
    interactions = PinnedPageCommand.Interactions(state: store?.state)
    latest.removeAll()
    families.removeAll()
    pictures.removeAll()
    bridges.removeAll()
    painted.removeAll()
    publish()
    guard let store else { return }
    listener = store.subscribe { [weak store] commit in
      let deliver: @MainActor () -> Void = {
        guard let store, subscribedStore === store, NativeStoreHandle.ownsWorkspace else { return }
        receive(commit.state)
        for effect in commit.effects {
          if case .pinHandoff(let id) = effect { request("handOffPin", tabId: id) }
        }
      }
      if Thread.isMainThread { MainActor.assumeIsolated { deliver() } }
      else { Task { @MainActor in deliver() } }
    }
    #if DEBUG
    FocusMoves.trace("pinHandoff listening")
    #endif
  }

  private static func receive(_ state: BrowserState) {
    interactions.receive(state, committing: committing)
    pictures = pictures.filter { state.sharedPageHolder($0.key) != nil }
    bridges = bridges.filter { state.windows[$0.key] != nil && state.tabs[$0.value.copy] != nil }
    publish()
  }

  static func presentation(windowId: String, tabId: String) -> [String: Any]? {
    guard let state = NativeStoreHandle.store?.state, state.tabs[tabId]?.windowId == windowId else { return nil }
    let dark = WindowHost.contentView(windowId)?.effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
    guard let value = PinnedPageCommand.presentation(tabId: tabId, state: state, token: serial,
      picture: pictures[tabId], bridge: bridges[windowId], dark: dark) else { return nil }
    return PageValue(json: .object(value)).foundation as? [String: Any]
  }

  static func presentations(windowId: String) -> [String: [String: Any]] {
    guard let state = NativeStoreHandle.store?.state else { return [:] }
    return Dictionary(uniqueKeysWithValues: state.tabs.values.filter { $0.windowId == windowId }.compactMap { tab in
      presentation(windowId: windowId, tabId: tab.id).map { (tab.id, $0) }
    })
  }

  static func didPaint(windowId: String, tabId: String, copyId: String, token: Int) {
    guard token == serial, bridges[windowId]?.copy == copyId,
      NativeStoreHandle.store?.state.sharedPageHolder(copyId)?.id == tabId else { return }
    painted.removeValue(forKey: windowId)?()
  }
  private static func publish() {
    NativeSplitChrome.refreshPinnedPages()
    NotificationCenter.default.post(name: changed, object: nil)
  }

  static func available(windowId: String?) -> Bool {
    guard let store = NativeStoreHandle.store else { return false }
    let route = CommandRoute.resolve("returnToPinnedUrl", windowId: windowId, state: store.state, closing: store.memory.closingWindows)
    guard let id = route.tabId, let tab = store.state.tabs[id], let home = tab.pinnedUrl, !home.isEmpty else { return false }
    return !tab.url.isEmpty && !samePage(tab.url, home)
  }

  static func perform(_ command: String, arg: String?, windowId: String?) -> Bool {
    let history = command == "back" || command == "forward"
    guard NativeStoreHandle.ownsWorkspace, let store = NativeStoreHandle.store else { return !history }
    let route = CommandRoute.resolve(command, windowId: windowId, state: store.state, closing: store.memory.closingWindows)
    let explicit = arg.flatMap { try? JSONValue.parse($0) }?["tabId"]?.string
    guard let id = explicit ?? route.tabId, let tab = store.state.tabs[id], !store.memory.closingWindows.contains(tab.windowId) else { return true }
    if history, store.state.sharedPageHolder(id) == nil { return false }
    request(command, tabId: id)
    return true
  }

  static func request(_ command: String, tabId: String, then: ((String) -> Void)? = nil) {
    guard NativeStoreHandle.ownsWorkspace, let store = NativeStoreHandle.store,
      let plan = PinnedPageCommand.plan(command, tabId: tabId, state: store.state), let issuer = PageIssuer.shared else {
      #if DEBUG
      FocusMoves.trace("pinHandoff rejected command=\(command) tab=\(tabId) owns=\(NativeStoreHandle.ownsWorkspace) issuer=\(PageIssuer.shared != nil)")
      #endif
      return
    }
    start()
    let source = plan.holder.windowId
    let target = plan.copy.windowId
    let key = "\(plan.copy.profileId)\u{1}\(plan.copy.pinKeyOrId)"
    serial += 1
    let request = serial
    #if DEBUG
    FocusMoves.trace("pinHandoff \(request) command=\(command) copy=\(plan.copy.id) holder=\(plan.holder.id) source=\(source) target=\(target) moving=\(plan.moving)")
    #endif
    latest[target] = request
    families[key] = request
    let ownership = NativeStoreHandle.ownershipGeneration
    let intent = interactions[target]
    let selected = store.state.activeTabId(target)
    let profile = store.state.windows[target]?.profileId
    let gate = PinnedPageCommand.Gate(request: request, interaction: intent, ownership: ownership, deadline: Date().timeIntervalSince1970 + 3)
    let captured: (PageIdentity, ObjectIdentifier?)? = issuer.store.sequence {
      guard let binding = issuer.binding(tabId: plan.holder.id), issuer.ensurePageEstablished(binding), issuer.isCurrent(binding) else { return nil }
      return (binding.identity, TabPoolHost.shared.pageView(plan.holder.id).map(ObjectIdentifier.init))
    }
    func current() -> Bool {
      let bindingCurrent = captured == nil || issuer.store.sequence { issuer.binding(tabId: plan.holder.id).map { $0.identity == captured?.0 && issuer.isCurrent($0) } == true }
      let allowed = NativeStoreHandle.ownsWorkspace && NativeStoreHandle.store === store && families[key] == request
        && gate.allows(request: latest[target] ?? -1, interaction: interactions[target], ownership: NativeStoreHandle.ownershipGeneration, now: Date().timeIntervalSince1970)
        && store.state.activeTabId(target) == selected && store.state.windows[target]?.profileId == profile && plan.current(store.state)
        && !store.memory.closingWindows.contains(target)
        && bindingCurrent
      #if DEBUG
      if !allowed {
        FocusMoves.trace("pinHandoff \(request) stale owns=\(NativeStoreHandle.ownsWorkspace) binding=\(bindingCurrent) plan=\(plan.current(store.state)) intent=\(intent)/\(interactions[target]) selected=\(selected ?? "nil")/\(store.state.activeTabId(target) ?? "nil") latest=\(latest[target] ?? -1) family=\(families[key] ?? -1)")
      }
      #endif
      return allowed
    }
    var finished = false
    func finish(_ uri: String?) {
      guard !finished else { return }
      finished = true
      guard current() else { return }
      #if DEBUG
      FocusMoves.trace("pinHandoff \(request) captured image=\(uri != nil)")
      #endif
      if let uri { pictures[plan.copy.id] = uri }
      func commit() {
        painted[source] = nil
        guard current() else { bridges[source] = nil; publish(); return }
        committing = true
        defer { committing = false; bridges[source] = nil; publish() }
        do {
          guard try gate.perform(request: latest[target] ?? -1, interaction: interactions[target],
            ownership: NativeStoreHandle.ownershipGeneration, now: Date().timeIntervalSince1970, {
              if plan.moving || command == "handOffPin" { try store.dispatch(Command("handOffPin", [.string(plan.copy.id)]), origin: .native) }
            }) else { return }
          #if DEBUG
          FocusMoves.trace("pinHandoff \(request) committed holderWindow=\(store.state.tabs[plan.holder.id]?.windowId ?? "nil")")
          #endif
          if plan.home { try store.dispatch(Command("returnToPinnedUrl", [.string(plan.holder.id)]), origin: .native) }
          interactions.receive(store.state, committing: true)
          FrameUpdates.flush()
          guard let action = plan.page else { then?(plan.holder.id); return }
          let navigation = store.state.tabs[plan.holder.id]?.navigation
          let arrivalIntent = interactions[target]
          var completed = false
          var observer: UUID?
          func arrive() {
            guard !completed, NativeStoreHandle.ownsWorkspace, NativeStoreHandle.store === store,
              NativeStoreHandle.ownershipGeneration == ownership, families[key] == request, latest[target] == request,
              interactions[target] == arrivalIntent, Date().timeIntervalSince1970 < gate.deadline,
              (!plan.moving || store.state.activeTabId(target) == plan.holder.id), store.state.tabs[plan.holder.id]?.windowId == target,
              store.state.tabs[plan.holder.id]?.navigation == navigation, store.state.tabs[plan.holder.id]?.pageIn?.isEmpty != false else { return }
            issuer.store.sequence {
              guard let binding = issuer.binding(tabId: plan.holder.id), issuer.ensurePageEstablished(binding), issuer.isCurrent(binding),
                store.pageFacts(plan.holder.id)?.ready != nil else { return }
              if plan.moving, let physical = captured?.1 {
                guard let page = TabPoolHost.shared.pageView(plan.holder.id), ObjectIdentifier(page) == physical,
                  let window = WindowHost.contentView(target)?.window, page.window === window else { return }
              } else if let identity = captured?.0, binding.identity != identity { return }
              completed = true
              #if DEBUG
              FocusMoves.trace("pinHandoff \(request) arrival command=\(command) holder=\(plan.holder.id)")
              #endif
              if let observer { issuer.registry.removeObserver(observer) }
              issuer.issueInScope(tabId: plan.holder.id, identity: binding.identity, command: action) { _ in }
            }
          }
          observer = issuer.registry.observe { _ in arrive() }
          TabPoolHost.shared.afterPlacement { arrive() }
          arrive()
          DispatchQueue.main.asyncAfter(deadline: .now() + 3) {
            #if DEBUG
            if !completed { FocusMoves.trace("pinHandoff \(request) arrival expired holder=\(plan.holder.id) target=\(target) actual=\(store.state.tabs[plan.holder.id]?.windowId ?? "nil") ready=\(store.pageFacts(plan.holder.id)?.ready != nil)") }
            #endif
            completed = true
            if let observer { issuer.registry.removeObserver(observer) }
          }
        } catch { NSLog("[commands] pinned page failed: %@", String(describing: error)) }
      }
      if plan.moving, let uri, store.state.activeTabId(source) == plan.holder.id {
        bridges[source] = (plan.copy.id, uri)
        var committed = false
        let once = { if !committed { committed = true; commit() } }
        painted[source] = once
        #if DEBUG
        FocusMoves.trace("pinHandoff \(request) waiting for source paint")
        #endif
        publish()
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.12, execute: once)
      } else { commit() }
    }
    guard plan.moving, let captured else { finish(nil); return }
    issuer.store.sequence {
      issuer.issueInScope(tabId: plan.holder.id, identity: captured.0, command: .capturePicture(1)) { result in
        let value = try? result.get()
        finish(value?.json["data"]?.string.map { "data:image/jpeg;base64,\($0)" })
      }
    }
    DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) { finish(PinnedPageCommand.pictureAfterCaptureTimeout(holder: NativeTabPictures.shared.cache.picture(plan.holder.id).map { "data:image/jpeg;base64,\($0.data)" }, previous: pictures[plan.copy.id])) }
  }
}
