import AppKit
import SolaraCore
import SolaraModel
import SolaraShell
import SolaraStore
import SolaraUI

@MainActor
final class NativeTranslation: NativeSiteControlsContribution {
  static let shared = NativeTranslation()

  private struct Page: Equatable {
    let identity: PageIdentity
    let ownership: Int
    let window: String
    let profile: String
    let ruleOwner: String
    let privateWindow: Bool
    let site: String
    let url: String
    let navigation: Int?
  }

  @MainActor
  private final class Entry {
    let page: Page
    let revision: Int
    var life = TranslationLifetime()
    var work: Task<Void, Never>?
    var progress: Int?
    #if DEBUG
    var lastError: String?
    #endif
    let never: Bool

    init(page: Page, never: Bool, revision: Int) {
      self.page = page
      self.never = never
      self.revision = revision
    }
  }

  private weak var store: Store?
  private var storeListener: Int?
  private var entries: [String: Entry] = [:]
  private var started = false
  private var pending: Set<String> = []
  private var refreshScheduled = false
  private var toastID = 0

  private static let preferred = Locale.preferredLanguages
  private static let target = TranslationLifetime.baseLanguage(preferred.first ?? "en")

  private static func name(_ language: String) -> String {
    Locale.current.localizedString(forIdentifier: language) ?? language
  }

  func start() {
    guard !started, PageTranslationProvider.available else { return }
    started = true
    NativeSiteControls.shared.translate = self
    _ = NativeStoreHandle.subscribeLifecycle { [weak self] in self?.reconcileStore() }
    _ = PageRegistry.shared.observe { [weak self] event in
      switch event {
      case .registered(let descriptor): self?.schedule([descriptor.tabID])
      case .retired(let registration):
        if let self, let entry = self.entries[registration.tabID],
          entry.page.identity.registrationGeneration == registration.registrationGeneration {
          self.remove(entry)
        }
      }
    }
    PageIssuer.lifecycleObservers.append { [weak self] issuer, binding, name, payload in
      guard let self, self.currentStore === issuer.store,
        ["onNavigationChange", "onReady", "onDiscarded", "onLoadError", "onCrashed"].contains(name) else { return }
      if let entry = self.entries[binding.tabId], entry.page.identity == binding.identity,
        payload["isLoading"]?.bool == true || name == "onCrashed" || name == "onDiscarded" || name == "onLoadError" {
        self.remove(entry)
      }
      self.schedule([binding.tabId])
    }
  }

  private var currentStore: Store? {
    guard NativeStoreHandle.ownsWorkspace, !NativeStoreHandle.frozen, NativeStoreHandle.store === store else { return nil }
    return store
  }

  private func reconcileStore() {
    let next = NativeStoreHandle.ownsWorkspace && !NativeStoreHandle.frozen ? NativeStoreHandle.store : nil
    guard next !== store else { return }
    if let storeListener { store?.unsubscribe(storeListener) }
    for entry in Array(entries.values) { remove(entry) }
    store = next
    storeListener = next?.subscribe { [weak self, weak next] commit in
      let changes = commit.changes
      let rules = changes.settingsChanged.contains("neverTranslateSites") || changes.settingsRemoved.contains("neverTranslateSites")
      guard rules || !changes.tabs.isEmpty || !changes.live.isEmpty || !changes.windows.isEmpty || !changes.profiles.isEmpty else { return }
      Task { @MainActor in
        guard let self, let next, self.currentStore === next else { return }
        self.storeChanged(commit, rules: rules)
      }
    }
    if let next { schedule(Set(next.state.live.keys)) }
  }

