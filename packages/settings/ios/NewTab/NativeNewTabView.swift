import AppKit
import ExpoModulesCore
import SolaraModel
import SolaraOmnibox
import SolaraStore
import SolaraUI

final class NativeNewTabView: ExpoView {
  private static let live = NSHashTable<NativeNewTabView>.weakObjects()

  static func focusHero(windowId: String, tabId: String) -> Bool {
    guard let view = live.allObjects.first(where: {
      $0.windowId == windowId && $0.tabId == tabId && $0.window != nil && !$0.isHiddenOrHasHiddenAncestor
    }) else { return false }
    view.hero.focusBar()
    return true
  }
  static let events = [
    "onOpen", "onSwitch", "onAction", "onExtension", "onRemoveHistory", "onChosen", "onOpenChip", "onDictate", "onContextMenu", "onJourney",
    "onLatency", "onBarLayout", "onDriverState",
  ]

  let onOpen = EventDispatcher()
  let onSwitch = EventDispatcher()
  let onAction = EventDispatcher()
  let onExtension = EventDispatcher()
  let onRemoveHistory = EventDispatcher()
  let onChosen = EventDispatcher()
  let onOpenChip = EventDispatcher()
  let onDictate = EventDispatcher()
  let onContextMenu = EventDispatcher()
  let onJourney = EventDispatcher()
  let onLatency = EventDispatcher()
  let onBarLayout = EventDispatcher()
  let onDriverState = EventDispatcher()
  var driven = false

  let hero = NewTabHeroView(frame: .zero)
  private lazy var actions = NativeOmniboxActions.controller(view: { [weak self] in self?.hero })
  var windowId = ""
  var tabId = ""
  var profileId = ""
  var themeTokens: [String: String] = [:]
  var dark = false
  var marks: [String: String] = [:]
  private var loadedMarks: [String: String] = [:]

  override var isFlipped: Bool { true }

  required init(appContext: AppContext? = nil) {
    super.init(appContext: appContext)
    Self.live.add(self)
    hero.autoresizingMask = [.width, .height]
    hero.frame = bounds
    hero.settings = { NativeSettingsHandle.model?.settings ?? SolaraModel.Settings(values: [:]) }
    hero.fetcher = NewTabNetwork.fetcher
    hero.bangStore = NativeBangs.shared
    hero.favicons = NewTabNetwork.favicons
    hero.events = makeEvents()
    hero.focusAllowed = { [weak self] in
      guard let self else { return false }
      guard NativeStoreHandle.ownsWorkspace, let state = NativeStoreHandle.store?.state else { return true }
      return state.activeTabId(self.windowId) == self.tabId
    }
    hero.onBarLayout = { [weak self] height, heading in self?.onBarLayout(["height": height, "headingHeight": heading]) }
    addSubview(hero)
  }

  override func hitTest(_ point: NSPoint) -> NSView? {
    let hit = super.hitTest(point)
    return hit === self ? nil : hit
  }

  func propsDidUpdate() {
    if !windowId.isEmpty && !tabId.isEmpty { hero.configure(NewTabIdentity(windowId: windowId, tabId: tabId, profileId: profileId)) }
    hero.theme = NewTabTheme(dark: dark, tokens: themeTokens)
    NativeWorkspaceCommands.newTabViewReady(self)
    if marks != loadedMarks {
      loadedMarks = marks
      hero.markImages = NewTabNetwork.markImages(marks)
    }
  }

  override func viewDidMoveToWindow() {
    super.viewDidMoveToWindow()
    NativeWorkspaceCommands.newTabViewReady(self)
  }

