#if DEBUG
import AppKit
import SwiftUI

@MainActor
private final class SyncPairingDisplayService: TrustedPairingService {
  let surface = TrustedSurface()
  let request = TrustedRequest(chainSuffix: "F100", requestSuffix: "F200", sessionSuffix: "F300", firstObserved: TrustedPairingClock.now())
  var claimedName = "Fixture Studio"
  var warning = false
  var visible = true
  var allowRequests = 0
  private var revision: UInt64 = 1
  private var observers: [UUID: (TrustedSurface?, @MainActor (TrustedSnapshot) -> Void)] = [:]
  private var currentArm: TrustedArm?
  private var phase: TrustedPhase = .idle
  private var selected = false
  private var ready = false
  private var admitted = true
  private var comparison: TrustedComparison?
  private var authorization: TrustedAuthorization?

  func observe(on surface: TrustedSurface?, _ receive: @escaping @MainActor (TrustedSnapshot) -> Void) -> TrustedSubscription {
    let id = UUID()
    observers[id] = (surface, receive)
    receive(snapshot(for: surface))
    return TrustedSubscription { [weak self] in self?.observers[id] = nil }
  }

  func attach(to settingsWindow: NSWindow) -> TrustedSurface { surface }

  func arm(on surface: TrustedSurface, reviewing: TrustedRequest?, options: TrustedArmOptions) throws -> TrustedArm {
    guard surface === self.surface, currentArm == nil else { throw FixtureError.refused }
    let made = TrustedArm(deadline: TrustedPairingClock.now() + 120)
    currentArm = made
    phase = .choosing
    admitted = true
    return made
  }

  func select(_ request: TrustedRequest, in arm: TrustedArm) async throws {
    guard request === self.request, arm === currentArm, !selected else { throw FixtureError.refused }
    selected = true
    phase = .preparing
    publish()
  }

  func present(_ arm: TrustedArm, on surface: TrustedSurface) throws {
    guard surface === self.surface, arm === currentArm, visible,
      TrustedPairingClock.now() < arm.deadline else { throw FixtureError.refused }
    admitted = true
    authorization = nil
    comparison = nil
    if ready && selected { makeComparison() }
    publish()
  }

  func surfaceChanged(_ surface: TrustedSurface, event: TrustedSurfaceEvent) {
    guard surface === self.surface else { return }
    authorization = nil
    comparison = nil
    admitted = false
    if event == .removed {
      currentArm = nil
      phase = .ended(.removed)
    }
    publish()
  }

  func acknowledge(_ comparison: TrustedComparison, matched: Bool, on surface: TrustedSurface) -> TrustedAuthorization? {
    guard surface === self.surface, comparison === self.comparison, admitted, visible, phase == .comparing else { return nil }
    authorization = matched ? TrustedAuthorization() : nil
    return authorization
  }

  func allow(_ authorization: TrustedAuthorization, on surface: TrustedSurface) async throws {
    guard surface === self.surface, authorization === self.authorization, visible, admitted, phase == .comparing,
      let currentArm, TrustedPairingClock.now() < currentArm.deadline else { throw FixtureError.refused }
    self.authorization = nil
    allowRequests += 1
    phase = .authenticating
    publish()
  }

  func end(_ arm: TrustedArm?, on surface: TrustedSurface, disposition: TrustedEnd) {
    guard surface === self.surface, arm == nil || arm === currentArm else { return }
    authorization = nil
    comparison = nil
    currentArm = nil
    admitted = false
    phase = .ended(disposition == .unexpectedRequest ? .unexpectedRequest : .cancelled)
    publish()
  }

  func finishPreparation() {
    guard selected, currentArm != nil, phase == .preparing || phase == .comparing else { return }
    ready = true
    phase = .comparing
    if visible && admitted && comparison == nil { makeComparison() }
    publish()
  }

  private func makeComparison() {
    guard let currentArm else { return }
    comparison = TrustedComparison(arm: currentArm, surface: surface, presentation: TrustedPresentation(), code: "ABCD23", claimedName: claimedName, nameWarning: warning)
  }

  func publish() {
    revision += 1
    for (surface, receive) in observers.values { receive(snapshot(for: surface)) }
  }

