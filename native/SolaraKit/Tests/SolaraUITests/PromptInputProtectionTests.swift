import AppKit
import Testing

@testable import SolaraUI

@MainActor
private final class RejectingPromptInputControl: NSView {
  var queries = 0
  var presses = 0
  override func acceptsFirstMouse(for event: NSEvent?) -> Bool { queries += 1; return false }
  override func mouseDown(with event: NSEvent) { presses += 1 }
}

@MainActor
private final class PromptInputPageView: NSView {
  override var acceptsFirstResponder: Bool { true }
}

@MainActor
@Suite(.serialized) struct PromptInputProtectionTests {
  private func permission(_ key: String? = "permission-1") -> PromptBodyView {
    let body = PromptBodyView(frame: CGRect(x: 0, y: 0, width: 300, height: 300))
    var state = PromptState.decode(##"{"icons":[],"title":"Allow notifications?","details":[],"buttons":[{"id":"deny","title":"Don't Allow"},{"id":"accept","title":"Allow","primary":true}],"close":true,"dark":false,"theme":{},"control":"#FFFFFF","controlBorder":"#000000","goButton":"#000000","goButtonText":"#FFFFFF"}"##)!
    state.inputProtectionKey = key
    body.update(state)
    return body
  }

  private func chooser() -> DeviceChooserView {
    let body = DeviceChooserView(frame: CGRect(x: 0, y: 0, width: 340, height: 400))
    body.update(DeviceChooserState.decode(##"{"id":1,"title":"Choose a device","icon":"headphones","options":[{"name":"Fixture device","signal":3}],"selected":0,"scanning":false,"refreshing":false,"canRefresh":true,"scanningText":"Scanning","noOptionsText":"No devices","unauthorized":false,"adapterOff":false,"cancelLabel":"Cancel","okLabel":"Connect","valid":true,"dark":false,"theme":{},"goButton":"#000000","goButtonText":"#FFFFFF"}"##)!)
    return body
  }

  private func install() -> ExtensionInstallView {
    let body = ExtensionInstallView(frame: CGRect(x: 0, y: 0, width: 348, height: 300))
    body.update(ExtensionInstallState(status: "prompt", title: "Add fixture?", warnings: ["Read site data"], action: "Add extension", dark: false, theme: [:], goButton: "#000000", goButtonText: "#FFFFFF"))
    return body
  }

  private func button(_ label: String, in root: NSView) -> PromptPressable? {
    if let control = root as? PromptPressable, control.accessibilityLabel() == label { return control }
    return root.subviews.lazy.compactMap { button(label, in: $0) }.first
  }

  private func mouse(_ type: NSEvent.EventType, _ control: NSView, at time: TimeInterval, clicks: Int = 1) -> NSEvent {
    NSEvent.mouseEvent(with: type, location: control.convert(CGPoint(x: control.bounds.midX, y: control.bounds.midY), to: nil), modifierFlags: [], timestamp: time, windowNumber: control.window?.windowNumber ?? 0, context: nil, eventNumber: 1, clickCount: clicks, pressure: type == .leftMouseDown ? 1 : 0)!
  }

  private func key(_ code: UInt16, at time: TimeInterval, repeat repeated: Bool = false) -> NSEvent {
    NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: time, windowNumber: 0, context: nil, characters: code == 49 ? " " : "\r", charactersIgnoringModifiers: code == 49 ? " " : "\r", isARepeat: repeated, keyCode: code)!
  }

  private func exercise(_ body: NSView, _ protection: PromptInputProtection, label: String, count: () -> Int) throws {
    var now: TimeInterval = 100
    protection.now = { now }
    protection.shown()
    let control = try #require(button(label, in: body))
    #expect(!control.acceptsFirstMouse(for: nil))
    let initial = count()
    now = 100.499
    control.mouseDown(with: mouse(.leftMouseDown, control, at: now))
    control.mouseUp(with: mouse(.leftMouseUp, control, at: now))
    for code: UInt16 in [36, 49, 76] { control.keyDown(with: key(code, at: now)) }
    #expect(!control.accessibilityPerformPress())
    #expect(count() == initial)
    control.mouseDown(with: mouse(.leftMouseDown, control, at: now))
    now = 100.6
    control.mouseUp(with: mouse(.leftMouseUp, control, at: now, clicks: 2))
    #expect(count() == initial)
    control.mouseDown(with: mouse(.leftMouseDown, control, at: now))
    control.mouseUp(with: mouse(.leftMouseUp, control, at: now))
    #expect(count() == initial + 1)
    for code: UInt16 in [36, 49, 76] { control.keyDown(with: key(code, at: now)) }
    #expect(count() == initial + 4)
    #expect(control.accessibilityPerformPress())
    #expect(count() == initial + 5)
    control.keyDown(with: key(36, at: now, repeat: true))
    control.keyDown(with: key(36, at: 100.1))
    #expect(count() == initial + 5)
    protection.shown()
    control.keyDown(with: key(36, at: now))
    #expect(!control.accessibilityPerformPress())
    #expect(count() == initial + 5)
  }

  @Test func permissionProtectsMouseKeyboardAndAccessibility() throws {
    let body = permission()
    var events: [PromptEvent] = []
    body.onEvent = { events.append($0) }
    try exercise(body, body.inputProtection, label: "Allow", count: { events.count })
    #expect(events.allSatisfy { $0 == .button("accept") })
  }

  @Test func deviceChooserProtectsMouseKeyboardAndAccessibility() throws {
    let body = chooser()
    var events: [DeviceChooserEvent] = []
    body.onEvent = { events.append($0) }
    try exercise(body, body.inputProtection, label: "Connect", count: { events.count })
    #expect(events.allSatisfy { $0 == .choose(0) })
  }

  @Test func extensionInstallProtectsMouseKeyboardAndAccessibility() throws {
    let body = install()
    var events: [ExtensionDialogEvent] = []
    body.onEvent = { events.append($0) }
    try exercise(body, body.inputProtection, label: "Add extension", count: { events.count })
    #expect(events.allSatisfy { $0 == .confirm })
  }

  @Test func chooserReturnAndDoubleClickCannotBypassProtection() throws {
    let body = chooser()
    var now: TimeInterval = 200
    body.inputProtection.now = { now }
    body.inputProtection.shown()
    var events: [DeviceChooserEvent] = []
    body.onEvent = { events.append($0) }
    body.keyDown(with: key(36, at: now))
    let row = try #require(button("Fixture device", in: body))
    row.mouseDown(with: mouse(.leftMouseDown, row, at: now, clicks: 2))
    now += 0.6
    row.mouseUp(with: mouse(.leftMouseUp, row, at: now, clicks: 2))
    #expect(events.isEmpty)
    body.keyDown(with: key(36, at: now))
    #expect(events == [.choose(0)])
    row.mouseDown(with: mouse(.leftMouseDown, row, at: now, clicks: 2))
    row.mouseUp(with: mouse(.leftMouseUp, row, at: now, clicks: 2))
    #expect(events == [.choose(0), .select(0), .choose(0)])
  }

  @Test func unprotectedSharedButtonsKeepTheirTimingAndRejectFirstMouse() throws {
    let body = permission(nil)
    var events: [PromptEvent] = []
    body.onEvent = { events.append($0) }
    let control = try #require(button("Allow", in: body))
    #expect(!control.acceptsFirstMouse(for: nil))
    #expect(control.accessibilityPerformPress())
    #expect(events == [.button("accept")])
    #expect(!PromptPressable(frame: .zero).acceptsFirstMouse(for: nil))
  }

  @Test func ownWindowActivationAndPresentationRestartProtection() throws {
    NSApplication.shared.setActivationPolicy(.prohibited)
    let window = NSWindow(contentRect: CGRect(x: 0, y: 0, width: 340, height: 400), styleMask: [.titled], backing: .buffered, defer: false)
    let other = NSWindow(contentRect: CGRect(x: 0, y: 0, width: 340, height: 400), styleMask: [.titled], backing: .buffered, defer: false)
    window.isReleasedWhenClosed = false
    other.isReleasedWhenClosed = false
    window.alphaValue = 0
    other.alphaValue = 0
    defer { window.close(); other.close() }
    let body = chooser()
    var now: TimeInterval = 300
    body.inputProtection.now = { now }
    let container = NSView(frame: body.frame)
    window.contentView = container
    container.addSubview(body)
    var count = 0
    body.onEvent = { _ in count += 1 }
    let control = try #require(button("Connect", in: body))
    #expect(!control.accessibilityPerformPress())
    now = 300.5
    #expect(control.accessibilityPerformPress())
    NotificationCenter.default.post(name: NSWindow.didBecomeKeyNotification, object: other)
    #expect(control.accessibilityPerformPress())
    NotificationCenter.default.post(name: NSWindow.didBecomeKeyNotification, object: window)
    #expect(!control.accessibilityPerformPress())
    now = 301
    #expect(control.accessibilityPerformPress())
    container.isHidden = true
    container.isHidden = false
    #expect(!control.accessibilityPerformPress())
    now = 301.5
    #expect(control.accessibilityPerformPress())
    #expect(count == 4)
  }

  @Test func aMousePressStartedBeforeReactivationStaysRejected() throws {
    let body = chooser()
    var now: TimeInterval = 400
    body.inputProtection.now = { now }
    body.inputProtection.shown()
    var count = 0
    body.onEvent = { _ in count += 1 }
    let control = try #require(button("Connect", in: body))
    now = 400.5
    control.mouseDown(with: mouse(.leftMouseDown, control, at: now))
    body.inputProtection.shown()
    now = 401
    control.mouseUp(with: mouse(.leftMouseUp, control, at: now))
    #expect(count == 0)
  }

  @Test func aReplacedPermissionControlCannotCompleteItsOldPress() throws {
    let body = permission()
    var now: TimeInterval = 450
    body.inputProtection.now = { now }
    body.inputProtection.shown()
    var count = 0
    body.onEvent = { _ in count += 1 }
    let control = try #require(button("Allow", in: body))
    now = 450.5
    control.mouseDown(with: mouse(.leftMouseDown, control, at: now))
    control.removeFromSuperview()
    body.inputProtection.shown()
    now = 451.5
    control.mouseUp(with: mouse(.leftMouseUp, control, at: now))
    #expect(count == 0)
  }

  @Test func installSheetReturnCannotBypassItsBodyGuard() {
    NSApplication.shared.setActivationPolicy(.prohibited)
    let window = NSWindow(contentRect: CGRect(x: 0, y: 0, width: 800, height: 600), styleMask: [.titled], backing: .buffered, defer: false)
    window.isReleasedWhenClosed = false
    window.alphaValue = 0
    defer { window.close() }
    let sheet = SheetView(frame: CGRect(x: 0, y: 0, width: 800, height: 600))
    window.contentView = sheet
    let body = install()
    var now: TimeInterval = 500
    body.inputProtection.now = { now }
    var submits = 0
    sheet.onSubmit = { submits += 1 }
    sheet.present(body: body, bodyHeight: 180, style: SheetStyle(dark: false, panel: "#FFFFFF", panelBorder: "#000000", panelShadowOpacity: 0.3), accessibilityTitle: "Add fixture?", animated: false)
    sheet.keyDown(with: key(36, at: now))
    #expect(submits == 0)
    now = 500.5
    sheet.keyDown(with: key(36, at: now, repeat: true))
    #expect(submits == 0)
    sheet.keyDown(with: key(36, at: now))
    #expect(submits == 1)
  }

  @Test func inactivePermissionClickIsRejectedAndSadTabReloadActs() throws {
    NSApplication.shared.setActivationPolicy(.prohibited)
    let frontmost = NSWorkspace.shared.frontmostApplication?.processIdentifier
    let window = NSWindow(contentRect: CGRect(x: 0, y: 0, width: 800, height: 600), styleMask: [.titled], backing: .buffered, defer: false)
    window.isReleasedWhenClosed = false
    window.alphaValue = 0
    defer { window.orderOut(nil); window.close() }
    let root = PromptInputPageView(frame: CGRect(x: 0, y: 0, width: 800, height: 600))
    window.contentView = root
    window.makeFirstResponder(root)
    let body = permission()
    root.addSubview(body)
    var now = ProcessInfo.processInfo.systemUptime
    body.inputProtection.now = { now }
    body.inputProtection.shown()
    now += 1
    var allowed = 0
    body.onEvent = { _ in allowed += 1 }
    window.orderBack(nil)
    NSApp.deactivate()
    window.resignKey()
    window.makeFirstResponder(root)
    #expect(!window.isKeyWindow && !NSApp.isActive)
    let rejecting = RejectingPromptInputControl(frame: CGRect(x: 700, y: 500, width: 50, height: 50))
    root.addSubview(rejecting)
    NSApp.sendEvent(mouse(.leftMouseDown, rejecting, at: now))
    NSApp.sendEvent(mouse(.leftMouseUp, rejecting, at: now))
    #expect(rejecting.queries > 0 && rejecting.presses == 0)
    NSApp.deactivate()
    window.resignKey()
    let allow = try #require(button("Allow", in: body))
    let hit = root.hitTest(allow.convert(CGPoint(x: allow.bounds.midX, y: allow.bounds.midY), to: root))
    #expect(hit?.acceptsFirstMouse(for: nil) == false)
    NSApp.sendEvent(mouse(.leftMouseDown, allow, at: now))
    NSApp.sendEvent(mouse(.leftMouseUp, allow, at: now))
    #expect(allowed == 0)
    body.removeFromSuperview()
    let sad = SadTabView(frame: root.bounds)
    root.addSubview(sad)
    sad.update(SadTabState.decode(##"{"mode":"crashed","dark":false,"textPrimary":"#000000","textSecondary":"#00000099","panel":"#FFFFFF","panelBorder":"#000000","panelShadowOpacity":0.3,"goButton":"#000000","goButtonText":"#FFFFFF"}"##)!)
    var reloads = 0
    sad.onAction = { if $0 == .reload { reloads += 1 } }
    let reload = try #require(button("Reload", in: sad))
    #expect(reload.acceptsFirstMouse(for: nil))
    NSApp.deactivate()
    window.resignKey()
    NSApp.sendEvent(mouse(.leftMouseDown, reload, at: now))
    NSApp.sendEvent(mouse(.leftMouseUp, reload, at: now))
    #expect(reloads == 1)
    #expect(NSWorkspace.shared.frontmostApplication?.processIdentifier == frontmost)
  }
}
