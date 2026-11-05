import AppKit
import ExpoModulesCore

public class HostedModule: Module {
  public func definition() -> ModuleDefinition {
    Name("SolaraHosted")

    Events("onHostedEvent")

    OnCreate {
      if NativeExtensionSidePanel.enabled { HostedViews.declare(NativeExtensionSidePanel.kind) }
      if NativeBookmarksBar.enabled { HostedViews.declare(NativeBookmarksBar.kind) }
      HostedViews.declare(PanePrompts.kind)
      if NativeSidebarShell.enabled { HostedViews.declare(NativeSidebarShell.topic) }
      HostedViews.declare(NativeToolTour.kind)
      let sink = HostedSink(self)
      DispatchQueue.main.async {
        MainActor.assumeIsolated {
          HostedViews.emit = { body in sink.module?.sendEvent("onHostedEvent", body) }
          NativeStatusBubble.register(); NativeSidebar.register(); NativeDownloadMagnet.register(); NativeTabPickers.register(); NativeExtensionSidePanel.register()
          NativeSidebarIconPicker.register()
          NativeToolTour.register()
          if NativeBookmarksBar.enabled { NativeBookmarksBar.register() }
        }
      }
    }

    AsyncFunction("focusPageIfUnclaimed") { (windowId: String, tabId: String) -> Bool in
      MainActor.assumeIsolated { SidePanelFocus.focus(windowId: windowId, tabId: tabId) }
    }.runOnQueue(.main)

    Function("kinds") { () -> [String] in
      HostedViews.kinds
    }

    AsyncFunction("sidebarRowFrame") { (windowId: String, key: String) -> [String: Double]? in
      MainActor.assumeIsolated { NativeSidebar.rowFrame(windowId: windowId, key: key) }
    }.runOnQueue(.main)

    AsyncFunction("sidebarHoverShifts") { (windowId: String) -> String in
      MainActor.assumeIsolated { NativeSidebar.hoverShifts(windowId: windowId) ?? "null" }
    }.runOnQueue(.main)

    AsyncFunction("sidebarMotion") { (windowId: String) -> String in
      MainActor.assumeIsolated { NativeSidebar.motion(windowId: windowId) ?? "null" }
    }.runOnQueue(.main)

    AsyncFunction("sidebarHoverCard") { (windowId: String) -> String in
      MainActor.assumeIsolated { NativeSidebarHoverCard.describe(windowId) }
    }.runOnQueue(.main)

    AsyncFunction("sidebarIconPicker") { (windowId: String) -> String in
      MainActor.assumeIsolated { NativeSidebarIconPicker.describe(windowId) }
    }.runOnQueue(.main)

    AsyncFunction("sidebarIconPickerInput") { (windowId: String, action: String) in
      MainActor.assumeIsolated { NativeSidebarIconPicker.devInput(windowId, action) }
    }.runOnQueue(.main)

    AsyncFunction("sidebarShell") { (windowId: String) -> String in
      MainActor.assumeIsolated { NativeSidebarShell.describe(windowId) }
    }.runOnQueue(.main)

    AsyncFunction("presentedAt") { (windowId: String, x: Double, y: Double, width: [Double], height: [Double]) -> String in
      MainActor.assumeIsolated {
        guard width.count == 2, height.count == 2 else { return "null" }
        return NativeSidebarHoverCard.presented(windowId, at: CGPoint(x: x, y: y), width: width[0]...width[1], height: height[0]...height[1])
      }
    }.runOnQueue(.main)

    Function("takeSwitcherPress") { (windowId: String) -> Int in
      NativeTabPickers.switcherPresses.take(windowId)
    }

    AsyncFunction("tabPickers") { (windowId: String) -> String in
      MainActor.assumeIsolated { NativeTabPickers.describe(windowId) }
    }.runOnQueue(.main)

    AsyncFunction("downloadMagnet") { (windowId: String) -> String in
      MainActor.assumeIsolated { NativeDownloadMagnet.describe(windowId) }
    }.runOnQueue(.main)

    AsyncFunction("sidebarPages") { (windowId: String) -> String in
      MainActor.assumeIsolated { NativeSidebar.pages(windowId: windowId) ?? "null" }
    }.runOnQueue(.main)

    View(SolaraHostedView.self) {
      Prop("kind") { (view: SolaraHostedView, v: String) in MainActor.assumeIsolated { view.kind = v } }
      Prop("windowId") { (view: SolaraHostedView, v: String) in MainActor.assumeIsolated { view.windowId = v } }
      Prop("active") { (view: SolaraHostedView, v: Bool?) in MainActor.assumeIsolated { view.active = v ?? true } }
      Prop("state") { (view: SolaraHostedView, v: String?) in MainActor.assumeIsolated { view.state = v ?? "" } }

      OnViewDidUpdateProps { (view: SolaraHostedView) in MainActor.assumeIsolated { view.propsDidUpdate() } }
    }

    #if DEBUG
    AsyncFunction("devBookmarksBarLayout") { (windowId: String) -> String in
      MainActor.assumeIsolated { NativeBookmarksBar.devLayoutJSON(windowId: windowId) }
    }.runOnQueue(.main)

    AsyncFunction("devBookmarksBarMenu") { (windowId: String, trigger: String, id: String?) -> String in
      MainActor.assumeIsolated { NativeBookmarksBar.devMenuJSON(windowId: windowId, trigger: trigger, id: id) }
    }.runOnQueue(.main)

    AsyncFunction("devBookmarksBarChoose") { (windowId: String, trigger: String, id: String?, choiceId: String) -> String in
      MainActor.assumeIsolated { NativeBookmarksBar.devChooseJSON(windowId: windowId, trigger: trigger, id: id, choiceId: choiceId) }
    }.runOnQueue(.main)

    AsyncFunction("devBookmarksBarInput") { (windowId: String, action: String, id: String?, modifiers: Int, x: Double?) -> Bool in
      MainActor.assumeIsolated { NativeBookmarksBar.devInput(windowId: windowId, action: action, id: id, modifiers: modifiers, x: x) }
    }.runOnQueue(.main)
    #endif

    AsyncFunction("devHost") { (kind: String, windowId: String, on: Bool) -> [String: String] in
      MainActor.assumeIsolated { DevHost.toggle(kind: kind, windowId: windowId, on: on) }
    }.runOnQueue(.main)
  }
}