  private func snapshot(for surface: TrustedSurface?) -> TrustedSnapshot {
    let local = surface === self.surface
    return TrustedSnapshot(revision: revision, eligible: true, openMarkerVerified: true, requests: [request], arm: local ? currentArm : nil, phase: local ? phase : .idle, foreground: local && visible && admitted, comparison: local && visible && admitted ? comparison : nil)
  }

  private enum FixtureError: Error { case refused }
}

@MainActor
private struct SyncPairingFixtureAccessibility {
  let object: NSObject

  private func value(_ name: String) -> Any? {
    let selector = NSSelectorFromString(name)
    guard object.responds(to: selector) else { return nil }
    return object.perform(selector)?.takeUnretainedValue()
  }

  var children: [Any] { value("accessibilityChildren") as? [Any] ?? [] }
  var strings: [String] {
    ["accessibilityLabel", "accessibilityTitle", "accessibilityValue"].compactMap { value($0) as? String }
  }

  func press() -> Bool {
    if let accessible = object as? any NSAccessibilityProtocol { return accessible.accessibilityPerformPress() }
    let selector = NSSelectorFromString("accessibilityPerformPress")
    guard object.responds(to: selector) else { return false }
    typealias Press = @convention(c) (AnyObject, Selector) -> Bool
    return unsafeBitCast(object.method(for: selector), to: Press.self)(object, selector)
  }
}

@MainActor
final class SyncPairingDisplayFixture: SyncPairingFixtureSession {
  private let service = SyncPairingDisplayService()
  private let model: SyncTrustedPairingModel
  private weak var settings: NSWindow?
  private let panel: NSPanel
  private let dataDirectory: URL
  private var savedTarget: (() -> Void)?
  private var destroyed = false
  private var inspectionRequested = false
  private static var accessibilityUsers = 0
  private static var previousEnhancedAccessibility: Any?

