import AppKit
import Foundation
import Observation
import SolaraModel
import SolaraOmnibox

public enum Disposition: String, Sendable {
  case current, newTab, newWindow

  public static func from(meta: Bool, alt: Bool, shift: Bool) -> Disposition {
    if meta || alt { return .newTab }
    if shift { return .newWindow }
    return .current
  }
}

public enum BarVariant: String, Sendable {
  case hero, panel, sidebar
}

public enum BarDismissal: String, Sendable {
  case escape, closeKey
}

public enum HeroJourney: String, Sendable {
  case committed, focused, keystroke, suggestions, navigate, queryInvalidated
}

public enum HeroMenuChoice: String, Sendable {
  case cut, copy, paste, selectAll
}

@MainActor
public struct HeroBarEvents {
  public var open: (String, Disposition) -> Void = { _, _ in }
  public var switchTo: (String, String, Disposition) -> Void = { _, _, _ in }
  public var runAction: (String) -> Void = { _ in }
  public var runExtension: (SolaraOmnibox.Suggestion) -> Void = { _ in }
  public var removeHistory: (String) -> Void = { _ in }
  public var chosen: (SolaraOmnibox.Suggestion?) -> Void = { _ in }
  public var openChip: () -> Void = {}
  public var dictate: () -> Void = {}
  public var contextMenu: (_ hasSelection: Bool, _ hasValue: Bool) -> Void = { _, _ in }
  public var journey: (HeroJourney) -> Void = { _ in }
  public var latency: (Double) -> Void = { _ in }
  public var queryJourney: ((HeroJourney, String, String, String, Double?) -> Void)?
  public var queryCommit: ((@escaping @MainActor () -> Void) -> Void)?
  public var keyShown: () -> Void = {}
  public var changed: () -> Void = {}
  public var done: (BarDismissal?) -> Void = { _ in }
  public var cancel: (UUID) -> Void = { _ in }
  public var siteControls: () -> Void = {}
  public var copy: (String) -> Void = { text in
    NSPasteboard.general.clearContents()
    NSPasteboard.general.setString(text, forType: .string)
  }
  public var readClipboard: () -> String = { NSPasteboard.general.string(forType: .string) ?? "" }

  public init() {}
}

@MainActor
public protocol HeroFieldControl: AnyObject {
  func show(value: String, selection: TextSelection)
  func focusField()
  func releaseFocus()
  var hasFocus: Bool { get }
  var fieldSelection: TextSelection { get }
}

public struct HeroBarSnapshot: Sendable, Equatable {
  var typed: String
  var edited: Bool
  var selection: TextSelection
  var selected: Int
  var scope: SearchScope?
  var scopeFrom: String
}

public struct HeroKey: Sendable, Equatable {
  public enum Name: String, Sendable {
    case escape, arrowUp, arrowDown, pageUp, pageDown, tab, backspace, delete, enter
  }

  public var name: Name
  public var shift = false
  public var alt = false
  public var meta = false
  public var ctrl = false

  public init(_ name: Name, shift: Bool = false, alt: Bool = false, meta: Bool = false, ctrl: Bool = false) {
    self.name = name
    self.shift = shift
    self.alt = alt
    self.meta = meta
    self.ctrl = ctrl
  }
}

@MainActor
@Observable
public final class HeroBarModel {
  @ObservationIgnored static var saved: [String: HeroBarSnapshot] = [:]
  static let bangWord = try! NSRegularExpression(pattern: "^![^\\s!]+$")

  public let variant: BarVariant
  public let opensTab: Bool
  public let initialText: String
  public let windowId: String
  public let tabId: String
  public let profileId: String
  public var incognito: Bool
  @ObservationIgnored public var events = HeroBarEvents()
  @ObservationIgnored public weak var field: HeroFieldControl?
  @ObservationIgnored public var settings: () -> Settings
  public var currentUrl: String
  @ObservationIgnored let sources: NewTabSources
  @ObservationIgnored private var fetcher: SuggestFetcher?
  @ObservationIgnored let bangs: () -> any BangTable
  @ObservationIgnored private let bangStore: BangStore?
  @ObservationIgnored private var requestedBangRefresh = false
  @ObservationIgnored let now: @MainActor () -> Double

