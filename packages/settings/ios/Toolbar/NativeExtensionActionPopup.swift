import AppKit
import Foundation
import QuartzCore
import SolaraCore
import SolaraShell
import SolaraStore
import SolaraUI

struct ExtensionActionPopupIntent: Decodable {
  struct Anchor: Decodable {
    let x: Double
    let y: Double
    let width: Double
    let height: Double

    var rect: CGRect { CGRect(x: x, y: y, width: width, height: height) }
    var valid: Bool { [x, y, width, height].allSatisfy(\.isFinite) && width >= 0 && height >= 0 }
  }

  let extensionId: String
  let popupUrl: String
  let profile: String
  let tabId: String?
  let windowId: String
  let anchor: Anchor
  let requiresActive: Bool?
}

struct ExtensionPopupButton: Equatable {
  let owner: ObjectIdentifier
  let id: String
  let tabId: String?
}

@MainActor
enum NativeExtensionActionPopup {
  enum CloseReason: String {
    case replacement, dismissal
  }

  static var emit: ((String, [String: Any]) -> Void)?
  private(set) static var current: ExtensionActionPopupHost?
  private static var installed = false
  private struct PendingOmnibox {
    let button: ExtensionPopupButton
    let token: UUID
    let cancel: () -> Void
  }

  private static var pendingOmnibox: [String: PendingOmnibox] = [:]
  private struct HeldFieldBlur {
    weak var host: NSView?
    weak var fieldContainer: NSView?
    let flush: () -> Void
  }
  private static var heldFieldBlurs: [ObjectIdentifier: HeldFieldBlur] = [:]
  private static weak var dismissedPress: NSEvent?

  static func install() {
    guard !installed else { return }
    installed = true
    OutsidePressPolicy.deferPress = { area, event, cancel in
      guard let omnibox = omnibox(in: area) else { return false }
      return preserveOmniboxForToolbarPress(windowId: omnibox.windowId, event: event, cancel: cancel)
    }
    _ = NotificationCenter.default.addObserver(forName: NSApplication.didResignActiveNotification, object: nil, queue: .main) { _ in
      MainActor.assumeIsolated { close() }
    }
    _ = NSEvent.addLocalMonitorForEvents(matching: .leftMouseUp) { event in
      MainActor.assumeIsolated {
        for windowId in Array(pendingOmnibox.keys) {
          let button = extensionButton(windowId: windowId, event: event)
          if button == nil || button != pendingOmnibox[windowId]?.button {
            cancelPendingOmnibox(windowId: windowId)
          }
        }
      }
      return event
    }
    TabPoolHost.shared.pageEventObservers.append { tabId, name, payload in
      guard let current, current.intent.tabId == tabId, name == "onNavigationChange" else { return }
      if payload["isLoading"] as? Bool == true || payload["url"] as? String != current.sourceURL { close() }
    }
  }

  static func show(_ json: String) -> Bool {
    install()
    guard let data = json.data(using: .utf8), let intent = try? JSONDecoder().decode(ExtensionActionPopupIntent.self, from: data) else { return false }
    guard intent.anchor.valid, let url = URLComponents(string: intent.popupUrl), url.scheme == "chrome-extension",
      url.host == intent.extensionId, let window = ShellDrag.window(intent.windowId), let root = window.contentView,
      window.isVisible, intent.requiresActive != true || (window.isKeyWindow && NSApp.isActive) else {
      cancelPendingOmnibox(windowId: intent.windowId)
      return false
    }
    if let state = NativeStoreHandle.store?.state {
      guard let model = state.windows[intent.windowId], !model.isSmall,
        (state.peeks[intent.windowId]?.tabId ?? state.activeTabId(intent.windowId)) == intent.tabId else {
        cancelPendingOmnibox(windowId: intent.windowId)
        return false
      }
    }
    pendingOmnibox.removeValue(forKey: intent.windowId)
    close(reason: .replacement)
    let host = ExtensionActionPopupHost(intent: intent, window: window, root: root)
    current = host
    emit?("onExtensionPopupChanged", ["windowId": intent.windowId, "extensionId": intent.extensionId, "tabId": intent.tabId as Any? ?? NSNull()])
    host.open()
    return current === host
  }