  init(settings: NSWindow, dataDirectory: String) {
    if Self.accessibilityUsers == 0 {
      Self.previousEnhancedAccessibility = NSApp.accessibilityAttributeValue(NSAccessibility.Attribute(rawValue: "AXEnhancedUserInterface"))
      NSApp.accessibilitySetValue(true, forAttribute: NSAccessibility.Attribute(rawValue: "AXEnhancedUserInterface"))
    }
    Self.accessibilityUsers += 1
    self.settings = settings
    self.dataDirectory = URL(fileURLWithPath: dataDirectory, isDirectory: true).resolvingSymlinksInPath()
    model = SyncTrustedPairingModel(service: service)
    panel = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 540, height: 640), styleMask: [.titled, .nonactivatingPanel], backing: .buffered, defer: false)
    panel.isReleasedWhenClosed = false
    panel.identifier = NSUserInterfaceItemIdentifier("sync-pairing-sensitive")
    panel.title = "Pairing display fixture"
    panel.contentView = NSHostingView(rootView: SyncTrustedPairingSheet(model: model))
    settings.beginSheet(panel)
    panel.contentView?.layoutSubtreeIfNeeded()
    model.attach(to: settings)
    model.connect()
    service.publish()
  }

  func drive(_ action: String, argument: String?) -> [String: Any] {
    guard !destroyed else { return ["error": "no mounted fixture", "actionControlFound": false] }
    layout()
    var control = "fixture content"
    switch action {
    case "select":
      control = "request"
      guard let button = buttons().compactMap({ $0 as? SyncRequestNativeButton }).first else { return failure("request") }
      button.performClick(nil)
    case "ready": service.finishPreparation()
    case "check": return setCheckbox(true)
    case "uncheck": return setCheckbox(false)
    case "allow":
      control = "allow"
      guard let button = allowButton() else { return failure(control) }
      button.performClick(nil)
    case "space": return dispatchKey(" ", keyCode: 49)
    case "return": return dispatchKey("\r", keyCode: 36)
    case "enter": return dispatchKey("\u{3}", keyCode: 76)
    case "escape":
      control = "deny"
      guard let button = allowButton(), let window = button.window else { return failure("allow") }
      guard let cancel = accessibilityElements().first(where: { $0.strings.contains("Deny") }) else { return failure(control) }
      guard window.makeFirstResponder(button) else { return failure("allow", reason: "refused first responder", found: true) }
      guard cancel.press() else { return failure(control, reason: "refused input", found: true) }
    case "saveTarget":
      control = "allow"
      guard let button = allowButton() else { return failure(control) }
      savedTarget = button.invoke
    case "pressSaved":
      control = "saved allow target"
      guard let savedTarget else { return failure(control) }
      savedTarget()
    case "inspect":
      control = "inspect"
      if let button = buttons().first(where: { $0.title == "Inspect name characters" }) {
        button.performClick(nil)
      } else {
        guard let inspect = accessibilityElements().first(where: { $0.strings.contains("Inspect name characters") }) else { return failure(control) }
        guard inspect.press() else { return failure(control, reason: "refused input", found: true) }
      }
      inspectionRequested = true
    case "hide":
      service.visible = false
      model.surfaceChanged(.visibilityChanged)
    case "show":
      service.visible = true
      service.publish()
    case "remount": model.surfaceChanged(.remounted)
    case "present":
      control = "review request"
      guard let present = accessibilityElements().first(where: { $0.strings.contains("Review request") }) else { return failure(control) }
      guard present.press() else { return failure(control, reason: "refused input", found: true) }
    case "light": for window in hostingWindows() { window.appearance = NSAppearance(named: .aqua) }
    case "dark": for window in hostingWindows() { window.appearance = NSAppearance(named: .darkAqua) }
    case "longName":
      guard model.comparison == nil else { return failure("name variant", reason: "comparison already presented", found: true) }
      service.claimedName = String(repeating: "é", count: 64)
    case "confusable":
      guard model.comparison == nil else { return failure("name variant", reason: "comparison already presented", found: true) }
      service.claimedName = "Fixture Studiо"
      service.warning = true
    case "snapshot":
      var result = actionState(control)
      result["snapshotSaved"] = snapshot(argument)
      if result["snapshotSaved"] as? Bool != true { result["error"] = "fixture snapshot unavailable" }
      return result
    default: break
    }
    layout()
    return actionState(control)
  }

  private func failure(_ control: String, reason: String = "unavailable", found: Bool = false) -> [String: Any] {
    var result = state()
    result["error"] = "fixture \(control) control \(reason)"
    result["actionControl"] = control
    result["actionControlFound"] = found
    return result
  }

  private func actionState(_ control: String) -> [String: Any] {
    var result = state()
    result["actionControl"] = control
    result["actionControlFound"] = control != "fixture content" || hostedViews().contains { ($0 as? SyncPairingProbeView)?.sensitive == true }
    if result["actionControlFound"] as? Bool != true { result["error"] = "fixture content unavailable" }
    return result
  }

  private func checkboxButton() -> NSButton? {
    buttons().first { $0.identifier?.rawValue == "sync-pairing-matched" || $0.title == "The code matches on my other Mac" }
  }

  private func setCheckbox(_ checked: Bool) -> [String: Any] {
    layout()
    guard let button = checkboxButton() else { return failure("checkbox") }
    if (button.state == .on) != checked { button.performClick(nil) }
    guard (button.state == .on) == checked, model.matched == checked else { return failure("checkbox", reason: "refused input", found: true) }
    return actionState("checkbox")
  }

  private func dispatchKey(_ characters: String, keyCode: UInt16) -> [String: Any] {
    guard let button = allowButton(), let window = button.window else { return failure("allow") }
    guard let event = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: TrustedPairingClock.now(), windowNumber: window.windowNumber, context: nil, characters: characters, charactersIgnoringModifiers: characters, isARepeat: false, keyCode: keyCode) else { return failure("allow", reason: "key event unavailable", found: true) }
    window.defaultButtonCell = button.cell as? NSButtonCell
    guard window.makeFirstResponder(button) else { return failure("allow", reason: "refused first responder", found: true) }
    window.sendEvent(event)
    return actionState("allow")
  }

  private func views(_ root: NSView?) -> [NSView] {
    guard let root else { return [] }
    return [root] + root.subviews.flatMap { views($0) }
  }

  private func hostingWindows() -> [NSWindow] {
    var queue = [panel as NSWindow]
    if let settings { queue.insert(settings, at: 0) }
    var seen = Set<ObjectIdentifier>()
    var result: [NSWindow] = []
    while !queue.isEmpty {
      let window = queue.removeFirst()
      guard seen.insert(ObjectIdentifier(window)).inserted else { continue }
      result.append(window)
      if let sheet = window.attachedSheet { queue.append(sheet) }
      queue += window.sheets
      queue += NSApp.windows.filter { $0.sheetParent === window }
    }
    return result
  }

  private func hostedViews() -> [NSView] { hostingWindows().flatMap { views($0.contentView) } }

  private func layout() {
    for window in hostingWindows() { window.contentView?.layoutSubtreeIfNeeded() }
  }

  private func accessibilityElements() -> [SyncPairingFixtureAccessibility] {
    var queue: [Any] = hostingWindows().flatMap { [$0] + ($0.accessibilityChildren() ?? []) }
    queue += hostedViews()
    var seen = Set<ObjectIdentifier>()
    var result: [SyncPairingFixtureAccessibility] = []
    while !queue.isEmpty, result.count < 10000 {
      let element = queue.removeFirst()
      guard let object = element as? NSObject, seen.insert(ObjectIdentifier(object)).inserted else { continue }
      let accessible = SyncPairingFixtureAccessibility(object: object)
      result.append(accessible)
      queue += accessible.children
    }
    return result
  }

  private func buttons() -> [NSButton] { hostedViews().compactMap { $0 as? NSButton } }
  private func allowButton() -> SyncAllowNativeButton? { buttons().compactMap { $0 as? SyncAllowNativeButton }.first }

  func mountedState() -> [String: Any] { actionState("fixture content") }

  private func state() -> [String: Any] {
    layout()
    let allViews = hostedViews()
    let accessible = accessibilityElements()
    let texts = allViews.compactMap { $0 as? NSTextView }
    let nameView = texts.first { $0.accessibilityIdentifier() == "sync-pairing-claimed-name" && $0.string.contains(service.claimedName) }
    let allow = allowButton()
    let checkbox = checkboxButton()
    let deny = accessible.first { $0.strings.contains("Deny") }
    let inspect = accessible.first { $0.strings.contains("Inspect name characters") }
    let found = ["allow": allow != nil, "checkbox": checkbox != nil, "deny": deny != nil, "inspect": inspect != nil, "name": nameView != nil]
    var nameLayout: [String: Any] = ["found": nameView != nil, "textViews": texts.count]
    var nameReason = model.comparison == nil ? "comparison not presented" : "name view unavailable"
    let complete = nameView.map { text in
      guard let layout = text.layoutManager, let container = text.textContainer else { nameReason = "name layout unavailable"; return false }
      layout.ensureLayout(for: container)
      let used = layout.usedRect(for: container)
      let glyphs = layout.glyphRange(for: container)
      let characters = layout.characterRange(forGlyphRange: glyphs, actualGlyphRange: nil)
      func dimension(_ value: CGFloat) -> Any {
        if value.isFinite { return Double(value) }
        return String(describing: value)
      }
      nameLayout["boundsWidth"] = dimension(text.bounds.width)
      nameLayout["boundsHeight"] = dimension(text.bounds.height)
      nameLayout["containerWidth"] = dimension(container.containerSize.width)
      nameLayout["usedWidth"] = dimension(used.width)
      nameLayout["usedHeight"] = dimension(used.height)
      nameLayout["hidden"] = text.isHiddenOrHasHiddenAncestor
      nameLayout["charactersRendered"] = characters.length
      nameLayout["charactersExpected"] = text.string.utf16.count
      guard characters == NSRange(location: 0, length: text.string.utf16.count), text.bounds.width > 0,
        used.width <= text.bounds.width + 1, used.height <= text.bounds.height + 1 else { nameReason = "name text clipped"; return false }
      guard contained(text) else { nameReason = "name view outside visible content"; return false }
      return true
    } ?? false
    let required = model.comparison != nil ? ["allow", "checkbox", "deny", "inspect", "name"] : ["allow", "deny"]
    let missing = required.filter { found[$0] != true }
    let visible = missing.isEmpty && allow.map(contained) == true
    var strings = allViews.flatMap { view -> [String] in
      [(view as? NSTextView)?.string, (view as? NSTextField)?.stringValue, view.accessibilityLabel(), view.accessibilityValue() as? String].compactMap { $0 }
    }
    strings += accessible.flatMap(\.strings)
    let inspection = inspectionRequested && inspect != nil && nameView != nil && strings.contains { $0.contains(SyncPairingName.characters(service.claimedName)) } && strings.contains { $0.contains(SyncPairingName.escaped(service.claimedName)) }
    var result: [String: Any] = ["fixture": true, "mounted": true, "choosing": model.phase == .choosing, "preparing": model.phase == .preparing,
      "comparisonPresent": model.comparison != nil, "checked": checkbox.map { $0.state == .on && model.matched } ?? false,
      "allowEnabled": allow.map { $0.isEnabled && model.canAllow } ?? false,
      "allowRequests": service.allowRequests, "realAuthenticationRequests": 0, "releaseRequests": 0,
      "nameFullyRendered": complete, "nameLayout": nameLayout, "inspectionComplete": inspection, "controlsVisible": visible,
      "controlsFound": found, "requiredControlsFound": missing.isEmpty, "windows": windowStructure()]
    if !complete { result["nameFullyRenderedReason"] = nameReason }
    if !visible { result["controlsVisibleReason"] = missing.isEmpty ? "controls outside visible content" : "missing controls: " + missing.joined(separator: ", ") }
    if checkbox == nil { result["checkedReason"] = model.comparison == nil ? "comparison not presented" : "checkbox unavailable" }
    if allow == nil { result["allowEnabledReason"] = "allow unavailable" }
    if !inspection { result["inspectionCompleteReason"] = inspect == nil ? "inspect control unavailable" : (nameView == nil ? "name view unavailable" : (inspectionRequested ? "inspection text unavailable" : "inspection not requested")) }
    return result
  }

  private func contained(_ view: NSView) -> Bool {
    guard let root = view.window?.contentView, !view.isHiddenOrHasHiddenAncestor,
      view.bounds.width > 0, view.bounds.height > 0, root.bounds.contains(view.convert(view.bounds, to: root)) else { return false }
    var ancestor = view.superview
    while let current = ancestor {
      if let clip = current as? NSClipView, !clip.bounds.contains(view.convert(view.bounds, to: clip)) { return false }
      ancestor = current.superview
    }
    return true
  }

  private func windowStructure() -> [[String: Any]] {
    hostingWindows().map { window in
      ["number": window.windowNumber, "kind": String(describing: type(of: window)), "settings": window === settings,
        "fixturePanel": window === panel, "sheetParent": window.sheetParent?.windowNumber ?? -1,
        "attachedSheet": window.attachedSheet?.windowNumber ?? -1, "sheets": window.sheets.map(\.windowNumber),
        "content": window.contentView.map { String(describing: type(of: $0)) } ?? "unavailable",
        "views": views(window.contentView).count, "key": window.isKeyWindow]
    }
  }

  private func snapshot(_ path: String?) -> Bool {
    guard let path else { return false }
    let target = URL(fileURLWithPath: path).standardizedFileURL
    let parent = target.deletingLastPathComponent().resolvingSymlinksInPath()
    guard parent.path.hasPrefix(dataDirectory.path + "/"), target.pathExtension.lowercased() == "png",
      let view = allowButton()?.window?.contentView, let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { return false }
    view.cacheDisplay(in: view.bounds, to: rep)
    guard let bytes = rep.representation(using: .png, properties: [:]) else { return false }
    do { try bytes.write(to: target, options: .atomic); return true } catch { return false }
  }

  func destroy() {
    guard !destroyed else { return }
    destroyed = true
    savedTarget = nil
    model.teardown()
    if let settings, panel.sheetParent === settings { settings.endSheet(panel) }
    panel.orderOut(nil)
    panel.contentView = nil
    Self.accessibilityUsers -= 1
    if Self.accessibilityUsers == 0 {
      NSApp.accessibilitySetValue(Self.previousEnhancedAccessibility ?? false, forAttribute: NSAccessibility.Attribute(rawValue: "AXEnhancedUserInterface"))
      Self.previousEnhancedAccessibility = nil
    }
  }
}

extension SyncPairingFixtureHost {
  public convenience init(environment: [String: String] = ProcessInfo.processInfo.environment) {
    self.init(environment: environment) { window in
      SyncPairingDisplayFixture(settings: window, dataDirectory: environment["SOLARA_DATA_DIR"] ?? "")
    }
  }
}
#endif