  public private(set) var typed: String
  public private(set) var edited: Bool
  public private(set) var suppressCompletion = true
  public private(set) var selected: Int
  public private(set) var scope: SearchScope?
  @ObservationIgnored public private(set) var scopeFrom: String
  public private(set) var result = SuggestionResult(items: [], completion: "")
  public private(set) var shown = ""
  public private(set) var filled: String?
  @ObservationIgnored private var filledKey: String?
  @ObservationIgnored private var typedSelection: TextSelection?
  public private(set) var listAway = false
  @ObservationIgnored public private(set) var selection: TextSelection
  @ObservationIgnored private var remote: (text: String, list: [String]) = ("", [])
  @ObservationIgnored private var fetching: String?
  @ObservationIgnored private var keyAt: ContinuousClock.Instant?
  @ObservationIgnored private var queryEpoch: String?
  @ObservationIgnored private var queryGeneration = 0
  @ObservationIgnored private var sourcesSeen = -1
  @ObservationIgnored private var tabScopeCache: (key: String, scope: SearchScope?)?
  @ObservationIgnored private var changeAnnounced = false
  @ObservationIgnored public private(set) var editing = false
  @ObservationIgnored public private(set) var editingSession = UUID()
  @ObservationIgnored private var focusedOnce = false

  public init(
    windowId: String, tabId: String, profileId: String, incognito: Bool, settings: @escaping () -> Settings,
    sources: NewTabSources = .shared, fetcher: SuggestFetcher? = nil, bangs: @escaping () -> any BangTable = { BundledBangs.table },
    bangStore: BangStore? = nil, variant: BarVariant = .hero, opensTab: Bool = false, initialText: String = "", currentUrl: String = "",
    now: @escaping @MainActor () -> Double = { Date().timeIntervalSince1970 * 1000 }
  ) {
    self.variant = variant
    self.opensTab = opensTab
    self.initialText = initialText
    self.currentUrl = opensTab ? "" : currentUrl
    self.windowId = windowId
    self.tabId = tabId
    self.profileId = profileId
    self.incognito = incognito
    self.settings = settings
    self.sources = sources
    self.fetcher = fetcher?.makeContext()
    self.bangStore = bangStore
    self.bangs = bangStore.map { store in { store.tableForUse() } } ?? bangs
    self.now = now
    let restored = variant == .hero ? HeroBarModel.saved[tabId] : nil
    typed = restored?.typed ?? initialText
    edited = restored?.edited ?? false
    selected = restored?.selected ?? (opensTab ? -1 : 0)
    scope = restored?.scope
    scopeFrom = restored?.scopeFrom ?? ""
    selection = restored?.selection ?? (initialText.isEmpty ? .caret(0) : TextSelection(start: 0, end: initialText.utf16.count))
    recompute()
    observeBangs()
  }

  public func setFetcher(_ fetcher: SuggestFetcher?) {
    self.fetcher?.cancel()
    self.fetcher = fetcher?.makeContext()
    fetching = nil
    remote = ("", [])
    recompute()
    writeField()
  }

  isolated deinit {
    fetcher?.cancel()
  }

  public var engine: SearchEngine { defaultSearchEngine(settings()) }
  public var hero: Bool { variant == .hero }
  var noneSelected: Int { opensTab ? -1 : 0 }
  var idle: Bool { opensTab && scope == nil && jsTrim(typed).isEmpty }
  var showsStart: Bool { variant == .sidebar && !edited && scope == nil }

  public var items: [SolaraOmnibox.Suggestion] {
    if showsStart { return dropdownStart() }
    if idle {
      return sources.openTabs(windowId: windowId, profileId: profileId, excluding: sources.activeTabId(windowId: windowId, profileId: profileId))
    }
    return result.items
  }
  public var value: String { filled ?? typed + shown }
  var home: Int { idle ? -1 : 0 }
  public var selectedIndex: Int { selected < 0 && idle ? -1 : min(max(selected, 0), items.count - 1) }
  public var current: SolaraOmnibox.Suggestion? { items.indices.contains(selectedIndex) ? items[selectedIndex] : nil }

  public var tabScope: SearchScope? {
    guard scope == nil, edited else { return nil }
    let key = "\(typed)\u{1}\(shown)\u{1}\(sourcesSeen)"
    if let cached = tabScopeCache, cached.key == key { return cached.scope }
    let found = offeredSiteSearch(typed, shown, scopeSources())
    tabScopeCache = (key, found)
    return found
  }

  public var placeholder: String {
    if let scope { return "Search \(scope.name)" }
    return incognito ? "Search privately or enter address" : "Search or enter address"
  }