  static func close(windowId: String? = nil, restoreFocus: Bool = true, focusPage: Bool = false, reason: CloseReason = .dismissal) {
    cancelPendingOmnibox(windowId: windowId)
    guard let host = current, windowId == nil || host.intent.windowId == windowId else { return }
    current = nil
    host.end(restoreFocus: restoreFocus, focusPage: focusPage)
    settleHeldFieldBlurs(window: host.window)
    emit?("onExtensionPopupChanged", ["windowId": host.intent.windowId, "extensionId": NSNull(), "tabId": NSNull(), "reason": reason.rawValue])
  }

  static func anchorsChanged(window: NSWindow?, tabId: String?, anchors: [String: CGRect]) {
    guard let host = current, host.window === window, host.intent.tabId == tabId else { return }
    if let rect = anchors[host.intent.extensionId] ?? anchors["*"] { host.setAnchor(rect) }
  }

  static func preservesOmnibox(windowId: String) -> Bool {
    current?.intent.windowId == windowId || pendingOmnibox[windowId] != nil
  }

  static func preserveOmniboxForToolbarPress(windowId: String, event: NSEvent, cancel: @escaping () -> Void) -> Bool {
    if event === dismissedPress { return true }
    if let host = current, host.intent.windowId == windowId, event.window === host.window { return true }
    guard event.type == .leftMouseDown, let window = ShellDrag.window(windowId), event.window === window,
      let button = extensionButton(windowId: windowId, event: event) else {
      pendingOmnibox.removeValue(forKey: windowId)
      return false
    }
    if current?.intent.windowId != windowId {
      let token = UUID()
      pendingOmnibox[windowId] = PendingOmnibox(button: button, token: token, cancel: cancel)
      DispatchQueue.main.asyncAfter(deadline: .now() + 1) {
        MainActor.assumeIsolated {
          guard pendingOmnibox[windowId]?.token == token else { return }
          cancelPendingOmnibox(windowId: windowId)
        }
      }
    }
    return true
  }

  static func holdFieldBlur(from host: NSView, fieldContainer: NSView, flush: @escaping () -> Void) -> Bool {
    guard let window = fieldContainer.window, let popup = current, popup.window === window else { return false }
    let key = ObjectIdentifier(window)
    heldFieldBlurs.removeValue(forKey: key)?.flush()
    heldFieldBlurs[key] = HeldFieldBlur(host: host, fieldContainer: fieldContainer, flush: flush)
    return true
  }

  static func dropHeldFieldBlur(from host: NSView) {
    for (key, held) in heldFieldBlurs where held.host === host { heldFieldBlurs.removeValue(forKey: key) }
  }

  static func flushHeldFieldBlur(from host: NSView) {
    for (key, held) in heldFieldBlurs where held.host == nil || held.host === host {
      heldFieldBlurs.removeValue(forKey: key)
      held.flush()
    }
  }

  #if DEBUG
  static var heldFieldBlurCount: Int { heldFieldBlurs.count }
  #endif

  private static func settleHeldFieldBlurs(window: NSWindow?) {
    for (key, held) in heldFieldBlurs {
      guard let container = held.fieldContainer ?? held.host, let containerWindow = container.window else {
        heldFieldBlurs.removeValue(forKey: key)
        held.flush()
        continue
      }
      guard containerWindow === window else { continue }
      heldFieldBlurs.removeValue(forKey: key)
      let editor = containerWindow.firstResponder as? NSTextView
      let backInField = editor?.isFieldEditor == true && (editor?.delegate as? NSView)?.isDescendant(of: container) == true
      if !backInField { held.flush() }
    }
  }