  private func storeChanged(_ commit: Commit, rules: Bool) {
    let changes = commit.changes
    let snapshot = commit.state
    let windows = Set(changes.windows.upserted).union(changes.windows.removed)
    var ids = Set(changes.tabs.upserted).union(changes.tabs.removed)
      .union(changes.live.upserted).union(changes.live.removed)
    if !windows.isEmpty {
      ids.formUnion(snapshot.live.keys.filter { id in snapshot.tabs[id].map { windows.contains($0.windowId) } == true })
    }
    if rules || !windows.isEmpty {
      for entry in Array(entries.values) where commit.rev > entry.revision {
        let page = entry.page
        let changedProfile = windows.contains(page.window) && snapshot.windows[page.window]?.profileId != page.profile
        let changedRule = rules && Self.never(page, in: snapshot.settings) != entry.never
        if changedProfile || changedRule {
          remove(entry)
          ids.insert(page.identity.tabId)
        }
      }
    }
    if rules || !changes.profiles.isEmpty { ids.formUnion(entries.keys) }
    schedule(ids)
  }

  private func schedule(_ ids: Set<String>) {
    guard !ids.isEmpty else { return }
    pending.formUnion(ids)
    guard !refreshScheduled else { return }
    refreshScheduled = true
    DispatchQueue.main.async {
      self.refreshScheduled = false
      let ids = self.pending
      self.pending.removeAll()
      for id in ids { self.refresh(id) }
    }
  }

  private func page(_ id: String) -> Page? {
    guard let store = currentStore, let issuer = PageIssuer.shared, issuer.store === store,
      let binding = issuer.binding(tabId: id), issuer.isCurrent(binding) else { return nil }
    let snapshot = store.state
    guard let tab = snapshot.tabs[id], let window = snapshot.windows[tab.windowId],
      window.profileId == tab.profileId, !store.memory.closingWindows.contains(tab.windowId),
      let site = TranslationLifetime.site(tab.url), let live = snapshot.live[id], !live.isLoading, !live.discarded,
      binding.navigation?["isLoading"]?.bool == false else { return nil }
    return Page(identity: binding.identity, ownership: NativeStoreHandle.ownershipGeneration,
      window: tab.windowId, profile: tab.profileId,
      ruleOwner: TranslationLifetime.ruleOwner(profile: tab.profileId,
        original: window.originalProfileId ?? Ids.incognitoOriginal(tab.profileId), privateWindow: window.incognito),
      privateWindow: window.incognito, site: site, url: tab.url, navigation: tab.navigation.flatMap { Int(exactly: $0.seq) })
  }

  private static func never(_ page: Page, in settings: Settings) -> Bool {
    settings["neverTranslateSites"]?[page.ruleOwner]?.array?.contains(.string(page.site)) == true
  }

  private func current(_ entry: Entry, _ receipt: TranslationLifetime.Receipt? = nil) -> Bool {
    guard let store = currentStore else { return false }
    return store.sequence {
      let id = entry.page.identity.tabId
      return entries[id] === entry && page(id) == entry.page && Self.never(entry.page, in: store.state.settings) == entry.never
        && (receipt.map(entry.life.accepts) ?? true)
    }
  }

  private func refresh(_ id: String) {
    guard let store = currentStore else { return }
    let candidate = store.sequence {
      page(id).map { (page: $0, never: Self.never($0, in: store.state.settings), revision: store.rev) }
    }
    if let entry = entries[id] {
      if let candidate, candidate.page == entry.page && candidate.never == entry.never {
        if !entry.never && entry.life.receipt == nil && entry.work == nil { detect(entry) }
        return
      }
      remove(entry)
    }
    guard let candidate else { return }
    let entry = Entry(page: candidate.page, never: candidate.never, revision: candidate.revision)
    entries[id] = entry
    if !entry.never { detect(entry) }
    changed()
  }

  private func changed() {
    NativeToolbarPresenter.refreshContributions()
    NativeSiteControls.shared.refresh()
  }

  private func remove(_ entry: Entry) {
    entries[entry.page.identity.tabId] = nil
    entry.work?.cancel()
    hideProgress(entry)
    if entry.life.phase != .idle, let receipt = entry.life.receipt { restore(entry.page, receipt) }
    entry.life.invalidate()
    changed()
  }

