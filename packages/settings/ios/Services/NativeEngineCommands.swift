import AppKit
import SolaraCore
import SolaraModel
import SolaraShell
import SolaraStore
import SolaraUI

@MainActor
enum NativeEngineCommands {
  struct Back {
    let engine: String
    let url: String
    let window: String
    let profile: String
    let navigation: Navigation?
    var identity: PageIdentity?
    let destination: String
    let ownership: Int
  }
  static var backChanged: (@MainActor () -> Void)?
  private static var observer: UUID?
  private static var lifecycle: Int?
  private static var storeIdentity: Store?
  private static var storeObserver: Int?
  private static var cancellations: [String: @MainActor () -> Void] = [:]
  private static var validityChecks: [UUID: @MainActor () -> Void] = [:]
  static func start() {
    if lifecycle == nil { lifecycle = NativeStoreHandle.subscribeLifecycle { resetForStore(); backChanged?() } }
    resetForStore()
    guard observer == nil, let issuer = PageIssuer.shared else { return }
    observer = issuer.registry.observe { event in
      switch event {
      case .registered(let descriptor):
        guard var back = backs[descriptor.tabID], let store = NativeStoreHandle.store,
          store.state.tabs[descriptor.tabID]?.navigation == back.navigation, store.pageEngine(descriptor.tabID, in: store.state) == back.destination else { return }
        issuer.store.sequence {
          guard let binding = issuer.binding(tabId: descriptor.tabID), issuer.isCurrent(binding) else { return }
          if back.identity != nil { backs[descriptor.tabID] = nil }
          else { back.identity = binding.identity; backs[descriptor.tabID] = back }
        }
      case .retired(let registration):
        if backs[registration.tabID]?.identity?.registrationGeneration == registration.registrationGeneration { backs[registration.tabID] = nil }
      }
    }
  }

  private static func resetForStore() {
    let store = NativeStoreHandle.ownsWorkspace ? NativeStoreHandle.store : nil
    guard store !== storeIdentity else { return }
    if let storeObserver { storeIdentity?.unsubscribe(storeObserver) }
    storeIdentity = store
    storeObserver = store?.subscribe { _ in
      Task { @MainActor in if !backs.isEmpty { backChanged?() } }
    }
    let cancel = Array(cancellations.values)
    cancellations = [:]
    requests = [:]
    backs = [:]
    siteMoves = [:]
    for action in cancel { action() }
  }

  private static var requests: [String: UUID] = [:]
  private static var siteMoves: [String: TimeInterval] = [:]
  private static var backs: [String: Back] = [:] { didSet { backChanged?() } }
  #if DEBUG
  static var consent: Bool?
  static var confirmations = 0
  #endif

  static func hasBack(_ tabId: String) -> Bool {
    guard let store = NativeStoreHandle.store, let tab = store.state.tabs[tabId], let back = backs[tabId],
      NativeStoreHandle.ownsWorkspace, back.ownership == NativeStoreHandle.ownershipGeneration,
      tab.windowId == back.window, tab.profileId == back.profile, tab.navigation == back.navigation,
      store.pageEngine(tabId, in: store.state) == back.destination else { if backs[tabId] != nil { backs[tabId] = nil }; return false }
    guard let identity = back.identity, let issuer = PageIssuer.shared else { return false }
    return issuer.store.sequence { issuer.binding(tabId: tabId).map { $0.identity == identity && issuer.isCurrent($0) } == true }
  }

  static func perform(_ command: String, arg: String?, windowId: String?) -> Bool {
    #if DEBUG
    FocusMoves.trace("engine menu window=\(windowId ?? "nil") owned=\(NativeStoreHandle.ownsWorkspace)")
    #endif
    guard NativeStoreHandle.ownsWorkspace, let store = NativeStoreHandle.store else { return true }
    let route = CommandRoute.resolve("togglePageEngine", windowId: windowId, state: store.state, closing: store.memory.closingWindows)
    #if DEBUG
    FocusMoves.trace("engine route window=\(route.windowId ?? "nil") tab=\(route.tabId ?? "nil")")
    #endif
    guard let id = route.tabId else { return true }
    request(tabId: id, action: "toggle", options: [:]) { _ in }
    return true
  }