  static func omniboxSessionEnded(windowId: String) {
    pendingOmnibox.removeValue(forKey: windowId)
  }

  private static func extensionButton(windowId: String, event: NSEvent) -> ExtensionPopupButton? {
    guard let window = ShellDrag.window(windowId), event.window === window else { return nil }
    return NativeToolbarHostView.extensionButton(event) ?? SidebarAddressBridge.extensionButton(windowId: windowId, event: event)
  }

  static func dismiss(_ event: NSEvent, focusPage: Bool) {
    dismissedPress = event
    close(focusPage: focusPage)
  }

  private static func cancelPendingOmnibox(windowId: String?) {
    let ids = windowId.map { [$0] } ?? Array(pendingOmnibox.keys)
    for id in ids { pendingOmnibox.removeValue(forKey: id)?.cancel() }
  }

  private static func omnibox(in view: NSView) -> NativeOmniboxView? {
    if let omnibox = view as? NativeOmniboxView { return omnibox }
    for child in view.subviews { if let found = omnibox(in: child) { return found } }
    return nil
  }
}

@MainActor
final class ExtensionActionPopupHost: NSObject, SolaraCoreWebViewDelegate {
  let intent: ExtensionActionPopupIntent
  weak var window: NSWindow?
  let sourceURL: String?
  private weak var root: NSView?
  private weak var container: NSView?
  private let surface = ExtensionActionPopupSurface(frame: .zero)
  private var page: SolaraCoreWebView?
  private let focus: ExtensionActionPopupFocus
  private var anchor: CGRect
  private var preferred = CGSize(width: 25, height: 25)
  private var sized = false
  private var appeared = false
  private var focused = false
  private weak var pressedPage: NSView?
  private var measuring = false
  private var ended = false
  private var mouseMonitor: Any?
  private var notifications: [NSObjectProtocol] = []
  private weak var store: Store?
  private var storeListener: Int?
  private let sourceNavigation: Double?

  init(intent: ExtensionActionPopupIntent, window: NSWindow, root: NSView) {
    self.intent = intent
    self.window = window
    self.root = root
    anchor = intent.anchor.rect
    focus = ExtensionActionPopupFocus(window: window, windowId: intent.windowId, tabId: intent.tabId)
    let tab = intent.tabId.flatMap { NativeStoreHandle.store?.state.tabs[$0] }
    sourceURL = tab?.url
    sourceNavigation = tab?.navigation?.seq
    super.init()
  }