  private func evaluate(_ entry: Entry, receipt: TranslationLifetime.Receipt? = nil, script: String) async -> JSONValue? {
    guard let store = currentStore else { return nil }
    let result: JSONValue? = await withCheckedContinuation { continuation in
      store.sequence {
        guard !Task.isCancelled, current(entry, receipt), let issuer = PageIssuer.shared, issuer.store === store else {
          continuation.resume(returning: nil)
          return
        }
        let identity = entry.page.identity
        issuer.issueInScope(tabId: identity.tabId, identity: identity, command: .evaluate(script)) { result in
          guard case .success(.string(let text)) = result else { return continuation.resume(returning: nil) }
          continuation.resume(returning: try? JSONValue.parse(text))
        }
      }
    }
    guard !Task.isCancelled, current(entry, receipt) else { return nil }
    return result
  }

  private func evaluate(_ entry: Entry, _ receipt: TranslationLifetime.Receipt, _ operation: String, _ args: [Any]) async -> JSONValue? {
    let script = TranslationScript.call(operation, document: receipt.document, url: entry.page.url, arguments: args)
    return await evaluate(entry, receipt: receipt, script: script)
  }

  private func restore(_ page: Page, _ receipt: TranslationLifetime.Receipt) {
    guard let issuer = PageIssuer.shared, issuer.binding(identity: page.identity) != nil else { return }
    let script = TranslationScript.call("revert", document: receipt.document, arguments: [receipt.token])
    issuer.issue(tabId: page.identity.tabId, identity: page.identity, command: .evaluate(script)) { _ in }
  }

  private func detect(_ entry: Entry) {
    entry.work = Task { [weak self, weak entry] in
      guard let self, let entry, let script = TranslationScript.sample(url: entry.page.url) else { return }
      defer { if !Task.isCancelled { entry.work = nil } }
      for delay in [100, 250, 500] {
        guard !Task.isCancelled, current(entry) else { return }
        if var sample = await evaluate(entry, script: script), let document = sample["document"]?.string {
          guard !Task.isCancelled, current(entry) else { return }
          let receipt = entry.life.replace(document: document)
          if let orphan = sample["token"]?.string {
            guard await evaluate(entry, receipt, "revert", [orphan])?.bool == true,
              let original = await evaluate(entry, receipt, "sample", []), current(entry, receipt) else { return }
            sample = original
          }
          let text = sample["text"]?.string ?? ""
          let declared = String((sample["lang"]?.string ?? "").prefix(20))
          let detected = text.utf16.count >= 40 ? PageTranslationProvider.detect(String(text.prefix(3000))) : nil
          if let source = TranslationLifetime.offer(detected ?? declared, preferred: Self.preferred),
            await status(source, Self.target) != .unsupported, !Task.isCancelled, current(entry, receipt) {
            entry.life.source = source
            changed()
          }
          return
        }
        try? await Task.sleep(for: .milliseconds(delay))
      }
    }
  }

  func toolbar(tabId: String, windowId: String) -> ToolbarPresenter.Translation? {
    guard let entry = entry(tabId, windowId), let source = entry.life.source else { return nil }
    return .init(translated: entry.life.phase != .idle, language: Self.name(source))
  }

  private func entry(_ id: String, _ window: String) -> Entry? {
    guard let entry = entries[id], entry.page.window == window, current(entry) else { return nil }
    return entry
  }

  func toggle(tabId: String, windowId: String) {
    guard let entry = entry(tabId, windowId), !entry.never else { return }
    if entry.life.phase == .idle { translate(entry, target: Self.target) }
    else { revert(entry, quiet: false) }
  }