  public var goLabel: String {
    switch current {
    case .search(_, _, let engine, _, _): engine
    case .calc: "Copy"
    default: "Go"
    }
  }

  public var goEnabled: Bool { !hero || !jsTrim(typed).isEmpty }

  public var leadingSuggestion: SolaraOmnibox.Suggestion? {
    guard let current, !typed.isEmpty || scope != nil else { return nil }
    if case .search = current { return nil }
    return current
  }

  public var trailingHint: String? { tabScope.map { "Search \($0.name)  ⇥" } }

  public func snapshot() -> HeroBarSnapshot {
    HeroBarSnapshot(typed: typed, edited: edited, selection: selection, selected: selected, scope: scope, scopeFrom: scopeFrom)
  }

  public func save() {
    invalidateQueryProbe()
    guard hero else { return }
    if !typed.isEmpty || scope != nil { HeroBarModel.saved[tabId] = snapshot() } else { HeroBarModel.saved[tabId] = nil }
  }

  public func panelOpened(_ open: Bool) {
    if hero && open && !listAway { listAway = true }
  }

  public func mounted() {
    events.journey(.committed)
  }

  public func focusOnce() {
    guard !focusedOnce, let field else { return }
    focusedOnce = true
    field.focusField()
    field.show(value: value, selection: selection)
    events.journey(.focused)
  }

  public func focusSelectingAll() {
    field?.focusField()
    selection = TextSelection(start: 0, end: value.utf16.count)
    field?.show(value: value, selection: selection)
  }

  public func didFocus() {
    editingSession = UUID()
    editing = true
    listAway = false
  }

  public func didBlur(session: UUID) {
    guard session == editingSession else { return }
    invalidateQueryProbe()
    editing = false
    if !hero { events.cancel(session) }
  }

  public func sourcesChanged() {
    guard sourcesSeen != sources.revision else { return }
    recompute()
    writeField()
  }

  private func observeBangs() {
    guard let bangStore else { return }
    withObservationTracking {
      _ = bangStore.revision
    } onChange: { [weak self] in
      Task { @MainActor [weak self] in
        guard let self else { return }
        self.observeBangs()
        self.recompute()
        self.writeField()
      }
    }
  }

  public func textChanged(_ next: String, edit: EditContext?) {
    keyAt = .now
    events.journey(.keystroke)
    let before = filled
    let suppress = InlineRules.preventsInline(typed: before ?? typed, shown: before == nil ? shown : "", next: next, edit: edit)
    clearFill()
    if scope == nil, let bySpace = keywordBySpace(before ?? typed, next), let keyword = keywordScope(bySpace.keyword) {
      enterScope(keyword, from: bySpace.from)
      return
    }
    edited = true
    typed = next
    shown = ""
    suppressCompletion = suppress
    selected = opensTab && jsTrim(next).isEmpty ? -1 : 0
    selection = edit?.after ?? .caret(next.utf16.count)
    update()
  }

  public func selectionChanged(_ next: TextSelection) {
    selection = next
    if filled != nil { return }
    if InlineRules.acceptsCompletion(typed: typed, shown: shown, selection: next) {
      typed = value
      shown = ""
      suppressCompletion = true
      selected = 0
      update()
    }
  }