  private func makeEvents() -> HeroBarEvents {
    var e = HeroBarEvents()
    e.edited = { [weak self] text in
      guard let self, !text.isEmpty, let tabId = self.hero.model?.tabId,
        NativeStoreHandle.ownsWorkspace, let store = NativeStoreHandle.store,
        store.state.tabs[tabId]?.newTabPlaceholder == true else { return }
      _ = try? store.dispatch(Command("settleNewTab", [.string(tabId)]), origin: .native)
    }
    e.open = { [weak self] url, disposition in self?.onOpen(["url": url, "disposition": disposition.rawValue, "nativeActions": false]) }
    e.switchTo = { [weak self] tab, url, disposition in self?.onSwitch(["tabId": tab, "url": url, "disposition": disposition.rawValue, "nativeActions": false]) }
    e.runAction = { [weak self] id in self?.onAction(["id": id, "nativeActions": false]) }
    e.runExtension = { [weak self] s in self?.onExtension(["suggestion": NewTabJSON.suggestion(s)]) }
    e.removeHistory = { [weak self] url in self?.onRemoveHistory(["url": url]) }
    e.chosen = { [weak self] s in self?.onChosen(["suggestion": s.map(NewTabJSON.suggestion) ?? NSNull()]) }
    e.openChip = { [weak self] in
      guard let self else { return }
      if self.actions.ownsActions, let model = self.hero.model { NativeOmniboxActions.openChip(model, in: self.hero) }
      else { self.onOpenChip(["nativeActions": false]) }
    }
    e.dictate = { [weak self] in self?.onDictate([:]) }
    e.contextMenu = { [weak self] hasSelection, hasValue in self?.onContextMenu(["hasSelection": hasSelection, "hasValue": hasValue]) }
    e.journey = { [weak self] mark in self?.onJourney(["mark": mark.rawValue]) }
    e.latency = { [weak self] ms in self?.onLatency(["ms": ms]) }
    if FieldTimingMarks.queryProbeEnabled {
      let journey = e.journey
      e.journey = { mark in if mark != .keystroke && mark != .suggestions { journey(mark) } }
      e.latency = { _ in }
      e.queryJourney = { [weak self] mark, tabId, query, generation, ms in
        guard let self else { return }
        if mark == .keystroke { FieldTimingMarks.atPresent("omnibox:\(tabId):\(generation)", "suggest") }
        self.onJourney(["mark": mark.rawValue, "tabId": tabId, "query": query, "generation": generation, "at": Date().timeIntervalSince1970 * 1000])
        if let ms { self.onLatency(["ms": ms, "query": query, "generation": generation]) }
      }
    }
    e.keyShown = { [weak self] in
      guard let self else { return }
      FieldTimingMarks.atPresent("bar:\(self.windowId)", "keyShown")
    }
    e.changed = { [weak self] in
      guard let self, self.driven else { return }
      self.onDriverState(["json": self.driverStateJSON()])
    }
    return actions.decorate(e, model: { [weak self] in self?.hero.model })
  }

  func driverState() -> [String: Any] {
    guard let m = hero.model else { return [:] }
    func sel(_ s: TextSelection) -> [String: Int] { ["start": s.start, "end": s.end] }
    let focused = m.field?.hasFocus ?? false
    let editor = focused ? hero.window?.firstResponder as? NSTextView : nil
    let range = editor?.isFieldEditor == true ? editor?.selectedRange() : nil
    var state: [String: Any] = [
      "observationVersion": 2, "nativeActions": actions.ownsActions, "mounted": hero.window != nil, "fieldAttached": m.field != nil, "listAway": m.listAway,
      "windowId": m.windowId, "tabId": m.tabId, "profileId": m.profileId, "variant": m.variant.rawValue, "opensTab": m.opensTab,
      "focused": focused, "fieldValue": range != nil ? (editor?.string ?? "") as Any : NSNull(),
      "fieldSelection": range.map { ["start": $0.location, "end": $0.location + $0.length] } as Any? ?? NSNull(),
      "typed": m.typed, "value": m.value, "selection": sel(m.selection), "completion": m.shown, "suggested": m.result.completion,
      "preventInline": m.suppressCompletion, "selected": m.items.isEmpty ? -1 : m.selectedIndex, "scope": m.scope.map(NewTabJSON.scope) ?? NSNull(),
      "scopeFrom": m.scopeFrom, "tabScope": m.tabScope.map(NewTabJSON.scope) ?? NSNull(), "items": m.items.map(NewTabJSON.suggestion),
    ]
    #if DEBUG
    state["glass"] = hero.devGlassState
    #endif
    return state
  }