  func open() {
    guard let root, let window else { return NativeExtensionActionPopup.close() }
    let container = NativeWindowShell.overlay(intent.windowId) ?? root
    self.container = container
    surface.onResize = { [weak self] in self?.place() }
    surface.autoresizingMask = [.width, .height]
    surface.frame = container.bounds
    let web = SolaraCoreWebView(frame: CGRect(origin: .zero, size: preferred))
    web.standalone = true
    web.extensionHost = "popup"
    web.profile = intent.profile
    web.initialURL = intent.popupUrl
    web.pageBackgroundColor = .white
    web.wantsLayer = true
    web.layer?.cornerRadius = 12
    web.layer?.cornerCurve = .continuous
    web.layer?.masksToBounds = true
    web.autoresizingMask = [.width, .height]
    web.delegate = self
    page = web
    place()
    surface.card.addSubview(web)
    container.addSubview(surface, positioned: .above, relativeTo: nil)
    guard !ended, NativeExtensionActionPopup.current === self else { return }
    mouseMonitor = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown, .otherMouseDown]) { [weak self] event in
      let keep = MainActor.assumeIsolated {
        guard let self else { return true }
        return self.mouseDown(event) != nil
      }
      return keep ? event : nil
    }
    for name in [NSApplication.didResignActiveNotification, NSWindow.didResignKeyNotification, NSWindow.willCloseNotification] {
      let object: Any? = name == NSApplication.didResignActiveNotification ? nil : window
      notifications.append(NotificationCenter.default.addObserver(forName: name, object: object, queue: .main) { [weak self] note in
        let restoreFocus = note.name != NSWindow.willCloseNotification
        MainActor.assumeIsolated {
          guard let self, NativeExtensionActionPopup.current === self else { return }
          NativeExtensionActionPopup.close(restoreFocus: restoreFocus)
        }
      })
    }
    store = NativeStoreHandle.store
    storeListener = store?.subscribe { [weak self] _ in
      DispatchQueue.main.async { self?.validateSource() }
    }
  }

  private func validateSource() {
    guard !ended, let state = store?.state else { return }
    let shown = state.peeks[intent.windowId]?.tabId ?? state.activeTabId(intent.windowId)
    let tab = intent.tabId.flatMap { state.tabs[$0] }
    if state.windows[intent.windowId] == nil || shown != intent.tabId || tab?.url != sourceURL || tab?.navigation?.seq != sourceNavigation {
      NativeExtensionActionPopup.close(windowId: intent.windowId)
    }
  }

  func setAnchor(_ rect: CGRect) {
    anchor = rect
    place()
  }

  private func place() {
    guard let root, let container else { return }
    if let window, let liveAnchor = NativeToolbarHostView.extensionAnchor(window: window, tabId: intent.tabId, extensionId: intent.extensionId) {
      anchor = liveAnchor
    }
    let bounds = CGRect(origin: .zero, size: root.bounds.size)
    let rect = ExtensionPopupGeometry.frame(anchor: anchor, preferred: preferred, bounds: bounds)
    let native = root.isFlipped ? rect : CGRect(x: rect.minX, y: root.bounds.height - rect.maxY, width: rect.width, height: rect.height)
    surface.card.frame = surface.superview == nil ? container.convert(native, from: root) : surface.convert(native, from: root)
    page?.frame = surface.card.bounds
  }

  private func mouseDown(_ event: NSEvent) -> NSEvent? {
    guard !ended else { return event }
    if contains(event) { return event }
    let press = outsidePress(event)
    if case .page(let pressed) = press { pressedPage = pressed }
    NativeExtensionActionPopup.dismiss(event, focusPage: pressedPage != nil)
    if case .passThrough = press { return event }
    return nil
  }

  private enum OutsidePress { case passThrough, chrome, page(NSView) }

  private func outsidePress(_ event: NSEvent) -> OutsidePress {
    guard let window, event.window === window, let root,
      let hit = root.superview?.hitTest(event.locationInWindow) else { return .passThrough }
    for kind: NSWindow.ButtonType in [.closeButton, .miniaturizeButton, .zoomButton] {
      if let button = window.standardWindowButton(kind), hit === button || hit.isDescendant(of: button) { return .passThrough }
    }
    guard root.bounds.contains(root.convert(event.locationInWindow, from: nil)),
      !OutsidePressPolicy.targetsWindowDrag(hit) else { return .passThrough }
    var view: NSView? = hit
    while let current = view {
      if current is SolaraCoreWebView || current is NativePageView || current is NewTabHeroView { return .page(hit) }
      if current is ToolbarView || current is SidebarAddressBarView { return .chrome }
      if current.responds(to: Selector(("nativeID"))), current.value(forKey: "nativeID") as? String == "solara-page-content" { return .page(hit) }
      view = current.superview
    }
    if let shell = NativeWindowShell.host(intent.windowId)?.shell, shell.pageArea.contains(shell.card.convert(event.locationInWindow, from: nil)) {
      return .page(hit)
    }
    return .passThrough
  }

  func contains(_ event: NSEvent) -> Bool {
    event.window === window && surface.card.frame.contains(surface.convert(event.locationInWindow, from: nil))
  }

  func end(restoreFocus: Bool, focusPage: Bool) {
    guard !ended else { return }
    ended = true
    if let mouseMonitor { NSEvent.removeMonitor(mouseMonitor) }
    mouseMonitor = nil
    for token in notifications { NotificationCenter.default.removeObserver(token) }
    notifications.removeAll()
    if let storeListener { store?.unsubscribe(storeListener) }
    storeListener = nil
    store = nil
    let web = page
    page = nil
    web?.delegate = nil
    web?.closeBrowser()
    web?.removeFromSuperview()
    surface.removeFromSuperview()
    if focusPage { focus.focusPage(pressed: pressedPage) } else if restoreFocus { focus.restore() }
  }

  nonisolated func webView(_ web: SolaraCoreWebView, event name: String, payload: [String: Any]) {
    nonisolated(unsafe) let body = payload
    MainActor.assumeIsolated {
      guard !ended, web === page, NativeExtensionActionPopup.current === self else { return }
      switch name {
      case "preferredSize":
        guard let width = body["width"] as? Double, let height = body["height"] as? Double,
          width.isFinite, height.isFinite, width > 0, height > 0 else { return }
        sized = true
        resize(CGSize(width: width, height: height))
      case "navigation":
        guard body["isLoading"] as? Bool == false else { return }
        if !sized, !measuring {
          measuring = true
          measure(web)
        }
        if !focused {
          focused = true
          web.focusPage()
        }
      case "windowClose": NativeExtensionActionPopup.close()
      case "openWindow":
        NativeExtensionActionPopup.emit?("onExtensionPopupOpenWindow", ["windowId": intent.windowId, "profile": intent.profile, "request": body])
        if body["disposition"] as? String != "background" { NativeExtensionActionPopup.close() }
      default: break
      }
    }
  }

  private func resize(_ size: CGSize) {
    preferred = size
    place()
    guard !appeared else { return }
    appeared = true
    surface.card.alphaValue = 1
    let opacity = CABasicAnimation(keyPath: "opacity")
    opacity.fromValue = 0
    opacity.toValue = 1
    let slide = CABasicAnimation(keyPath: "transform.translation.y")
    slide.fromValue = -4
    slide.toValue = 0
    let animation = CAAnimationGroup()
    animation.animations = [opacity, slide]
    animation.duration = 0.15
    animation.timingFunction = CAMediaTimingFunction(controlPoints: 1 / 3, 1, 2 / 3, 1)
    surface.card.layer?.add(animation, forKey: "appear")
  }

  private func measure(_ web: SolaraCoreWebView) {
    web.evaluate(Self.measureScript) { [weak self, weak web] json in
      MainActor.assumeIsolated {
        guard let self, !self.ended, !self.sized, let web, self.page === web,
          let data = json?.data(using: .utf8), let size = try? JSONDecoder().decode(MeasuredSize.self, from: data) else { return }
        guard size.w.isFinite, size.h.isFinite, size.w > 0, size.h > 0 else { return }
        self.resize(CGSize(width: size.w, height: size.h))
        self.measure(web)
      }
    }
  }

  private struct MeasuredSize: Decodable {
    let w: Double
    let h: Double
  }

  private static let measureScript = """
    const measure = () => {
      const d = document.documentElement, b = document.body;
      return { w: Math.ceil(Math.max(d.scrollWidth, b ? b.scrollWidth : 0)), h: Math.ceil(Math.max(d.scrollHeight, b ? b.scrollHeight : 0)) };
    };
    const last = window.__solaraSize, now = measure();
    if (!last || last.w !== now.w || last.h !== now.h) {
      window.__solaraSize = now;
      post("result", JSON.stringify(now));
    } else {
      const ro = new ResizeObserver(() => {
        const m = measure();
        if (m.w === window.__solaraSize.w && m.h === window.__solaraSize.h) return;
        ro.disconnect();
        window.__solaraSize = m;
        post("result", JSON.stringify(m));
      });
      ro.observe(document.documentElement);
      if (document.body) ro.observe(document.body);
    }
    """

  #if DEBUG
  func describe() -> [String: Any] {
    let native = surface.card.convert(surface.card.bounds, to: root)
    let rect = root?.isFlipped == true ? native : CGRect(x: native.minX, y: (root?.bounds.height ?? 0) - native.maxY, width: native.width, height: native.height)
    return ["extensionId": intent.extensionId, "tabId": intent.tabId as Any? ?? NSNull(),
      "frame": Self.rect(rect), "anchor": Self.rect(anchor), "appeared": appeared,
      "browserId": page?.browserId as Any? ?? NSNull()]
  }

  static func rect(_ rect: CGRect) -> [Double] { [rect.minX, rect.minY, rect.width, rect.height] }
  #endif
}