  @discardableResult
  public func key(_ k: HeroKey) -> Bool {
    switch k.name {
    case .escape:
      if filled != nil {
        selected = home
        restoreTyped()
        return true
      }
      if scope != nil {
        leaveScope(nil)
      } else if !hero {
        invalidateQueryProbe()
        events.done(.escape)
      } else if !shown.isEmpty {
        suppressCompletion = true
        update()
      } else {
        reset()
      }
      return true
    case .arrowDown:
      move(1)
      return true
    case .arrowUp:
      move(-1)
      return true
    case .pageUp:
      selected = 0
      followHighlight()
      return true
    case .pageDown:
      selected = max(0, items.count - 1)
      followHighlight()
      return true
    case .delete:
      guard k.shift, case .page(let url, _, _, let tabId, _, let visited)? = current, visited, tabId == nil else { return false }
      events.removeHistory(url)
      return true
    case .tab, .backspace:
      if k.name == .tab && k.ctrl { return false }
      if k.name == .backspace && (filled != nil || !asksForBackspace(scope)) { return false }
      if k.name == .tab && filled != nil {
        move(k.shift ? -1 : 1)
        return true
      }
      let mods = SiteSearchKeyModifiers(shiftKey: k.shift, altKey: k.alt, metaKey: k.meta, ctrlKey: k.ctrl)
      let state = SiteSearchKeyState(typed: typed, completion: shown, scope: scope, offered: tabScope, scopeFrom: scopeFrom)
      switch siteSearchKey(k.name == .tab ? "Tab" : "Backspace", mods, state) {
      case .enter(let next, let from)?:
        enterScope(next, from: from)
        return true
      case .leave(let text)?:
        leaveScope(text)
        return true
      case .accept(let text)?:
        clearFill()
        typed = text
        shown = ""
        suppressCompletion = true
        selection = .caret(text.utf16.count)
        update()
        return true
      case nil:
        if k.name == .tab {
          move(k.shift ? -1 : 1)
          return true
        }
        return false
      }
    case .enter:
      let text = jsTrim(filled ?? typed)
      if k.meta && k.shift {
        forceSearch()
        return true
      }
      if k.ctrl && !text.isEmpty && text.rangeOfCharacter(from: HeroBarModel.wwwBreakers) == nil {
        go("https://www.\(text).com", k.shift ? .newWindow : .current)
        return true
      }
      if k.meta || k.alt || k.shift {
        choose(current, Disposition.from(meta: k.meta, alt: k.alt, shift: k.shift), byEnter: true)
        return true
      }
      if k.ctrl { return true }
      submit()
      return true
    }
  }

  static let wwwBreakers = CharacterSet.whitespacesAndNewlines.union(CharacterSet(charactersIn: "./:"))

  public func submit() {
    choose(current, .current, byEnter: true)
  }

  public func chooseRow(_ s: SolaraOmnibox.Suggestion) {
    choose(s, .current, byEnter: false)
  }

  public func removeRow(_ url: String) {
    events.removeHistory(url)
  }

  public func goPressed() {
    choose(current, .current, byEnter: true)
  }

  public func dictatePressed() {
    field?.focusField()
    events.dictate()
  }

  public func contextMenu() {
    events.contextMenu(selection.end > selection.start, !value.isEmpty)
  }

  public func apply(_ choice: HeroMenuChoice) {
    let units = Array(value.utf16)
    let lo = max(0, min(selection.start, units.count))
    let hi = max(lo, min(selection.end, units.count))
    let picked = String(decoding: units[lo..<hi], as: UTF16.self)
    switch choice {
    case .copy:
      events.copy(picked)
    case .cut, .paste:
      if choice == .cut { events.copy(picked) }
      let insert = choice == .paste ? sanitizePaste(events.readClipboard()) : ""
      let next = String(decoding: units[..<lo], as: UTF16.self) + insert + String(decoding: units[hi...], as: UTF16.self)
      clearFill()
      typed = next
      shown = ""
      edited = true
      suppressCompletion = true
      selected = 0
      let caret = lo + insert.utf16.count
      selection = .caret(caret)
      update()
    case .selectAll:
      selection = TextSelection(start: 0, end: units.count)
      field?.show(value: value, selection: selection)
    }
    field?.focusField()
  }

  public func reset() {
    clearFill()
    typed = ""
    shown = ""
    edited = false
    scope = nil
    selected = noneSelected
    suppressCompletion = true
    selection = .caret(0)
    update()
  }

  func dismiss() {
    invalidateQueryProbe()
    if hero { reset() } else { events.done(nil) }
  }

  func go(_ url: String, _ disposition: Disposition = .current) {
    guard !url.isEmpty else { return }
    if disposition == .current { events.journey(.navigate) }
    events.open(url, disposition)
    if disposition != .current { dismiss() } else if !hero { field?.releaseFocus() }
  }