private final class HostedSink: @unchecked Sendable {
  weak var module: HostedModule?
  init(_ module: HostedModule) { self.module = module }
}

@MainActor
enum DevHost {
  private static var hosts: [String: DevHostView] = [:]
  private static let fieldKind = "dev.field"

  static func toggle(kind: String, windowId: String, on: Bool) -> [String: String] {
    #if DEBUG
    if kind == fieldKind { registerField() }
    let window = NSApp.windows.filter { $0.isVisible && $0.contentView != nil }.max { $0.frame.width * $0.frame.height < $1.frame.width * $1.frame.height }
    let before = describe(window?.firstResponder)
    if on, let content = window?.contentView, hosts[kind] == nil {
      let host = DevHostView(kind: kind, windowId: windowId)
      host.frame = content.bounds
      host.autoresizingMask = [.width, .height]
      hosts[kind] = host
      content.addSubview(host)
    } else if !on, let host = hosts.removeValue(forKey: kind) {
      host.removeFromSuperview()
    }
    return ["before": before, "after": describe(window?.firstResponder), "mounted": String(hosts[kind]?.mountedView != nil), "unmounts": String(unmounts)]
    #else
    return [:]
    #endif
  }

  private static func describe(_ responder: NSResponder?) -> String {
    guard let responder else { return "nil" }
    if let editor = responder as? NSTextView, editor.isFieldEditor, let field = editor.delegate {
      return "field editor of \(type(of: field))"
    }
    return String(describing: type(of: responder))
  }

  private static func registerField() {
    HostedViews.register(fieldKind) { _ in
      let box = NSView()
      let field = NSTextField(string: "")
      field.frame = NSRect(x: 20, y: 20, width: 200, height: 24)
      box.addSubview(field)
      let probe = DevFieldBox(field: field)
      return HostedContent(view: probe.adopt(box), onUnmount: { DevHost.unmounts += 1 })
    }
  }

  static var unmounts = 0
}

final class DevFieldBox: NSView {
  let field: NSTextField

  init(field: NSTextField) {
    self.field = field
    super.init(frame: .zero)
  }

  required init?(coder: NSCoder) { fatalError() }

  func adopt(_ box: NSView) -> NSView {
    box.frame = bounds
    box.autoresizingMask = [.width, .height]
    addSubview(box)
    return self
  }

  override var acceptsFirstResponder: Bool { true }

  override func becomeFirstResponder() -> Bool {
    DispatchQueue.main.async { [field] in field.window?.makeFirstResponder(field) }
    return true
  }
}

final class DevHostView: NSView {
  let kind: String
  let windowId: String
  private var mount: HostedMount?

  init(kind: String, windowId: String) {
    self.kind = kind
    self.windowId = windowId
    super.init(frame: .zero)
  }

  required init?(coder: NSCoder) { fatalError() }

  override var isFlipped: Bool { true }

  override func hitTest(_ point: NSPoint) -> NSView? {
    let hit = super.hitTest(point)
    return hit === self ? nil : hit
  }

  override func viewDidMoveToWindow() {
    super.viewDidMoveToWindow()
    guard mount == nil, let window, let content = HostedViews.make(kind, windowId: windowId) else { return }
    mount = HostedMount(content: content, in: self, window: window)
  }

  override func viewWillMove(toWindow newWindow: NSWindow?) {
    if newWindow == nil {
      let current = mount
      mount = nil
      current?.end()
    }
    super.viewWillMove(toWindow: newWindow)
  }

  override func keyUp(with event: NSEvent) {}

  override func flagsChanged(with event: NSEvent) {}

  var mountedView: NSView? { mount?.content.view }
}

#if SOLARA_PROBES
public enum HostedRead {
  public static var kinds: [String] { HostedViews.kinds }
}
#endif

#if SOLARA_PROBES
@MainActor
public enum HoverLayoutRead {
  public static func snapshot(windowId: String, area: String) -> [String: Any]? {
    switch area {
    case "sidebar":
      guard let page = NativeSidebar.hosts[windowId]?.view.current else { return nil }
      return ["area": area, "targets": page.probeHoverTargets(), "frames": page.probeHoverFrames()]
    case "topStrip":
      guard let page = NativeTopStrip.hosts[windowId]?.view.current else { return nil }
      return ["area": area, "targets": page.probeHoverTargets(), "frames": page.probeHoverFrames()]
    case "downloads":
      var result = DownloadsHoverShifts.probeSnapshot(windowId: windowId)
      result["area"] = area
      return result
    default: return nil
    }
  }
}

@MainActor
public enum HoverLayoutInput {
  public static func perform(windowId: String, area: String, target: String, on: Bool) -> Bool {
    switch area {
    case "sidebar": return NativeSidebar.hosts[windowId]?.view.current?.probeHover(target, on: on) ?? false
    case "topStrip": return NativeTopStrip.hosts[windowId]?.view.current?.probeHover(target, on: on) ?? false
    case "downloads": return DownloadsHoverShifts.probeHover(windowId: windowId, key: target, on: on)
    default: return false
    }
  }
}
#endif