@MainActor
private final class ExtensionActionPopupFocus {
  private weak var window: NSWindow?
  private weak var responder: NSResponder?
  private weak var page: SolaraCoreWebView?
  private let tabId: String?
  private let windowId: String
  private let selection: NSRange?

  init(window: NSWindow, windowId: String, tabId: String?) {
    self.window = window
    self.windowId = windowId
    self.tabId = tabId
    if let editor = window.firstResponder as? NSTextView, editor.isFieldEditor, let field = editor.delegate as? NSResponder {
      responder = field
      selection = editor.selectedRange()
    } else {
      responder = window.firstResponder
      selection = nil
    }
    var view = window.firstResponder as? NSView
    while let current = view {
      if let web = current as? SolaraCoreWebView { page = web; break }
      view = current.superview
    }
    if page == nil, window.firstResponder === window || window.firstResponder == nil, let tabId {
      page = (TabPoolHost.shared.pageView(tabId) as? SolaraCoreWebView) ?? Self.find(tabId, in: window.contentView)
    }
  }

  private static func find(_ tabId: String, in view: NSView?) -> SolaraCoreWebView? {
    guard let view, !view.isHiddenOrHasHiddenAncestor else { return nil }
    if let web = view as? SolaraCoreWebView, web.transferKey == tabId { return web }
    for child in view.subviews { if let found = find(tabId, in: child) { return found } }
    return nil
  }