  func choose(_ s: SolaraOmnibox.Suggestion?, _ disposition: Disposition, byEnter: Bool) {
    invalidateQueryProbe()
    if byEnter, let filled, s.flatMap(OmniboxFill.text(for:)) != filled {
      events.chosen(nil)
      return go(resolveInput(filled, search: engine.url), disposition)
    }
    if s != nil || scope == nil { events.chosen(s) }
    let typedSearch: Bool = {
      guard let s else { return true }
      guard byEnter, selectedIndex == 0, case .search(_, _, _, let suggested, let bang) = s else { return false }
      return !bang && !suggested
    }()
    let text = value
    if scope == nil && typedSearch && mayBeBang(text) {
      let fallback: String
      if case .search(_, let url, _, _, _)? = s { fallback = url } else { fallback = resolveInput(text, search: engine.url) }
      go(findBang(text, bangs())?.url ?? fallback, disposition)
      return
    }
    guard let s else {
      if scope != nil { return }
      return go(resolveInput(text, search: engine.url), disposition)
    }
    switch s {
    case .page(let url, _, _, let tabId, _, _):
      if let tabId, !tabId.isEmpty, !(opensTab && disposition == .newTab) {
        events.switchTo(tabId, url, disposition)
        if hero && disposition == .current { reset() }
        if !hero && disposition == .current { field?.releaseFocus() }
        return
      }
      go(url, disposition)
    case .search(_, let url, _, _, _), .create(_, _, let url, _):
      go(url, disposition)
    case .calc(_, let result, let url):
      if disposition != .current { return go(url, disposition) }
      events.copy(result)
      clearFill()
      typed = result
      shown = ""
      suppressCompletion = true
      selection = TextSelection(start: 0, end: result.utf16.count)
      update()
    case .action(let id, _, _, _):
      dismiss()
      events.runAction(id)
    case .extension:
      dismiss()
      events.runExtension(s)
    }
  }

  func mayBeBang(_ text: String) -> Bool {
    let trimmed = jsTrim(text)
    guard trimmed.contains("!"), !trimmed.hasPrefix("?") else { return false }
    let words = trimmed.split(whereSeparator: { $0.isWhitespace }).map(String.init)
    guard let first = words.first, let last = words.last else { return false }
    return matchesBangWord(first) || matchesBangWord(last)
  }

  private func matchesBangWord(_ word: String) -> Bool {
    HeroBarModel.bangWord.firstMatch(in: word, range: NSRange(location: 0, length: word.utf16.count)) != nil
  }

  func forceSearch() {
    let text = jsTrim(filled ?? typed)
    guard !text.isEmpty else { return }
    go(scope.map { scopedSearchUrl($0, text, engine) } ?? searchUrl(engine, text))
  }

  func enterScope(_ next: SearchScope, from: String) {
    clearFill()
    scopeFrom = from
    scope = next
    typed = ""
    shown = ""
    edited = true
    selected = 0
    suppressCompletion = true
    selection = .caret(0)
    update()
  }

  func leaveScope(_ restore: String?) {
    clearFill()
    scope = nil
    if let restore {
      typed = restore
      shown = ""
      edited = true
      selection = .caret(restore.utf16.count)
    }
    selected = 0
    suppressCompletion = true
    update()
  }

  func move(_ delta: Int) {
    let n = items.count
    guard n > 0 else {
      selected = 0
      return
    }
    if selectedIndex < 0 {
      selected = delta > 0 ? 0 : n - 1
    } else {
      selected = (selectedIndex + delta + n) % n
    }
    followHighlight()
  }

  func followHighlight() {
    guard let next = OmniboxFill.shown(selected: selectedIndex, home: home, items: items) else {
      if filled != nil { restoreTyped() }
      return
    }
    if filled == nil { typedSelection = selection }
    filled = next
    filledKey = current.map(suggestionKey)
    selection = .caret(next.utf16.count)
    writeField()
  }

  func restoreTyped() {
    guard filled != nil else { return }
    filled = nil
    filledKey = nil
    selection = typedSelection ?? .caret(value.utf16.count)
    typedSelection = nil
    writeField()
  }

  func clearFill() {
    filled = nil
    filledKey = nil
    typedSelection = nil
  }

  func scopeSources() -> ScopeSources {
    ScopeSources(engines: searchEngines(settings()), hosts: sources.knownHosts(profileId))
  }

  func keywordScope(_ text: String) -> SearchScope? {
    var bare = jsTrim(text)
    if let r = bare.range(of: "^[a-zA-Z]+://", options: .regularExpression) { bare.removeSubrange(r) }
    if bare.hasSuffix("/") { bare.removeLast() }
    if bare.rangeOfCharacter(from: CharacterSet(charactersIn: "/?#:@")) != nil { return nil }
    guard let found = findScope(text, scopeSources()) else { return nil }
    if bare.contains(".") { return found }
    guard found.kind == .engine else { return nil }
    let engine = searchEngines(settings()).first { $0.id == found.engineId }
    return engine.map { $0.keyword.lowercased() == text.lowercased() } == true ? found : nil
  }