  private func translate(_ entry: Entry, target: String) {
    guard current(entry), !entry.never, let source = entry.life.source else { return }
    if entry.life.phase != .idle { revert(entry, quiet: true) }
    guard TranslationLifetime.baseLanguage(source) != TranslationLifetime.baseLanguage(target) else {
      toast(entry, "Translation error (the page is already in \(Self.name(target)))")
      return
    }
    entry.work?.cancel()
    guard let receipt = entry.life.begin(source: source, target: target) else { return }
    #if DEBUG
    entry.lastError = nil
    #endif
    changed()
    entry.work = Task { [weak self, weak entry] in
      guard let self, let entry, current(entry, receipt), !Task.isCancelled else { return }
      do {
        let availability = await status(source, target)
        guard !Task.isCancelled, current(entry, receipt) else { return }
        switch availability {
        case .installed: break
        case .supported: try await PageTranslationProvider.prepare(source, target, in: ShellDrag.window(entry.page.window))
        case .unsupported: throw Failure.unavailable(Self.name(source), Self.name(target))
        }
        guard !Task.isCancelled, current(entry, receipt) else { return }
        guard let started = await evaluate(entry, receipt, "start", [receipt.token])?.bool else {
          loseDocument(entry, receipt)
          return
        }
        guard started else { throw Failure.pageUnavailable }
        let began = ContinuousClock.now
        guard try await drain(entry, receipt, source: source, target: target, began: began) else {
          loseDocument(entry, receipt)
          return
        }
        guard current(entry, receipt), entry.life.finish(receipt) else { return }
        hideProgress(entry)
        toast(entry, "Translated to \(Self.name(target))")
        changed()
        await follow(entry, receipt, source: source, target: target)
      } catch {
        guard !Task.isCancelled, current(entry, receipt) else { return }
        revert(entry, quiet: true)
        let reason = error.localizedDescription.trimmingCharacters(in: .whitespacesAndNewlines.union(CharacterSet(charactersIn: ".")))
        #if DEBUG
        entry.lastError = reason
        #endif
        toast(entry, "Translation error (\(reason))")
      }
    }
  }

  private enum Failure: LocalizedError {
    case pageUnavailable
    case unavailable(String, String)
    #if DEBUG
    case fixture
    #endif

    var errorDescription: String? {
      switch self {
      case .pageUnavailable: "the page isn't ready"
      case .unavailable(let source, let target): "\(source) to \(target) isn't available"
      #if DEBUG
      case .fixture: "test translation failed"
      #endif
      }
    }
  }

  private func revert(_ entry: Entry, quiet: Bool) {
    guard let receipt = entry.life.receipt, entry.life.phase != .idle, entry.life.cancel(receipt) else { return }
    entry.work?.cancel()
    restore(entry.page, receipt)
    hideProgress(entry)
    if !quiet, let source = entry.life.source { toast(entry, "Translated back to \(Self.name(source))") }
    changed()
  }

  private func loseDocument(_ entry: Entry, _ receipt: TranslationLifetime.Receipt) {
    guard current(entry, receipt) else { return }
    remove(entry)
    refresh(entry.page.identity.tabId)
  }

  private func follow(_ entry: Entry, _ receipt: TranslationLifetime.Receipt, source: String, target: String) async {
    while !Task.isCancelled && current(entry, receipt) {
      do {
        try await Task.sleep(for: .milliseconds(600))
        if try await drain(entry, receipt, source: source, target: target, began: nil) == false {
          loseDocument(entry, receipt)
          return
        }
      } catch {
        if Task.isCancelled || !current(entry, receipt) { return }
      }
    }
  }

  private func drain(_ entry: Entry, _ receipt: TranslationLifetime.Receipt, source: String, target: String,
    began: ContinuousClock.Instant?) async throws -> Bool {
    while !Task.isCancelled && current(entry, receipt) {
      guard let batch = await evaluate(entry, receipt, "next", [receipt.token, TranslationScript.maximumPassages, TranslationScript.maximumCharacters]),
        batch["gone"]?.bool == false, let raw = batch["passages"]?.array else { return false }
      let passages = raw.prefix(32).compactMap { passage -> [TranslationBatches.Piece]? in
        passage.array?.dropFirst().first?.array?.prefix(40).compactMap { raw in
          guard let pair = raw.array, pair.count == 2, let id = pair[0].int, let text = pair[1].string else { return nil }
          return .init(id: id, text: text)
        }
      }
      if !passages.isEmpty {
        let values: [TranslationBatches.Result]
        do {
          values = try await TranslationBatches.translate(passages,
            blocks: { await self.blocks(source, target, $0) },
            loose: { try await self.loose(source, target, $0) })
        } catch {
          let rejected: [[Any]] = passages.flatMap { $0 }.map { [$0.id, NSNull()] }
          if !Task.isCancelled { _ = await evaluate(entry, receipt, "apply", [receipt.token, rejected]) }
          throw error
        }
        let results: [[Any]] = values.map { [$0.id, $0.text as Any? ?? NSNull()] }
        guard await evaluate(entry, receipt, "apply", [receipt.token, results])?.bool == true else { return false }
      }
      if let began, began.duration(to: .now) >= .milliseconds(1200),
        let total = batch["total"]?.number, total > 0, let done = batch["done"]?.number {
        progress(entry, target: target, value: Int(min(99, max(0, (100 * done / total).rounded()))))
      }
      if batch["more"]?.bool != true { return true }
    }
    return false
  }