  func focusPage(pressed: NSView?) {
    guard let window, window.isVisible else { return }
    if let tabId, let shown = (TabPoolHost.shared.pageView(tabId) as? SolaraCoreWebView) ?? Self.find(tabId, in: window.contentView),
      shown.window === window, !shown.isHiddenOrHasHiddenAncestor {
      return focus(shown, in: window)
    }
    var view = pressed
    while let current = view, current.window === window {
      if current.acceptsFirstResponder, window.makeFirstResponder(current) { return }
      view = current.superview
    }
    window.makeFirstResponder(nil)
  }

  func restore() {
    guard let window, window.isVisible else { return }
    if let page, page.window === window, !page.isHiddenOrHasHiddenAncestor { return focus(page, in: window) }
    guard let view = responder as? NSView, view.window === window, !view.isHiddenOrHasHiddenAncestor,
      view.acceptsFirstResponder, window.makeFirstResponder(view) else { return }
    if let selection, let editor = (view as? NSTextField)?.currentEditor() as? NSTextView,
      NSMaxRange(selection) <= (editor.string as NSString).length { editor.setSelectedRange(selection) }
  }

  private func focus(_ page: SolaraCoreWebView, in window: NSWindow) {
    if let state = NativeStoreHandle.store?.state,
      (state.peeks[windowId]?.tabId ?? state.activeTabId(windowId)) != tabId { return }
    if let focus = NativeAppIntegration.preparePageFocus(page) {
      _ = focus { [weak page, weak window] in
        guard let page, let window else { return false }
        return page.window === window && window.isVisible && !page.isHiddenOrHasHiddenAncestor
      }
    } else { page.focusPage() }
  }
}

@MainActor
private final class ExtensionActionPopupSurface: NSView {
  let card = ExtensionActionPopupCard(frame: .zero)
  var onResize: (() -> Void)?

  override var isFlipped: Bool { true }