  private var active: Bool { edited || scope != nil }

  private func update() {
    recompute()
    writeField()
    if !items.isEmpty { events.journey(.suggestions) }
    if let keyAt {
      self.keyAt = nil
      events.keyShown()
      if events.queryJourney != nil {
        publishQueryProbe(keyAt)
      } else {
        HeroBarModel.afterNextCommit { [events] in
          let elapsed = ContinuousClock.now - keyAt
          events.latency(Double(elapsed.components.seconds) * 1000 + Double(elapsed.components.attoseconds) / 1e15)
        }
      }
    }
  }

  public func invalidateQueryProbe() {
    guard let journey = events.queryJourney else { return }
    if let queryEpoch { journey(.queryInvalidated, tabId, typed, "\(queryEpoch):\(queryGeneration)", nil) }
    queryGeneration += 1
  }

  private func publishQueryProbe(_ keyAt: ContinuousClock.Instant) {
    guard let journey = events.queryJourney else { return }
    if queryEpoch == nil { queryEpoch = UUID().uuidString }
    let generation = queryGeneration
    let identity = "\(queryEpoch!):\(generation)"
    let query = typed
    journey(.keystroke, tabId, query, identity, nil)
    guard !items.isEmpty else { return }
    let committed: @MainActor () -> Void = { [weak self] in
      guard let self, self.queryGeneration == generation, self.typed == query else { return }
      let elapsed = ContinuousClock.now - keyAt
      journey(.suggestions, self.tabId, query, identity, Double(elapsed.components.seconds) * 1000 + Double(elapsed.components.attoseconds) / 1e15)
    }
    if let schedule = events.queryCommit { schedule(committed) } else { HeroBarModel.afterNextCommit(committed) }
  }

  private func recompute() {
    invalidateQueryProbe()
    sourcesSeen = sources.revision
    let query = jsTrim(typed)
    requestRemote(query)
    guard active, !query.isEmpty else {
      if idle { _ = items }
      result = SuggestionResult(items: [], completion: "")
      shown = ""
      refollowHighlight()
      return
    }
    let s = settings()
    let table = scope == nil && query.contains("!") ? bangs() : nil
    if table != nil, let bangStore, !requestedBangRefresh {
      requestedBangRefresh = true
      Task { [weak bangStore] in _ = await bangStore?.refreshOnce() }
    }
    let options = SuggestOptions(
      now: now(),
      engine: defaultSearchEngine(s),
      preference: SearchPreference(rawValue: s.string("commandBarPreference") ?? "") ?? .website,
      remote: remoteList(query),
      actions: sources.actions(windowId),
      extensions: sources.extensions(windowId),
      currentTabId: tabId,
      currentUrl: currentUrl.isEmpty ? nil : currentUrl,
      scope: scope,
      preventInline: suppressCompletion,
      bangs: table)
    result = sources.index(profileId).suggest(typed, tabs: sources.tabs(profileId), options: options)
    shown = suppressCompletion || scope != nil ? "" : result.completion
    refollowHighlight()
  }

  private func refollowHighlight() {
    guard let key = filledKey else { return }
    if let at = items.firstIndex(where: { suggestionKey($0) == key }) {
      selected = at
    } else if let next = OmniboxFill.shown(selected: selectedIndex, home: home, items: items) {
      filled = next
      filledKey = current.map(suggestionKey)
      selection = .caret(next.utf16.count)
    } else {
      filled = nil
      filledKey = nil
      selection = typedSelection ?? .caret((typed + shown).utf16.count)
      typedSelection = nil
    }
  }

  private func writeField() {
    let full = value
    if filled == nil && !shown.isEmpty { selection = TextSelection(start: typed.utf16.count, end: full.utf16.count) }
    let length = full.utf16.count
    selection = TextSelection(start: min(selection.start, length), end: min(selection.end, length))
    field?.show(value: full, selection: selection)
    announceChange()
  }

  private func remoteList(_ query: String) -> [String] {
    if remote.text == query { return remote.list }
    let q = query.lowercased()
    if remote.text.isEmpty || !q.hasPrefix(remote.text.lowercased()) { return [] }
    return remote.list.filter { $0.lowercased().hasPrefix(q) }
  }

