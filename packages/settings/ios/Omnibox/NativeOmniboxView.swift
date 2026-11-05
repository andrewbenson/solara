import AppKit
import SolaraShell
import ExpoModulesCore
import SolaraModel
import SolaraOmnibox
import SolaraStore
import SolaraUI

final class NativeOmniboxView: ExpoView, FocusHandoffDestination {
  static let events = [
    "onOpen", "onSwitch", "onAction", "onExtension", "onRemoveHistory", "onChosen", "onOpenChip", "onDictate", "onContextMenu", "onJourney",
    "onLatency", "onBarLayout", "onDriverState", "onDone", "onCancel", "onSiteControls",
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
  let onDone = EventDispatcher()
  let onCancel = EventDispatcher()
  let onSiteControls = EventDispatcher()

  let bar = OmniboxBarView(frame: .zero)
  var windowId = ""
  var tabId = ""
  var profileId = ""
  var variant = BarVariant.panel
  var opensTab = false
  var initialText = ""
  var themeTokens: [String: String] = [:]
  var dark = false
  var driven = false
  var panelJSON = ""
  private var awaitingOpen = false
  private var host: OmniboxPanelHostView?
  nonisolated(unsafe) static var hosts: [String: WeakOmniboxHost] = [:]

  override var isFlipped: Bool { true }

  required init(appContext: AppContext? = nil) {
    super.init(appContext: appContext)
    bar.autoresizingMask = [.width, .height]
    bar.frame = bounds
    bar.settings = { NativeSettingsHandle.model?.settings ?? SolaraModel.Settings(values: [:]) }
    bar.fetcher = NewTabNetwork.fetcher
    bar.bangStore = NativeBangs.shared
    bar.favicons = NewTabNetwork.favicons
    bar.events = makeEvents()
    bar.onHeight = { [weak self] height in self?.onBarLayout(["height": height]) }
    addSubview(bar)
  }

  override func hitTest(_ point: NSPoint) -> NSView? {
    let hit = super.hitTest(point)
    return host != nil && (hit === self || hit === host) ? nil : hit
  }

  func setPanel(_ json: String) {
    panelJSON = json
    guard !json.isEmpty else { return }
    if host == nil {
      bar.removeFromSuperview()
      let made = OmniboxPanelHostView(bar: bar)
      made.onOutside = { [weak self] event in
        guard let self, !NativeExtensionActionPopup.preserveOmniboxForToolbarPress(windowId: self.windowId, event: event, cancel: { [weak self] in self?.onCancel([:]) }) else { return }
        self.onCancel([:])
      }
      made.onHeight = { [weak self] h in self?.onBarLayout(["height": h]) }
      host = made
      placeHost()
      NotificationCenter.default.addObserver(self, selector: #selector(commandWillDispatch(_:)), name: Notification.Name("SolaraCommandWillDispatch"), object: nil)
    }
  }

  var focusDestination: NSView { host ?? self }

  private func placeHost() {
    guard let host else { return }
    let overlay = window == nil ? nil : NativeWindowShell.overlay(windowId).flatMap { $0.window === window ? $0 : nil }
    let parent = overlay ?? self
    if host.superview !== parent {
      host.hide()
      host.removeFromSuperview()
      parent.addSubview(host)
    }
    host.autoresizingMask = parent === self ? [.width, .height] : []
    let frame = parent === self ? bounds : parent.convert(bounds, from: self)
    if host.frame != frame { host.frame = frame }
  }

  override func viewDidMoveToWindow() {
    super.viewDidMoveToWindow()
    placeHost()
  }

  override func layout() {
    super.layout()
    placeHost()
  }

  @objc private func commandWillDispatch(_ note: Notification) {
    MainActor.assumeIsolated {
      guard note.userInfo?["command"] as? String == "focusCommandBar", let window, note.object as? NSWindow === window,
        let host, !host.shown, let panel = NativeOmniboxPanel.decode(panelJSON), panel.ready, !panel.tabId.isEmpty
      else { return }
      awaitingOpen = true
      open(panel, in: host)
      DispatchQueue.main.async {
        window.displayIfNeeded()
        CATransaction.flush()
      }
      DispatchQueue.main.asyncAfter(deadline: .now() + 2) { [weak self] in
        MainActor.assumeIsolated {
          guard let self, self.awaitingOpen else { return }
          self.awaitingOpen = false
          self.host?.hide()
        }
      }
    }
  }

  func showPanel(_ json: String) {
    guard let host, let panel = NativeOmniboxPanel.decode(json) else { return }
    host.style = panel.style
    if panel.tabId.isEmpty { return host.hide() }
    if !panel.open {
      if awaitingOpen { return }
      host.hide()
      return host.prepare(panel.placement, identity: identity(of: panel))
    }
    awaitingOpen = false
    open(panel, in: host)
  }

  private func identity(of panel: NativeOmniboxPanel) -> OmniboxBarIdentity {
    OmniboxBarIdentity(windowId: windowId, tabId: panel.tabId, profileId: profileId, variant: panel.variant, opensTab: false, initialText: panel.text)
  }

  private func open(_ panel: NativeOmniboxPanel, in host: OmniboxPanelHostView) {
    let next = identity(of: panel)
    let fresh = !host.shown || host.identity != next
    host.show(panel.placement, identity: next)
    guard fresh else { return }
    if driven { DispatchQueue.main.async { [weak self] in if let self, self.driven { self.onDriverState(["json": self.driverStateJSON()]) } } }
    FieldTimingMarks.now("panel", "configured")
    FieldTimingMarks.atPresent("panel", "content")
  }

  func propsDidUpdate() {
    bar.theme = NewTabTheme(dark: dark, tokens: themeTokens)
    if host != nil {
      placeHost()
      if !windowId.isEmpty { NativeOmniboxView.hosts[windowId] = WeakOmniboxHost(view: self) }
      return showPanel(panelJSON)
    }
    if !windowId.isEmpty && !tabId.isEmpty {
      let before = bar.model
      bar.configure(OmniboxBarIdentity(windowId: windowId, tabId: tabId, profileId: profileId, variant: variant, opensTab: opensTab, initialText: initialText))
      if variant == .panel, bar.model !== before {
        FieldTimingMarks.now("panel", "configured")
        FieldTimingMarks.atPresent("panel", "content")
      }
      if driven { DispatchQueue.main.async { [weak self] in if let self, self.driven { self.onDriverState(["json": self.driverStateJSON()]) } } }
    }
  }

  private func makeEvents() -> HeroBarEvents {
    var e = HeroBarEvents()
    e.open = { [weak self] url, disposition in self?.onOpen(["url": url, "disposition": disposition.rawValue]) }
    e.switchTo = { [weak self] tab, url, disposition in self?.onSwitch(["tabId": tab, "url": url, "disposition": disposition.rawValue]) }
    e.runAction = { [weak self] id in self?.onAction(["id": id]) }
    e.runExtension = { [weak self] s in self?.onExtension(["suggestion": NewTabJSON.suggestion(s)]) }
    e.removeHistory = { [weak self] url in self?.onRemoveHistory(["url": url]) }
    e.chosen = { [weak self] s in self?.onChosen(["suggestion": s.map(NewTabJSON.suggestion) ?? NSNull()]) }
    e.openChip = { [weak self] in self?.onOpenChip([:]) }
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
    e.done = { [weak self] reason in
      guard let self else { return }
      NativeExtensionActionPopup.omniboxSessionEnded(windowId: self.windowId)
      self.onDone(["reason": reason?.rawValue ?? NSNull()])
    }
    e.cancel = { [weak self] session in
      guard let self, self.bar.model?.editingSession == session else { return }
      let preserved = NativeExtensionActionPopup.preservesOmnibox(windowId: self.windowId)
      NativeExtensionActionPopup.omniboxSessionEnded(windowId: self.windowId)
      if !preserved { self.onCancel([:]) }
    }
    e.siteControls = { [weak self] in self?.onSiteControls([:]) }
    e.changed = { [weak self] in
      guard let self, self.driven else { return }
      self.onDriverState(["json": self.driverStateJSON()])
    }
    return e
  }

  func driverStateJSON() -> String {
    guard let m = bar.model else { return "{}" }
    func sel(_ s: TextSelection) -> [String: Int] { ["start": s.start, "end": s.end] }
    let focused = m.field?.hasFocus ?? false
    let editor = focused ? bar.window?.firstResponder as? NSTextView : nil
    let range = editor?.isFieldEditor == true ? editor?.selectedRange() : nil
    let state: [String: Any] = [
      "observationVersion": 2, "mounted": bar.window != nil, "fieldAttached": m.field != nil, "listAway": m.listAway,
      "windowId": m.windowId, "tabId": m.tabId, "profileId": m.profileId, "variant": m.variant.rawValue, "opensTab": m.opensTab,
      "focused": focused, "fieldValue": range != nil ? (editor?.string ?? "") as Any : NSNull(),
      "fieldSelection": range.map { ["start": $0.location, "end": $0.location + $0.length] } as Any? ?? NSNull(),
      "typed": m.typed, "value": m.value, "selection": sel(m.selection), "completion": m.shown, "suggested": m.result.completion,
      "preventInline": m.suppressCompletion, "selected": m.selectedIndex, "scope": m.scope.map(NewTabJSON.scope) ?? NSNull(),
      "scopeFrom": m.scopeFrom, "tabScope": m.tabScope.map(NewTabJSON.scope) ?? NSNull(), "items": m.items.map(NewTabJSON.suggestion),
    ]
    let data = (try? JSONSerialization.data(withJSONObject: state)) ?? Data("{}".utf8)
    return String(decoding: data, as: UTF8.self)
  }

  func measure() -> [String: Double] {
    guard let window else { return [:] }
    let frame = convert(bounds, to: nil)
    let height = window.contentView?.bounds.height ?? 0
    return ["x": frame.minX, "y": height - frame.maxY, "width": frame.width, "height": frame.height]
  }
}

#if SOLARA_PROBES
public enum OmniboxRead {
  @MainActor public static func focusedURL(windowId: String) -> [String: Any]? {
    guard let view = NativeOmniboxView.hosts[windowId]?.view,
      view.bar.model?.field?.hasFocus == true,
      let editor = view.window?.firstResponder as? NSTextView, editor.isFieldEditor else { return nil }
    let selection = editor.selectedRange()
    return ["field": "url", "value": editor.string,
      "selection": ["start": selection.location, "end": selection.location + selection.length]]
  }

  @MainActor public static func bar(windowId: String) -> [String: Any]? {
    let anchor = NativeOmniboxView.hosts[windowId]?.view
    let views = NSApp.windows.flatMap { window in window.contentView.map(omniboxViews) ?? [] }
      .filter { $0.windowId == windowId && $0.bar.model != nil }
    let presented = views.filter { $0 !== anchor && $0.window?.isVisible == true && !$0.isHiddenOrHasHiddenAncestor }
    let chosen = presented.first { $0.bar.model?.field?.hasFocus == true } ?? presented.first
    let source = chosen != nil ? "panel" : "anchor"
    guard let view = chosen ?? anchor.flatMap({ $0.bar.model != nil ? $0 : nil }),
      var state = (try? JSONSerialization.jsonObject(with: Data(view.driverStateJSON().utf8))) as? [String: Any]
    else { return nil }
    state["source"] = source
    return state
  }

  @MainActor private static func omniboxViews(_ root: NSView) -> [NativeOmniboxView] {
    var found: [NativeOmniboxView] = []
    var stack = [root]
    while let view = stack.popLast() {
      if let omnibox = view as? NativeOmniboxView { found.append(omnibox) }
      stack.append(contentsOf: view.subviews)
    }
    return found
  }
}
#endif

enum FieldTimingMarks {
  static let queryProbeEnabled: Bool = {
    let env = ProcessInfo.processInfo.environment
    return env["SOLARA_BACKGROUND"] == "1" && env["SOLARA_DATA_DIR"]?.isEmpty == false && env["AC_BENCH_OMNIBOX"] == "1"
  }()

  static func now(_ key: String, _ kind: String) {
    NotificationCenter.default.post(name: Notification.Name("ACFieldMarkAtPresent"), object: [key, kind, "now"] as NSArray)
  }

  static func atPresent(_ key: String, _ kind: String) {
    NotificationCenter.default.post(name: Notification.Name("ACFieldMarkAtPresent"), object: [key, kind] as NSArray)
  }
}

final class WeakOmniboxHost {
  weak var view: NativeOmniboxView?
  init(view: NativeOmniboxView) { self.view = view }
}

struct NativeOmniboxPanel {
  var open: Bool
  var ready: Bool
  var tabId: String
  var text: String
  var placement: OmniboxPanelPlacement
  var style: OmniboxPanelStyle
  var variant: BarVariant

  static func decode(_ json: String) -> NativeOmniboxPanel? {
    guard let data = json.data(using: .utf8), let o = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
    func num(_ v: Any?) -> CGFloat { CGFloat((v as? NSNumber)?.doubleValue ?? 0) }
    let from = (o["from"] as? [String: Any]).map { CGRect(x: num($0["left"]), y: num($0["top"]), width: num($0["width"]), height: num($0["height"])) }
    let style = OmniboxPanelStyle(
      fill: CSSColor(o["fill"] as? String ?? "#FFFFFF") ?? CSSColor("#FFFFFF")!, border: CSSColor(o["border"] as? String ?? "") ?? CSSColor("rgba(0,0,0,0.1)")!,
      shadowOpacity: (o["shadowOpacity"] as? NSNumber)?.doubleValue ?? 0.2, radius: num(o["radius"] ?? 17))
    return NativeOmniboxPanel(
      open: o["open"] as? Bool ?? false, ready: o["ready"] as? Bool ?? false, tabId: o["tabId"] as? String ?? "", text: o["text"] as? String ?? "",
      placement: OmniboxPanelPlacement(left: num(o["left"]), top: num(o["top"]), width: num(o["width"]), from: from), style: style,
      variant: (o["variant"] as? String).flatMap(BarVariant.init(rawValue:)) ?? .panel)
  }
}