  override init(frame: NSRect) {
    super.init(frame: frame)
    card.alphaValue = 0
    addSubview(card)
  }

  required init?(coder: NSCoder) { fatalError() }

  override func hitTest(_ point: NSPoint) -> NSView? {
    let hit = super.hitTest(point)
    return hit === self ? nil : hit
  }

  override func setFrameSize(_ size: NSSize) {
    super.setFrameSize(size)
    onResize?()
  }
}

@MainActor
private final class ExtensionActionPopupCard: NSView {
  private let shadowLayer = CALayer()
  private let plate = CALayer()
  private let border = CALayer()

  override var isFlipped: Bool { true }

  override init(frame: NSRect) {
    super.init(frame: frame)
    wantsLayer = true
    layer?.masksToBounds = false
    layer?.addSublayer(shadowLayer)
    layer?.addSublayer(plate)
  }

  required init?(coder: NSCoder) { fatalError() }

  override func setFrameSize(_ size: NSSize) {
    super.setFrameSize(size)
    apply()
  }

  override func viewDidChangeEffectiveAppearance() {
    super.viewDidChangeEffectiveAppearance()
    apply()
  }

  override func layout() {
    super.layout()
    apply()
  }

  private func apply() {
    let dark = effectiveAppearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
    CATransaction.begin()
    CATransaction.setDisableActions(true)
    shadowLayer.frame = bounds
    shadowLayer.shadowColor = NSColor.black.cgColor
    shadowLayer.shadowRadius = 16
    shadowLayer.shadowOpacity = dark ? 0.45 : 0.18
    shadowLayer.shadowOffset = CGSize(width: 0, height: layer?.isGeometryFlipped == true || isFlipped ? 6 : -6)
    shadowLayer.shadowPath = CGPath(roundedRect: bounds, cornerWidth: 12, cornerHeight: 12, transform: nil)
    plate.frame = bounds
    plate.cornerRadius = 12
    plate.cornerCurve = .continuous
    plate.backgroundColor = (dark ? NSColor(srgbRed: 42 / 255, green: 42 / 255, blue: 42 / 255, alpha: 1) : .white).cgColor
    for child in subviews {
      child.wantsLayer = true
      child.layer?.cornerRadius = 12
      child.layer?.cornerCurve = .continuous
      child.layer?.masksToBounds = true
    }
    layer?.addSublayer(border)
    border.frame = bounds
    border.cornerRadius = 12
    border.cornerCurve = .continuous
    border.borderWidth = 0.5
    border.zPosition = 1
    border.borderColor = (dark ? NSColor.white.withAlphaComponent(0.16) : NSColor.black.withAlphaComponent(0.14)).cgColor
    CATransaction.commit()
  }
}

#if DEBUG
@MainActor
enum ExtensionActionPopupRead {
  static func snapshot(windowId: String) -> [String: Any]? {
    guard SolaraCoreTestHooksAllowed() else { return nil }
    let window = ShellDrag.window(windowId)
    let root = window?.contentView
    var out = NativeExtensionActionPopup.current.flatMap { $0.intent.windowId == windowId ? $0.describe() : nil } ?? ["frame": NSNull(), "anchor": NSNull(), "extensionId": NSNull(), "tabId": NSNull()]
    out["window"] = [root?.bounds.width ?? 0, root?.bounds.height ?? 0]
    out["liveViews"] = SolaraCoreWebView.devLiveExtensionViews("popup")
    out["heldFieldBlurs"] = NativeExtensionActionPopup.heldFieldBlurCount
    let responder = window?.firstResponder as? NSView
    var view = responder
    var focusedTabId: String?
    while let current = view {
      if let web = current as? SolaraCoreWebView { focusedTabId = web.transferKey; break }
      view = current.superview
    }
    out["focusedTabId"] = focusedTabId as Any? ?? NSNull()
    out["omniboxFocused"] = (responder as? NSTextView)?.isFieldEditor == true
    return out
  }
}
#endif