  private func requestRemote(_ query: String) {
    guard let fetcher else { return }
    var q = query
    if q.hasPrefix("?") { q.removeFirst() }
    q = jsTrim(q)
    let s = settings()
    let table = active && scope == nil && query.contains("!") ? bangs() : nil
    let blocked = !active || !s.bool("searchSuggestions") || q.isEmpty || (table.map { findBang(query, $0) != nil } ?? false)
      || q.range(of: "^[a-zA-Z][a-zA-Z0-9+.-]*://", options: .regularExpression) != nil || scope?.kind == .history
    if blocked {
      if fetching != nil { fetcher.cancel() }
      fetching = nil
      return
    }
    let engine = scope?.kind == .engine ? engineById(searchEngines(s), scope?.engineId) : defaultSearchEngine(s)
    let key = "\(engine.id)\u{1}\(q)"
    if fetching == key { return }
    fetching = key
    fetcher.request(engine, q) { [weak self, weak fetcher] list in
        Task { @MainActor in
        guard let self, let fetcher, self.fetcher === fetcher, self.fetching == key else { return }
        self.remote = (query, list)
        self.recompute()
        self.writeField()
      }
    }
  }
}

func jsTrim(_ s: String) -> String {
  s.trimmingCharacters(in: .whitespacesAndNewlines.union(CharacterSet(charactersIn: "\u{FEFF}\u{00A0}")))
}

extension HeroBarModel {
  public func driverType(_ text: String) {
    let before = selection
    let after = TextSelection.caret(text.utf16.count)
    selection = after
    field?.show(value: text, selection: after)
    textChanged(text, edit: EditContext(before: before, after: after))
  }

  @discardableResult
  public func driverKey(_ key: String, _ mods: [String: Bool]) -> Bool {
    let names: [String: HeroKey.Name] = [
      "Escape": .escape, "ArrowUp": .arrowUp, "ArrowDown": .arrowDown, "PageUp": .pageUp, "PageDown": .pageDown, "Tab": .tab, "Backspace": .backspace,
      "Delete": .delete, "Enter": .enter,
    ]
    let ctrl = mods["ctrlKey"] ?? false
    if ctrl && key == "n" { return self.key(HeroKey(.arrowDown, ctrl: true)) }
    if ctrl && key == "p" { return self.key(HeroKey(.arrowUp, ctrl: true)) }
    guard let name = names[key] else { return false }
    return self.key(HeroKey(name, shift: mods["shiftKey"] ?? false, alt: mods["altKey"] ?? false, meta: mods["metaKey"] ?? false, ctrl: ctrl))
  }
}

extension HeroBarModel {
  static let recentInDropdown = 4

  func dropdownStart() -> [SolaraOmnibox.Suggestion] {
    let current = sources.tabs(profileId).first { $0.id == tabId }
    let url = current?.url ?? currentUrl
    var seen = Set(url.isEmpty ? [] : [HeroBarModel.pageKey(url)])
    var out: [SolaraOmnibox.Suggestion] = []
    if !url.isEmpty { out.append(.page(url: url, title: current?.title ?? "", favicon: current?.favicon)) }
    for h in sources.history(profileId).sorted(by: { $0.lastVisit > $1.lastVisit }) {
      let key = HeroBarModel.pageKey(h.url)
      guard seen.insert(key).inserted else { continue }
      out.append(.page(url: h.url, title: h.title, favicon: h.favicon, visited: true))
      if out.count == HeroBarModel.recentInDropdown + (url.isEmpty ? 0 : 1) { break }
    }
    return out
  }

  static func pageKey(_ url: String) -> String {
    guard let hash = url.firstIndex(of: "#") else { return url }
    return String(url[..<hash])
  }
}

extension HeroBarModel {
  func announceChange() {
    guard !changeAnnounced else { return }
    changeAnnounced = true
    DispatchQueue.main.async { [weak self] in
      guard let self else { return }
      self.changeAnnounced = false
      self.events.changed()
    }
  }

  static func afterNextCommit(_ run: @escaping @MainActor () -> Void) {
    let observer = CFRunLoopObserverCreateWithHandler(nil, CFRunLoopActivity.beforeWaiting.rawValue, false, 2_000_001) { observer, _ in
      CFRunLoopRemoveObserver(CFRunLoopGetMain(), observer, .commonModes)
      MainActor.assumeIsolated { run() }
    }
    CFRunLoopAddObserver(CFRunLoopGetMain(), observer, .commonModes)
  }
}
