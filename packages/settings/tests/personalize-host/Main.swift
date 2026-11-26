import AppKit
import Foundation
import SolaraModel
import SolaraStore
import SolaraUI

@main
struct PersonalizeHostTests {
  @MainActor
  static func main() async throws {
    NSApplication.shared.setActivationPolicy(.prohibited)
    var state = BrowserState(settings: Settings.hydrated(from: nil))
    state.profiles["profile"] = Profile(id: "profile", name: "Work", color: "plum", icon: nil, createdAt: 0, theme: ["mode": "dark"])
    state.profiles["replacement"] = Profile(id: "replacement", name: "Home", color: "green", icon: nil, createdAt: 0)
    state.profileOrder = ["profile", "replacement"]
    for id in ["first", "other", "lifecycle"] {
      state.windows[id] = BrowserWindow(id: id, profileId: "profile", incognito: false, frame: nil, createdAt: 0)
    }
    let store = Store(state: state, memory: StoreMemory(ids: IdSource(launch: "personalize")), checksInvariants: false, clock: { 1 })
    NativeStoreHandle.resolve = { store }
    NativeStoreHandle.ownsWorkspace = true
    defer {
      NativeStoreHandle.ownsWorkspace = false
      NativeStoreHandle.resolve = nil
    }
    HostedPersonalize.register()
    var failures: [String] = []
    func expect(_ value: @autoclosure () -> Bool, _ message: String) {
      if !value() { failures.append(message) }
    }
    let appearance = "{\"dark\":true,\"tokens\":{}}"
    let first = HostedViews.make("personalize", windowId: "first")!
    let other = HostedViews.make("personalize", windowId: "other")!
    let view = first.view as! PersonalizeView
    let otherView = other.view as! PersonalizeView
    view.frame = CGRect(x: 0, y: 0, width: 800, height: 600)
    expect(!first.takesFocus, "hosting must preserve page focus")
    first.onState?(appearance)
    other.onState?(appearance)
    expect(view.state?.layout == "sidebar" && view.state?.color == "plum", "native workspace must supply profile and layout")
    expect(view.buttonFrame == CGRect(x: 754, y: 555.5, width: 30, height: 30), "button must retain its insets")
    expect(view.hitTest(CGPoint(x: 10, y: 10)) == nil, "closed overlay must pass through")
    _ = HostedPersonalize.drive("first", "press", "Personalize")
    expect(view.state?.open == true, "AX palette press must open without JS")
    expect(view.panelFrame?.width == 352 && view.panelFrame?.maxY == 546, "panel must retain geometry")
    _ = HostedPersonalize.drive("first", "press", "Blue")
    expect(store.state.profiles["profile"]?.color == "blue", "native color press must write the store")
    expect(store.state.profiles["profile"]?.theme == state.profiles["profile"]?.theme, "Personalize color must preserve the custom theme")
    _ = HostedPersonalize.drive("first", "press", "Classic")
    expect(store.state.windows["first"]?.tabLayout == "top", "layout press must use the canonical toggle")
    expect(view.state?.open == true, "choices must keep the panel open")
    try store.dispatch(SettingsWrites.updateProfile("profile", ["color": "red"]), origin: .native)
    await withCheckedContinuation { continuation in
      DispatchQueue.main.async { continuation.resume() }
    }
    expect(view.state?.color == "red", "native subscriptions must refresh without host prop changes")
    _ = HostedPersonalize.drive("other", "press", "Personalize")
    expect(otherView.state?.open == true && view.state?.open == false, "only one window may stay open")
    HostedPersonalize.setOpen("first")
    for origin: Origin in [.native, .bridge] {
      try store.dispatch(Command("setWindowClosing", ["first", true]), origin: origin)
      view.onColor("blue")
      view.onLayout("sidebar")
      expect(store.state.profiles["profile"]?.color == "red", "color must be refused during close intent from \(origin)")
      expect(store.state.windows["first"]?.tabLayout == "top", "layout must be refused during close intent from \(origin)")
      try store.dispatch(Command("setWindowClosing", ["first", false]), origin: origin)
    }
    func control(_ label: String, in root: NSView) -> PersonalizeControl? {
      if let control = root as? PersonalizeControl, control.accessibilityLabel() == label { return control }
      return root.subviews.lazy.compactMap { control(label, in: $0) }.first
    }
    if let blue = control("Blue", in: view) {
      let saved = blue.onPress
      try store.dispatch(Command("switchProfile", ["first", "replacement"]), origin: .native)
      saved?()
      expect(store.state.profiles["replacement"]?.color == "green", "stale profile actions must be refused before queued refresh")
      first.onState?(appearance)
      saved?()
      expect(store.state.profiles["replacement"]?.color == "green", "retained UI closures must remain invalid after refresh")
    } else { failures.append("missing Blue picker") }
    _ = HostedPersonalize.drive("first", "press", "Sidebar")
    expect(view.state?.layout == "sidebar", "input fixture must start with Classic unselected")
    let onOpen = view.onOpen
    let onColor = view.onColor
    let onLayout = view.onLayout
    var activations = 0
    view.onOpen = { _ in activations += 1 }
    view.onColor = { _ in activations += 1 }
    view.onLayout = { _ in activations += 1 }
    HostedPersonalize.setOpen("first")
    failures += await verifyControlInput(view, labels: ["Personalize", "Blue", "Classic"], present: {}, count: { activations }, traversalLabels: ProfileColorValue.allCases.map(\.name) + ["Personalize", "Sidebar", "Classic"])
    view.onOpen = onOpen
    view.onColor = onColor
    view.onLayout = onLayout
    NativeStoreHandle.ownsWorkspace = false
    expect(view.state == nil && otherView.state == nil, "ownership loss must clear both native surfaces")
    NativeStoreHandle.ownsWorkspace = true
    expect(view.state?.open == false, "ownership recovery must not reopen a dismissed panel")
    NativeStoreHandle.markFrozen()
    let before = store.state.profiles["replacement"]?.color
    view.onColor("red")
    expect(store.state.profiles["replacement"]?.color == before, "frozen state must refuse actions")
    NativeStoreHandle.thawForTests()
    first.onState?("invalid")
    expect(view.state == nil && view.panelFrame == nil, "invalid appearance must clear pixels and controls")
    first.onState?(appearance)
    expect(view.state?.open == false, "invalidated appearance must not reopen")
    first.onUnmount?()
    first.onState?(appearance)
    expect(view.state == nil && HostedPersonalize.drive("first", "state", nil)["active"] as? Bool == false, "unmount must detach subscriptions and inspection")
    other.onUnmount?()
    var safeConfig = StoreConfig()
    safeConfig.safeMode = true
    let safeStore = Store(state: state, config: safeConfig, checksInvariants: false)
    NativeStoreHandle.resolve = { safeStore }
    let safeContent = HostedViews.make("personalize", windowId: "first")!
    let safeView = safeContent.view as! PersonalizeView
    safeContent.onState?(appearance)
    expect(safeView.state?.open == false, "Personalize must remain visible in Safe Mode")
    HostedPersonalize.setOpen("first")
    expect(safeView.state?.open == true, "Personalize must open in Safe Mode")
    safeView.onLayout("top")
    expect(safeView.state?.layout == "top", "Classic layout must work in Safe Mode")
    safeView.onLayout("sidebar")
    expect(safeView.state?.layout == "sidebar", "Sidebar layout must work in Safe Mode")
    safeView.onColor("blue")
    expect(safeStore.state.profiles["profile"]?.color == "plum", "Safe Mode must refuse color changes")
    let hiddenParent = NSWindow(contentRect: CGRect(x: 0, y: 0, width: 800, height: 600), styleMask: [.titled], backing: .buffered, defer: false)
    hiddenParent.isReleasedWhenClosed = false
    hiddenParent.alphaValue = 0
    let safeMount = HostedMount(content: safeContent, in: hiddenParent.contentView!, window: hiddenParent)
    expect(safeView.window === hiddenParent && !hiddenParent.isVisible, "Safe Mode fixture must have a hidden parent")
    if let blue = control("Blue", in: safeView) {
      _ = blue.accessibilityPerformPress()
      expect(hiddenParent.attachedSheet == nil, "a retained color action must never present on a hidden parent")
      hiddenParent.orderFront(nil)
      expect(hiddenParent.isVisible && hiddenParent.alphaValue == 0 && !hiddenParent.isMiniaturized,
        "Safe Mode fixture must be ordered in before reveal")
      expect(blue.accessibilityPerformPress(), "the color control must accept the AX press before reveal")
      expect(hiddenParent.attachedSheet == nil, "a color action must never present before first reveal")
    } else { failures.append("missing Safe Mode Blue picker") }
    safeMount.end()
    hiddenParent.close()
    NativeStoreHandle.resolve = { store }
    let content = HostedViews.make("personalize", windowId: "lifecycle")!
    let mounted = content.view as! PersonalizeView
    let window = NSWindow(contentRect: CGRect(x: 0, y: 0, width: 800, height: 600), styleMask: [.titled], backing: .buffered, defer: false)
    window.isReleasedWhenClosed = false
    window.alphaValue = 0
    let host = NSView(frame: window.contentView!.bounds)
    window.contentView = host
    let mount = HostedMount(content: content, in: host, window: window)
    content.onState?(appearance)
    HostedPersonalize.setOpen("lifecycle")
    if let blue = control("Blue", in: mounted) {
      expect(window.makeFirstResponder(blue), "picker must accept explicit focus")
      HostedPersonalize.setOpen(nil)
      expect((window.firstResponder as? NSView)?.accessibilityLabel() == "Personalize", "closing must restore palette focus")
      HostedPersonalize.setOpen("lifecycle")
      if let current = control("Blue", in: mounted) { window.makeFirstResponder(current) }
      mount.end()
      expect(mounted.window == nil && mounted.state == nil, "real unmount must clear native lifetime")
      expect((window.firstResponder as? NSView).map { $0.window === window } ?? true, "unmount must leave no detached responder")
    } else { failures.append("missing mounted picker"); mount.end() }
    window.contentView = nil
    window.close()
    if failures.isEmpty { print("PASS native Personalize state, actions, receipts, geometry, input, focus, ownership and unmount") }
    else { failures.forEach { print("FAIL \($0)") }; exit(1) }
  }
}