  func driverStateJSON() -> String {
    let data = (try? JSONSerialization.data(withJSONObject: driverState())) ?? Data("{}".utf8)
    return String(decoding: data, as: UTF8.self)
  }

  func measure() -> [String: Double] {
    guard let window else { return [:] }
    let frame = hero.convert(hero.barFrame.insetBy(dx: NewTabLayout.barBorder, dy: NewTabLayout.barBorder), to: nil)
    let height = window.contentView?.bounds.height ?? 0
    return ["x": frame.minX, "y": height - frame.maxY, "width": frame.width, "height": frame.height]
  }
}

@MainActor
enum NewTabNetwork {
  static let fetcher = SuggestFetcher(fetch: SuggestFetcher.urlSession())

  static let favicons = NewTabFavicons { url, favicon, profile, dark in
    return await NativeHistoryCatalog.favicon(page: url, source: favicon, profileId: profile, dark: dark)
  }

  private static var markCache: [String: NSImage] = [:]

  static func markImages(_ uris: [String: String]) -> [MarkLayer.Name: NSImage] {
    var out: [MarkLayer.Name: NSImage] = [:]
    for name in MarkLayer.Name.allCases {
      guard let uri = uris[name.rawValue] else { continue }
      if let cached = markCache[uri] {
        out[name] = cached
        continue
      }
      guard let url = uri.hasPrefix("/") ? URL(fileURLWithPath: uri) : URL(string: uri), let image = loadImage(url) else { continue }
      markCache[uri] = image
      out[name] = image
    }
    return out
  }

  private static func loadImage(_ url: URL) -> NSImage? {
    guard let data = try? Data(contentsOf: url), let image = NSImage(data: data) else { return nil }
    image.size = NSSize(width: NewTabLayout.markSize, height: NewTabLayout.markSize)
    return image
  }
}

enum NewTabJSON {
  static func scope(_ s: SearchScope) -> [String: Any] {
    var out: [String: Any] = ["kind": s.kind.rawValue, "name": s.name, "host": s.host, "url": s.url]
    if let id = s.engineId { out["engineId"] = id }
    return out
  }

  static func suggestion(_ s: Suggestion) -> [String: Any] {
    switch s {
    case .page(let url, let title, let favicon, let tabId, let bookmarked, let visited):
      var out: [String: Any] = ["kind": "page", "url": url, "title": title, "favicon": favicon ?? NSNull()]
      if let tabId { out["tabId"] = tabId }
      if bookmarked { out["bookmarked"] = true }
      if visited { out["visited"] = true }
      return out
    case .search(let query, let url, let engine, let suggested, let bang):
      var out: [String: Any] = ["kind": "search", "query": query, "url": url, "engine": engine]
      if suggested { out["suggested"] = true }
      if bang { out["bang"] = true }
      return out
    case .calc(let expression, let value, let url):
      return ["kind": "calc", "expression": expression, "value": value, "url": url]
    case .action(let id, let title, let icon, let hint):
      var out: [String: Any] = ["kind": "action", "id": id, "title": title]
      if let icon { out["icon"] = icon }
      if let hint { out["hint"] = hint }
      return out
    case .create(let id, let title, let url, let site):
      return ["kind": "create", "id": id, "title": title, "url": url, "site": site]
    case .extension(let id, let title, let icon, let open):
      return ["kind": "extension", "id": id, "title": title, "icon": icon ?? NSNull(), "open": open.rawValue]
    }
  }
}