  static func request(tabId: String, action: String, options: JSONObject, completion: @escaping (Bool) -> Void) {
    #if DEBUG
    FocusMoves.trace("engine \(tabId) request action=\(action)")
    #endif
    start()
    guard NativeStoreHandle.ownsWorkspace, let store = NativeStoreHandle.store, let tab = store.state.tabs[tabId],
      !store.memory.closingWindows.contains(tab.windowId), let issuer = PageIssuer.shared else { completion(false); return }
    let source = store.pageEngine(tabId, in: store.state)
    if action == "persist" {
      guard tab.engine == nil, let engine = options["engine"]?.string, engine == source else { completion(false); return }
      do { try store.dispatch(Command("updateTab", [.string(tabId), .object(["engine": .string(engine)])]), origin: .native); completion(true) }
      catch { completion(false) }
      return
    }
    let back = action == "back" && hasBack(tabId) ? backs[tabId] : nil
    if action == "back", back == nil { completion(false); return }
    var destination = back?.engine ?? options["engine"]?.string ?? (source == "webkit" ? "chromium" : "webkit")
    if action == "follow" {
      guard tab.openerId?.isEmpty != false, tab.url == options["url"]?.string,
        let previous = options["previousUrl"]?.string, EngineCommand.differentSite(from: previous, to: tab.url),
        Date().timeIntervalSince1970 - (siteMoves[tabId] ?? 0) >= 10,
        let chosen = store.chosenPageEngine(for: tab.url, in: store.state), chosen != source else { completion(false); return }
      destination = chosen
      siteMoves[tabId] = Date().timeIntervalSince1970
    }
    #if DEBUG
    FocusMoves.trace("engine \(tabId) source=\(source) destination=\(destination) holder=\(store.state.sharedPageHolder(tabId)?.id ?? "nil")")
    #endif
    guard store.state.sharedPageHolder(tabId) == nil, let plan = EngineCommand.plan(tab: tab, currentEngine: source, destination: destination) else {
      #if DEBUG
      FocusMoves.trace("engine \(tabId) rejected shared copy or unsupported URL")
      #endif
      completion(false)
      return
    }
    let ownership = NativeStoreHandle.ownershipGeneration
    let identity: PageIdentity? = issuer.store.sequence {
      guard let binding = issuer.binding(tabId: tabId), issuer.ensurePageEstablished(binding), issuer.isCurrent(binding) else {
        #if DEBUG
        let binding = issuer.binding(tabId: tabId)
        FocusMoves.trace("engine \(tabId) no identity binding=\(binding != nil) established=\(binding.map { issuer.ensurePageEstablished($0) } ?? false) current=\(binding.map { issuer.isCurrent($0) } ?? false)")
        #endif
        return nil
      }
      return binding.identity
    }
    if var receipt = back, let identity {
      if let expected = receipt.identity, expected != identity { backs[tabId] = nil; completion(false); return }
      receipt.identity = identity
      backs[tabId] = receipt
    }
    let selected = store.state.activeTabId(tab.windowId)
    let profile = store.state.windows[tab.windowId]?.profileId
    cancellations[tabId]?()
    let token = UUID()
    requests[tabId] = token
    var completed = false
    var alert: NSAlert?
    var validity: Timer?
    @MainActor func finish(_ value: Bool) {
      guard !completed else { return }
      completed = true
      validity?.invalidate()
      validity = nil
      validityChecks[token] = nil
      #if DEBUG
      FocusMoves.trace("engine \(tabId) finish accepted=\(value) action=\(action)")
      #endif
      if let alert, let window = alert.window.sheetParent { window.endSheet(alert.window, returnCode: .alertSecondButtonReturn) }
      alert = nil
      if requests[tabId] == token { requests[tabId] = nil; cancellations[tabId] = nil }
      completion(value)
    }
    @MainActor func current() -> Bool {
      guard !completed, requests[tabId] == token, NativeStoreHandle.ownsWorkspace, NativeStoreHandle.store === store,
        NativeStoreHandle.ownershipGeneration == ownership, !store.memory.closingWindows.contains(tab.windowId),
        store.state.windows[tab.windowId]?.profileId == profile, store.state.activeTabId(tab.windowId) == selected,
        store.state.sharedPageHolder(tabId) == nil,
        plan.current(tab: store.state.tabs[tabId], engine: store.pageEngine(tabId, in: store.state)) else { return false }
      return issuer.store.sequence {
        guard let identity else { return issuer.binding(tabId: tabId) == nil }
        guard let binding = issuer.binding(tabId: tabId), binding.identity == identity else { return false }
        return issuer.isCurrent(binding)
      }
    }
    cancellations[tabId] = { finish(false) }
    validityChecks[token] = { if !current() { finish(false) } }
    let monitor = Timer(timeInterval: 0.1, repeats: true) { _ in
      MainActor.assumeIsolated { validityChecks[token]?() }
    }
    validity = monitor
    RunLoop.main.add(monitor, forMode: .common)
    @MainActor func replace() {
      guard current() else { finish(false); return }
      do {
        if let rule = options["rule"], plan.canRemember, let url = URL(string: plan.url), let host = url.host, let scheme = url.scheme,
          scheme == "http" || scheme == "https" {
          let site = "\(scheme)://\(host)\(url.port.map { ":\($0)" } ?? "")".lowercased()
          var rules = store.state.settings["websiteEngines"]?.object ?? [:]
          if rule.isNull { rules[site] = nil } else if ["webkit", "chromium"].contains(rule.string ?? "") { rules[site] = rule }
          try store.dispatch(Command("updateSettings", [.object(["websiteEngines": .object(rules)])]), origin: .native)
        }
        guard current() else { finish(false); return }
        if plan.replacesPage || back != nil {
          let url = back?.url ?? plan.url
          try store.dispatch(Command("switchPageEngine", [.string(tabId), .string(destination), .string(url)]), origin: .native)
          if action == "follow", let previous = options["previousUrl"]?.string,
            EngineCommand.plan(tab: Tab(id: tabId, windowId: tab.windowId, profileId: tab.profileId, url: previous, now: 0), currentEngine: destination, destination: source) != nil {
            backs[tabId] = Back(engine: source, url: previous, window: tab.windowId, profile: tab.profileId, navigation: store.state.tabs[tabId]?.navigation, destination: destination, ownership: ownership)
          }
          if back != nil { backs[tabId] = nil }
          FrameUpdates.flush()
        }
        finish(true)
      } catch { finish(false) }
    }
    @MainActor func carry() {
      guard current() else { finish(false); return }
      guard destination == "webkit", source == "chromium", NativeEngineSignIn.enabled, let identity,
        var parsed = URLComponents(string: plan.url), ["http", "https"].contains(parsed.scheme ?? "") else { replace(); return }
      let profile = store.state.engineProfile(tab.profileId)
      let key = NativeEngineSignIn.storeKey(profile: profile)
      parsed.fragment = nil
      let address = parsed.string ?? plan.url
      parsed.path = "/"
      parsed.query = nil
      let addresses = Array(Set([address, parsed.string ?? address]))
      var carried = false
      @MainActor func done() { guard !carried else { return }; carried = true; replace() }
      issuer.store.sequence {
        issuer.issueInScope(tabId: tabId, identity: identity, command: .pageCookies(addresses)) { result in
          guard !carried, current(), let cookies = try? result.get().foundation as? [[String: Any]] else { done(); return }
          NativeEngineSignIn.copy(cookies: cookies, profile: profile, key: key) { _ in done() }
        }
      }
      DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { done() }
    }
    @MainActor func consent(_ unsaved: Bool) {
      guard current() else { finish(false); return }
      guard unsaved else { carry(); return }
      let name = destination == "webkit" ? "WebKit" : "Chromium"
      #if DEBUG
      confirmations += 1
      if let choice = Self.consent { if choice { carry() } else { finish(false) }; return }
      #endif
      let sheet = NSAlert()
      alert = sheet
      sheet.messageText = back == nil ? "Open this page in \(name)?" : "Go back to the previous page?"
      sheet.informativeText = back == nil ? "The page reloads in \(name), so changes you made on it may not be saved." : "It opens in \(name), so changes you made on this page may not be saved."
      sheet.addButton(withTitle: back == nil ? "Open in \(name)" : "Go Back")
      sheet.addButton(withTitle: "Stay on Page")
      guard let window = WindowHost.contentView(tab.windowId)?.window else { finish(false); return }
      sheet.beginSheetModal(for: window) { result in
        if result == .alertFirstButtonReturn { carry() } else { finish(false) }
      }
    }
    #if DEBUG
    FocusMoves.trace("engine \(tabId) plan replacesPage=\(plan.replacesPage) back=\(back != nil) identity=\(identity != nil) action=\(action)")
    #endif
    if !plan.replacesPage && back == nil { replace(); return }
    if action == "follow" || options["checkWork"]?.bool == false || identity == nil { carry() }
    else if let identity {
      var evaluated = false
      @MainActor func evaluatedWork(_ dirty: Bool) { guard !evaluated else { return }; evaluated = true; consent(dirty) }
      issuer.store.sequence {
        issuer.issueInScope(tabId: tabId, identity: identity, command: .evaluate(EngineCommand.unsavedWork)) { result in
          #if DEBUG
          FocusMoves.trace("engine \(tabId) unsaved result \(String(describing: try? result.get()))")
          #endif
          guard !evaluated else { return }
          guard let dirty = (try? result.get())?.postedJSON?.bool else { finish(false); return }
          evaluatedWork(dirty)
        }
      }
      DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { if !evaluated { evaluated = true; finish(false) } }
    }
  }
}