  private func toast(_ entry: Entry, _ title: String) {
    toastID -= 1
    NativeSplitChrome.showNativeToast(.init(id: toastID, title: title, icon: "translate"), windowId: entry.page.window)
  }

  private func progress(_ entry: Entry, target: String, value: Int) {
    if entry.progress == nil {
      toastID -= 1
      entry.progress = toastID
    }
    guard let id = entry.progress else { return }
    NativeSplitChrome.showNativeToast(.init(id: id, title: "Translating to \(Self.name(target))…", message: "\(value)%",
      icon: "translate", sticky: true), windowId: entry.page.window)
  }

  private func hideProgress(_ entry: Entry) {
    guard let id = entry.progress else { return }
    entry.progress = nil
    NativeSplitChrome.hideNativeToast(id, windowId: entry.page.window)
  }

  private func setNever(_ entry: Entry, _ value: Bool) {
    guard current(entry), TranslationLifetime.canChangeRule(privateWindow: entry.page.privateWindow),
      value != entry.never, let model = NativeSettingsHandle.model, let store = currentStore else { return }
    store.sequence {
      guard current(entry) else { return }
      var all = store.state.settings["neverTranslateSites"]?.object ?? [:]
      let owner = entry.page.ruleOwner
      let site = JSONValue.string(entry.page.site)
      var sites = (all[owner]?.array ?? []).filter { $0 != site }
      if value { sites.append(site) }
      all[owner] = .array(sites)
      model.update(["neverTranslateSites": .object(all)])
    }
    refresh(entry.page.identity.tabId)
  }

  func menu(tabId: String, windowId: String) {
    guard let entry = entry(tabId, windowId), let receipt = entry.life.receipt else { return }
    let translated = entry.life.phase != .idle
    var rows: [[String: Any]] = [
      ["id": translated ? "original" : "translate", "title": translated ? "Show Original" : "Translate to \(Self.name(Self.target))",
        "symbol": translated ? "arrow.uturn.backward" : "translate"],
      ["id": "choose", "title": "Choose Another Language…", "symbol": "globe"],
    ]
    if !entry.page.privateWindow {
      rows += [["separator": true], ["id": "never", "title": "Never Translate This Site", "checked": entry.never]]
    }
    ShellMenus.choose(rows) { [weak self, weak entry] choice in
      guard let self, let entry, self.current(entry, receipt) else { return }
      switch choice {
      case "original": self.revert(entry, quiet: false)
      case "translate": self.translate(entry, target: Self.target)
      case "choose": self.choose(entry)
      case "never": self.setNever(entry, !entry.never)
      default: break
      }
    }
  }

  private func choose(_ entry: Entry) {
    guard let receipt = entry.life.receipt, !entry.never else { return }
    Task { [weak self, weak entry] in
      let languages = await PageTranslationProvider.supportedLanguages()
      guard let self, let entry, current(entry, receipt) else { return }
      var byBase: [String: String] = [:]
      for id in languages {
        let base = TranslationLifetime.baseLanguage(id)
        if id.count < (byBase[base]?.count ?? .max) { byBase[base] = id }
      }
      let sorted = byBase.values.map { (id: $0, name: Self.name($0)) }.sorted {
        $0.name.localizedCompare($1.name) == .orderedAscending
      }
      ShellMenus.choose(sorted.map { ["id": $0.id, "title": $0.name, "checked": $0.id == entry.life.target] }) { [weak self, weak entry] choice in
        guard let self, let entry, let choice, self.current(entry, receipt) else { return }
        self.translate(entry, target: choice)
      }
    }
  }

  func rows(tabId: String, windowId: String) -> JSONValue {
    guard let entry = entry(tabId, windowId), entry.life.source != nil || entry.never else { return .array([]) }
    let translated = entry.life.phase != .idle
    var rows: [JSONValue] = []
    if !entry.never {
      rows += [
        ["kind": "row", "id": "translate:toggle", "icon": .string(translated ? "arrow.uturn.backward" : "translate"),
          "title": .string(translated ? "Show Original (\(Self.name(entry.life.source ?? "")))" : "Translate to \(Self.name(Self.target))"),
          "pressable": true],
        ["kind": "row", "id": "translate:choose", "icon": "globe", "title": "Choose Another Language…", "pressable": true],
      ]
    }
    if !entry.page.privateWindow {
      rows.append(["kind": "row", "id": "translate:never", "icon": "nosign", "title": "Never Translate This Site",
        "accessory": ["kind": "toggle", "value": .bool(entry.never)]])
    }
    if !rows.isEmpty { rows.append(["kind": "separator"]) }
    return .array(rows)
  }

  func handle(_ event: SitePanelEvent, tabId: String, windowId: String, close: @escaping () -> Void) -> Bool {
    guard let entry = entry(tabId, windowId) else { return false }
    switch event {
    case .press("translate:toggle", _):
      close()
      toggle(tabId: tabId, windowId: windowId)
    case .press("translate:choose", _):
      close()
      if current(entry) { choose(entry) }
    case .toggle("translate:never", let value): setNever(entry, value)
    default: return false
    }
    return true
  }

  private func status(_ source: String, _ target: String) async -> PageTranslationProvider.Status {
    #if DEBUG
    if fixtureSource != nil { return .installed }
    #endif
    return await PageTranslationProvider.status(source, target)
  }

  private func blocks(_ source: String, _ target: String, _ texts: [[String]]) async -> [[String]?] {
    #if DEBUG
    if fixtureSource != nil { return texts.map { _ in nil } }
    #endif
    return await PageTranslationProvider.translateBlocks(source, target, texts)
  }

  private func loose(_ source: String, _ target: String, _ texts: [String]) async throws -> [String?] {
    #if DEBUG
    if let fixtureSource {
      let delay = fixtureDelay
      let fail = fixtureFailure
      await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
        DispatchQueue.main.asyncAfter(deadline: .now() + .milliseconds(delay)) { continuation.resume() }
      }
      if fail { throw Failure.fixture }
      return texts.map { "\(fixtureSource)\($0)" }
    }
    #endif
    return try await PageTranslationProvider.translate(source, target, texts)
  }

  #if DEBUG
  private var fixtureSource: String?
  private var fixtureDelay = 0
  private var fixtureFailure = false

  func fixture(prefix: String, delay: Int, fail: Bool) {
    fixtureSource = prefix
    fixtureDelay = min(5000, max(0, delay))
    fixtureFailure = fail
    for entry in Array(entries.values) where entry.life.source == nil && !entry.never {
      entry.work?.cancel()
      detect(entry)
    }
  }

  func probe(_ id: String) -> [String: Any] {
    guard let entry = entries[id], current(entry) else { return [:] }
    return ["phase": entry.life.phase.rawValue, "source": entry.life.source as Any? ?? NSNull(),
      "document": entry.life.receipt?.document as Any? ?? NSNull(), "never": entry.never,
      "profile": entry.page.profile, "progress": entry.progress as Any? ?? NSNull(),
      "lastError": entry.lastError as Any? ?? NSNull(), "rows": rows(tabId: id, windowId: entry.page.window).foundation]
  }

  func testAction(_ id: String, action: String, target: String?) {
    guard let entry = entries[id], current(entry) else { return }
    switch action {
    case "translate": translate(entry, target: target ?? Self.target)
    case "revert": revert(entry, quiet: false)
    case "never": setNever(entry, true)
    case "allow": setNever(entry, false)
    default: break
    }
  }
  #endif
}
