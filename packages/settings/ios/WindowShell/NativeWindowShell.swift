import AppKit
import SolaraShaders
import SolaraShell
import ExpoModulesCore
import Foundation
import SolaraModel
import SolaraStore
import Synchronization
import SolaraUI

@MainActor
enum NativeWindowShell {
  private static var installed = false
  private static var storeListener: Int?
  private static let lifetimes: ShellLifetimes<ShellHost> = {
    let lifetimes = ShellLifetimes<ShellHost> { host in
      host.stop()
      if NativeWindowShell.lifetimes.host(host.shell.windowId) == nil { NativeShareBand.windowEnded(host.shell.windowId) }
    }
    lifetimes.onIds = { ids in activeIds.withLock { $0 = ids } }
    return lifetimes
  }()
  private static let commits = ShellStoreCommits()
  nonisolated private static let activeIds = Mutex<Set<String>>([])

  nonisolated static var enabled: Bool {
    LaunchSwitches.shared.isOn(.nativeShell)
  }

  nonisolated static var mainOnTop: Bool {
    TabPoolHost.available && LaunchSwitches.shared.isOn(.shellMainTop)
  }

  static func install() {
    guard enabled, !installed, let make = WindowHost.makeContentView else { return }
    installed = true
    NativeSplitChrome.start()
    NativeShareBand.start()
    NativePeek.start()
    if let store = NativeStoreHandle.store {
      let sink = commits
      storeListener = store.subscribe { commit in
        sink.receive(Set(commit.state.windows.keys))
        NativePaneRoots.storeChanged()
      }
    }
    WindowHost.makeContentView = { windowId in
      guard isBrowserWindow(windowId) else { return make(windowId) }
      activeIds.withLock { _ = $0.insert(windowId) }
      let host = ShellHost(windowId: windowId, root: make(windowId))
      lifetimes.adopt(windowId, host)
      host.onClose = { [weak host] in lifetimes.end(windowId, ifHost: host) }
      return host.shell
    }
  }

  static func windowsChanged(_ live: Set<String>) {
    lifetimes.prune(keeping: live)
  }

  static func isBrowserWindow(_ windowId: String) -> Bool {
    if let kind = WindowHost.openingKinds[windowId] { return kind == "browser" }
    guard let window = NativeStoreHandle.store?.state.windows[windowId] else { return false }
    return window.kind == nil || window.kind == "browser"
  }

  static func host(_ windowId: String) -> ShellHost? { lifetimes.host(windowId) }

  nonisolated static func active(_ windowId: String) -> Bool { activeIds.withLock { $0.contains(windowId) } }

  nonisolated static var activeWindowIds: Set<String> { activeIds.withLock { $0 } }

  static func overlay(_ windowId: String) -> NSView? { host(windowId)?.shell.overlay }

  static func hiddenPages(_ windowId: String) -> NSView? { host(windowId)?.shell.hiddenPages }

  static func setBackdrop(_ windowId: String, _ json: String) {
    host(windowId)?.setBackdrop(json)
  }

  static func describe(_ windowId: String) -> [String: Any]? {
    host(windowId)?.describe()
  }
}

@MainActor
final class ShellHost {
  let shell: WindowShellView
  private weak var root: NSView?
  private var backdropJSON: String?
  private var observers: [NSObjectProtocol] = []
  private var contentSizer: NSObjectProtocol?
  private var closing: NSObjectProtocol?
  private var panes: PaneRootsHost?
  private var profilePager: ProfilePagerHost?
  private var sidePanel: SidePanelHost?
  #if DEBUG
  var devSidePanelResizeLinkActive: Bool { sidePanel?.devResizeLinkActive ?? false }
  #endif
  var onClose: (() -> Void)?

  init(windowId: String, root: NSView) {
    shell = WindowShellView(windowId: windowId, reactOnTop: NativeWindowShell.mainOnTop)
    self.root = root
    if shell.reactOnTop, root.responds(to: Selector(("setPassThroughTouches:"))) { root.setValue(true, forKey: "passThroughTouches") }
    shell.mount(.react, root)
    let center = NotificationCenter.default
    let appeared = Notification.Name("RCTContentDidAppearNotification")
    observers.append(
      center.addObserver(forName: appeared, object: root, queue: .main) { [weak self] _ in
        MainActor.assumeIsolated {
          guard let self else { return }
          self.keepContentSized()
          center.post(name: appeared, object: self.shell)
        }
      })
    keepContentSized()
    shell.onWindow = { [weak self] window in
      self?.watchClose(of: window)
      self?.profilePager?.windowChanged()
      self?.sidePanel?.windowChanged(window)
    }
    panes = NativePaneRoots.start(windowId)
    profilePager = NativeProfilePager.start(shell)
    shell.onFrames = { [weak self] _ in
      self?.profilePager?.place()
      self?.sidePanel?.place()
    }
  }

  private func watchClose(of window: NSWindow?) {
    if let closing { NotificationCenter.default.removeObserver(closing) }
    closing = nil
    guard let window else { return }
    closing = NotificationCenter.default.addObserver(forName: NSWindow.willCloseNotification, object: window, queue: .main) { [weak self] _ in
      MainActor.assumeIsolated { self?.onClose?() }
    }
  }

  func stop() {
    sidePanel?.stop()
    sidePanel = nil
    NativePeek.windowEnded(shell.windowId)
    NativeSidebarDock.setReactPeekRight(shell.windowId, 0)
    if let panes { NativePaneRoots.end(shell.windowId, ifHost: panes) }
    panes = nil
    profilePager?.stop()
    profilePager = nil
    for observer in observers { NotificationCenter.default.removeObserver(observer) }
    observers = []
    if let closing { NotificationCenter.default.removeObserver(closing) }
    closing = nil
    onClose = nil
    shell.onWindow = nil
    if let contentSizer { NotificationCenter.default.removeObserver(contentSizer) }
    contentSizer = nil
  }

  private func keepContentSized() {
    if let contentSizer { NotificationCenter.default.removeObserver(contentSizer) }
    contentSizer = nil
    guard let root, let content = root.subviews.first(where: { NSStringFromClass(type(of: $0)).hasSuffix("RootContentView") }) else { return }
    content.postsFrameChangedNotifications = true
    contentSizer = NotificationCenter.default.addObserver(forName: NSView.frameDidChangeNotification, object: content, queue: .main) {
      [weak root, weak content] _ in
      MainActor.assumeIsolated {
        guard let root, let content, content.superview === root, root.window != nil, !root.bounds.isEmpty, content.frame.size != root.bounds.size
        else { return }
        root.needsLayout = true
        content.needsLayout = true
      }
    }
  }

  func setSidePanel(_ json: String?) {
    if sidePanel == nil {
      guard let json, !json.isEmpty, SidePanelState.decode(json) != nil else { return }
      sidePanel = SidePanelHost(windowId: shell.windowId, shell: shell)
    }
    sidePanel?.apply(json)
  }

  func setBackdrop(_ json: String) {
    guard json != backdropJSON else { return }
    backdropJSON = json
    defer { NativePeek.backdropChanged(shell.windowId) }
    guard let view = makeBackdrop() else { return shell.mount(.backdrop, nil) }
    shell.mount(.backdrop, view)
  }

  func makeBackdrop() -> NSView? {
    guard let data = backdropJSON?.data(using: .utf8), let props = (try? JSONSerialization.jsonObject(with: data)) as? NSDictionary else { return nil }
    return EarlyBackdrop.make(props)
  }

  func describe() -> [String: Any] {
    func rect(_ r: CGRect?) -> Any { r.map { [$0.minX, $0.minY, $0.width, $0.height] } ?? NSNull() }
    let f = shell.frames
    return [
      "bounds": rect(shell.bounds),
      "card": rect(f.card),
      "sidebar": rect(f.sidebar),
      "sidebarShift": f.sidebarShift,
      "topStrip": rect(f.topStrip),
      "slots": WindowShellView.Slot.allCases.compactMap { slot in shell.view(in: slot).map { [slot.rawValue, NSStringFromClass(type(of: $0))] } },
      "order": shell.subviews.map { NSStringFromClass(type(of: $0)) },
      "backdrop": backdropJSON ?? NSNull(),
      "fill": shell.backgroundColor.map { String(describing: $0) } ?? NSNull(),
      "windowFill": shell.window?.backgroundColor.map { String(describing: $0) } ?? NSNull(),
      "appearance": shell.window?.effectiveAppearance.name.rawValue ?? NSNull(),
      "split": NativeSplitChrome.sample(shell.windowId) ?? NSNull(),
      "shareBand": NativeShareBand.describe(shell.windowId) ?? NSNull(),
      "shareBandWindows": NativeShareBand.windowIds,
      "paneRoots": NativePaneRoots.sample(shell.windowId) ?? NSNull(),
      "reactOnTop": shell.reactOnTop,
      "peek": NativePeek.sample(shell.windowId) ?? NSNull(),
      "sidebarDock": NativeSidebarDock.describe(shell.windowId) ?? NSNull(),
    ]
  }
}

#if SOLARA_PROBES
@MainActor
enum WindowShellProbeSamples {
  static var hitCosts: [String: [String: String]] = [:]
  static var pointerStreams: [String: [String: Double]] = [:]
  static var pointerLatencies: [String: [String: Any]] = [:]
}

@MainActor
public enum WindowShellRead {
  public static func hoverMeasurements(windowId: String) -> [String: Any]? {
    guard NativeWindowShell.host(windowId) != nil else { return nil }
    return ["hitCost": WindowShellProbeSamples.hitCosts[windowId] ?? [:],
      "pointerStream": WindowShellProbeSamples.pointerStreams[windowId] ?? [:],
      "pointerLatency": WindowShellProbeSamples.pointerLatencies[windowId] ?? [:],
      "sidebarDockLive": NativeSidebarDock.describe(windowId)?["live"] ?? NSNull()]
  }

  public static func accessibilityReach(windowId: String) -> [String: Int]? {
    NativeWindowShell.host(windowId)?.shell.accessibilityReach()
  }

  public static func snapshot(windowId: String) -> [String: Any]? {
    guard let source = NativeWindowShell.describe(windowId) else { return nil }
    return ["card": source["card"] ?? NSNull(), "order": source["order"] ?? [],
      "reactOnTop": source["reactOnTop"] ?? false]
  }

  public static func hitSlot(windowId: String, x: Double, y: Double) -> String? {
    guard let shell = NativeWindowShell.host(windowId)?.shell, shell.window != nil else { return nil }
    let point = shell.convert(NSPoint(x: x, y: y), to: nil)
    return shell.slotUnderPointer(at: point)?.rawValue
  }

  public static func hitView(windowId: String, x: Double, y: Double) -> String? {
    guard let window = NativeWindowShell.host(windowId)?.shell.window, let content = window.contentView else { return nil }
    let point = content.convert(NSPoint(x: x, y: content.isFlipped ? y : content.bounds.height - y), to: nil)
    return content.superview?.hitTest(point).map { String(describing: type(of: $0)) }
  }

  public static func reactBlockers(windowId: String, step: Double) -> [[String: Any]]? {
    NativeWindowShell.host(windowId)?.reactBlockers(step: CGFloat(step))
  }
}
#endif

#if DEBUG
extension ShellHost {
  func reactBlockers(step: CGFloat) -> [[String: Any]] {
    guard shell.reactOnTop, let root = shell.view(in: .react), !root.isHidden, step > 0 else { return [] }
    let frames = shell.frames
    let areas = [frames.card, frames.sidebar?.offsetBy(dx: frames.sidebarShift, dy: 0), frames.topStrip].compactMap { $0 }.filter { !$0.isEmpty }
    var found: [ObjectIdentifier: [String: Any]] = [:]
    for area in areas {
      for y in stride(from: area.minY + step / 2, to: area.maxY, by: step) {
        for x in stride(from: area.minX + step / 2, to: area.maxX, by: step) {
          guard let hit = root.hitTest(NSPoint(x: x, y: y)), Self.drawsNothing(hit), found[ObjectIdentifier(hit)] == nil else { continue }
          let box = hit.convert(hit.bounds, to: shell)
          found[ObjectIdentifier(hit)] = [
            "class": NSStringFromClass(type(of: hit)),
            "nativeID": (hit.responds(to: Selector(("nativeID"))) ? hit.value(forKey: "nativeID") as? String : nil) ?? NSNull(),
            "testID": hit.accessibilityIdentifier(),
            "reactTag": (hit.responds(to: Selector(("reactTag"))) ? hit.value(forKey: "reactTag") : nil) ?? NSNull(),
            "frame": [box.minX, box.minY, box.width, box.height],
            "at": [x, y],
            "ancestors": Self.reactAncestors(of: hit, below: root),
          ]
        }
      }
    }
    return Array(found.values)
  }

  private static func reactAncestors(of view: NSView, below root: NSView) -> [[Any]] {
    var out: [[Any]] = []
    for ancestor in sequence(first: view.superview, next: { $0?.superview }) {
      guard let ancestor, ancestor !== root, ancestor.responds(to: Selector(("reactTag"))), let tag = ancestor.value(forKey: "reactTag") as? NSNumber else { break }
      out.append([tag, ancestor.bounds.width, ancestor.bounds.height])
    }
    return out
  }

  private static func drawsNothing(_ view: NSView) -> Bool {
    let name = NSStringFromClass(type(of: view))
    guard name.hasPrefix("RCT"), !name.contains("Text"), !name.contains("Image") else { return false }
    if view.responds(to: Selector(("backgroundColor"))), let color = view.value(forKey: "backgroundColor") as? NSColor, (color.usingColorSpace(.sRGB)?.alphaComponent ?? 1) > 0 { return false }
    return view.layer?.contents == nil
  }
}
#endif

enum ShellLayoutPush {
  static func apply(_ given: [String: Any], to input: inout DockedLayoutInput, keepWidth: Bool = false) {
    let number = { (key: String) in (given[key] as? NSNumber).map { CGFloat($0.doubleValue) } }
    let flag = { (key: String) in (given[key] as? NSNumber)?.boolValue }
    if let dock = number("dock") { input.dock = dock }
    if !keepWidth, let width = number("sidebarWidth") { input.sidebarWidth = width }
    if let room = number("sidePanel") { input.sidePanel = max(0, room) }
    if let topTabs = flag("topTabs") { input.topTabs = topTabs }
    if let fullscreen = flag("fullscreen") { input.fullscreen = fullscreen }
    if let addressBar = flag("addressBarInSidebar") { input.addressBarInSidebar = addressBar }
    if let away = flag("away") { input.away = away }
  }
}

final class ShellStoreCommits: @unchecked Sendable {
  private let lock = NSLock()
  private var latest: Set<String>?
  private var scheduled = false

  func receive(_ ids: Set<String>) {
    if Thread.isMainThread {
      lock.withLock { latest = nil }
      MainActor.assumeIsolated { NativeWindowShell.windowsChanged(ids) }
      return
    }
    let schedule = lock.withLock { () -> Bool in
      latest = ids
      if scheduled { return false }
      scheduled = true
      return true
    }
    guard schedule else { return }
    DispatchQueue.main.async { [self] in
      let ids = lock.withLock { () -> Set<String>? in
        scheduled = false
        defer { latest = nil }
        return latest
      }
      guard let ids else { return }
      MainActor.assumeIsolated { NativeWindowShell.windowsChanged(ids) }
    }
  }
}

public class WindowShellModule: Module {
  public func definition() -> ModuleDefinition {
    Name("SolaraWindowShell")

    OnCreate {
      if Thread.isMainThread {
        MainActor.assumeIsolated { NativeWindowShell.install() }
      } else {
        DispatchQueue.main.async { MainActor.assumeIsolated { NativeWindowShell.install() } }
      }
    }

    Function("active") { (windowId: String) -> Bool in
      NativeWindowShell.enabled && NativeWindowShell.active(windowId)
    }

    Function("pagesPool") { () -> Bool in NativeSplitChrome.panesEnabled }
    Function("paneRoots") { (windowId: String) -> Bool in NativePaneRoots.active(windowId) }
    Function("mainOnTop") { (windowId: String) -> Bool in NativeWindowShell.mainOnTop && NativeWindowShell.active(windowId) }

    AsyncFunction("setBackdrop") { (windowId: String, json: String) in
      FrameUpdates.readOnMain { NativeWindowShell.setBackdrop(windowId, json) }
    }.runOnQueue(.main)

    AsyncFunction("setSidePanel") { (windowId: String, json: String?) in
      FrameUpdates.readOnMain { NativeWindowShell.host(windowId)?.setSidePanel(json) }
    }.runOnQueue(.main)

    AsyncFunction("setSheet") { (windowId: String, json: String?) in
      FrameUpdates.readOnMain { NativeSheets.set(windowId, json) }
    }.runOnQueue(.main)

    AsyncFunction("setLayout") { (windowId: String, layout: [String: Any]) in
      nonisolated(unsafe) let given = layout
      FrameUpdates.readOnMain {
        guard let shell = NativeWindowShell.host(windowId)?.shell else { return }
        if let right = given["peekRight"] as? NSNumber {
          NativeSidebarDock.setReactPeekRight(windowId, CGFloat(right.doubleValue))
        } else if given["sidebarWidth"] != nil {
          NativeSidebarDock.setReactPeekRight(windowId, 0)
        }
        var layout = given
        if !shell.widthDragActive, let width = (given["sidebarWidth"] as? NSNumber)?.doubleValue,
          NativeSidebarDock.railShown(windowId) || width == 84 {
          layout["sidebarWidth"] = SidebarRail.width
        }
        shell.update { ShellLayoutPush.apply(layout, to: &$0, keepWidth: shell.widthDragActive) }
      }
    }.runOnQueue(.main)

    AsyncFunction("setModal") { (windowId: String, owner: String, shown: Bool) in
      FrameUpdates.readOnMain { NativeWindowShell.host(windowId)?.shell.setModal(owner, shown: shown) }
    }.runOnQueue(.main)

    AsyncFunction("accessibilityReach") { (windowId: String) -> [String: Int]? in
      FrameUpdates.readOnMain { NativeWindowShell.host(windowId)?.shell.accessibilityReach() }
    }.runOnQueue(.main)

    AsyncFunction("devCover") { (windowId: String, rect: [Double]?, hidden: Bool?) -> Bool in
      #if DEBUG
      return FrameUpdates.readOnMain {
        guard let host = NativeWindowShell.host(windowId) else { return false }
        let id = NSUserInterfaceItemIdentifier("devCover")
        if let hidden, let cover = host.shell.overlay.subviews.first(where: { $0.identifier == id }) {
          cover.isHidden = hidden
          return true
        }
        host.shell.overlay.subviews.filter { $0.identifier == id }.forEach { $0.removeFromSuperview() }
        if let rect, rect.count == 4 {
          let cover = NSView(frame: CGRect(x: rect[0], y: rect[1], width: rect[2], height: rect[3]))
          cover.identifier = id
          cover.wantsLayer = true
          cover.layer?.backgroundColor = NSColor.systemPink.cgColor
          host.shell.overlay.addSubview(cover)
        }
        return true
      }
      #else
      return false
      #endif
    }.runOnQueue(.main)

    AsyncFunction("devRefusePaneRoot") { (tabId: String, refused: Bool) -> Bool in
      #if DEBUG
      return FrameUpdates.readOnMain {
        if refused { NativePaneRoots.refusedTabs.insert(tabId) } else { NativePaneRoots.refusedTabs.remove(tabId) }
        return true
      }
      #else
      return false
      #endif
    }.runOnQueue(.main)

    AsyncFunction("devLatePaneTeardown") { (seconds: Double) -> Bool in
      #if DEBUG
      return FrameUpdates.readOnMain {
        NativePaneRoots.lateTeardown = seconds
        return true
      }
      #else
      return false
      #endif
    }.runOnQueue(.main)

    AsyncFunction("devHitCost") { (windowId: String, x: Double, y: Double) -> [String: String] in
      #if DEBUG
      return FrameUpdates.readOnMain {
        guard let host = NativeWindowShell.host(windowId), host.shell.window != nil else { return [:] }
        let point = host.shell.convert(NSPoint(x: x, y: y), to: nil)
        let start = DispatchTime.now().uptimeNanoseconds
        var slot: WindowShellView.Slot?
        for _ in 0..<1000 { slot = host.shell.slotUnderPointer(at: point) }
        let micros = Double(DispatchTime.now().uptimeNanoseconds - start) / 1000 / 1000
        let result = ["micros": String(micros), "slot": slot?.rawValue ?? ""]
        #if SOLARA_PROBES
        WindowShellProbeSamples.hitCosts[windowId] = result
        #endif
        return result
      }
      #else
      return [:]
      #endif
    }.runOnQueue(.main)

    AsyncFunction("devLayerHitCosts") { (windowId: String, x: Double, y: Double) -> [[String: String]] in
      #if DEBUG
      return FrameUpdates.readOnMain {
        guard let host = NativeWindowShell.host(windowId), host.shell.window != nil else { return [] }
        let shell = host.shell
        let point = NSPoint(x: x, y: y)
        return shell.subviews.reversed().filter { !$0.isHidden }.map { layer in
          let start = DispatchTime.now().uptimeNanoseconds
          var hit: NSView?
          for _ in 0..<1000 { hit = layer.hitTest(point) }
          let micros = Double(DispatchTime.now().uptimeNanoseconds - start) / 1000 / 1000
          var views = 0
          func count(_ view: NSView) {
            views += 1
            view.subviews.forEach(count)
          }
          count(layer)
          return [
            "layer": shell.slot(of: layer)?.rawValue ?? NSStringFromClass(type(of: layer)), "micros": String(micros),
            "hit": hit.map { NSStringFromClass(type(of: $0)) } ?? "", "frame": NSStringFromRect(layer.frame), "views": String(views),
          ]
        }
      }
      #else
      return []
      #endif
    }.runOnQueue(.main)

    AsyncFunction("devPointerStream") { (windowId: String, points: [[Double]], hz: Double, promise: Promise) in
      #if DEBUG
      nonisolated(unsafe) let reply = promise
      FrameUpdates.readOnMain {
        guard let host = NativeWindowShell.host(windowId), let window = host.shell.window else { return reply.resolve([String: Double]()) }
        let shell = host.shell
        let inWindow = points.map { shell.convert(NSPoint(x: $0[0], y: $0[1]), to: nil) }
        shell.devResetPointerStats()
        let start = DispatchTime.now().uptimeNanoseconds
        Task { @MainActor in
          for point in inWindow {
            shell.devNotePointer(point)
            try? await Task.sleep(nanoseconds: UInt64(1e9 / hz))
          }
          try? await Task.sleep(nanoseconds: 50_000_000)
          let seconds = Double(DispatchTime.now().uptimeNanoseconds - start) / 1e9
          let result = [
            "moves": Double(inWindow.count), "lookups": Double(shell.devPointerLookups), "seconds": seconds,
            "frame": 1 / Double(window.screen?.maximumFramesPerSecond ?? 60),
            "lookupMicros": Double(shell.devPointerLookupNanos) / 1000, "coreShare": Double(shell.devPointerLookupNanos) / 1e9 / seconds,
          ]
          #if SOLARA_PROBES
          WindowShellProbeSamples.pointerStreams[windowId] = result
          #endif
          reply.resolve(result)
        }
      }
      #else
      promise.resolve([String: Double]())
      #endif
    }.runOnQueue(.main)

    AsyncFunction("devPointerLatency") { (windowId: String, x: Double, y: Double, promise: Promise) in
      #if DEBUG
      nonisolated(unsafe) let reply = promise
      FrameUpdates.readOnMain {
        guard let host = NativeWindowShell.host(windowId), let window = host.shell.window else { return reply.resolve([String: Any]()) }
        let shell = host.shell
        let start = DispatchTime.now().uptimeNanoseconds
        var answered = false
        let finish: (Bool) -> Void = { changed in
          guard !answered else { return }
          answered = true
          shell.devPointerResolved = nil
          let result: [String: Any] = [
            "changed": changed, "slot": x < 0 ? "" : shell.slotUnderPointer(at: shell.convert(NSPoint(x: x, y: y), to: nil))?.rawValue ?? "",
            "ms": Double(DispatchTime.now().uptimeNanoseconds - start) / 1e6, "frameMs": 1000 / Double(window.screen?.maximumFramesPerSecond ?? 60),
          ]
          #if SOLARA_PROBES
          WindowShellProbeSamples.pointerLatencies[windowId] = result
          #endif
          reply.resolve(result)
        }
        shell.devPointerResolved = { changed in finish(changed) }
        Task { @MainActor in
          try? await Task.sleep(nanoseconds: 1_000_000_000)
          finish(false)
        }
        shell.devNotePointer(x < 0 ? nil : shell.convert(NSPoint(x: x, y: y), to: nil))
      }
      #else
      promise.resolve([String: Any]())
      #endif
    }.runOnQueue(.main)

    Function("peekNative") { (windowId: String) -> Bool in NativePeek.enabled && NativeWindowShell.active(windowId) }

    AsyncFunction("peekClose") { (windowId: String) -> Bool in
      FrameUpdates.readOnMain { NativePeek.close(windowId) }
    }.runOnQueue(.main)

    AsyncFunction("peekExpand") { (windowId: String, promise: Promise) in
      nonisolated(unsafe) let reply = promise
      FrameUpdates.readOnMain { NativePeek.expand(windowId) { reply.resolve(true) } }
    }.runOnQueue(.main)

    AsyncFunction("devReactBlockers") { (windowId: String, step: Double) -> String in
      #if DEBUG
      return FrameUpdates.readOnMain {
        guard let host = NativeWindowShell.host(windowId), let data = try? JSONSerialization.data(withJSONObject: host.reactBlockers(step: step)) else { return "null" }
        return String(data: data, encoding: .utf8) ?? "null"
      }
      #else
      return "null"
      #endif
    }.runOnQueue(.main)

    AsyncFunction("describe") { (windowId: String) -> String in
      FrameUpdates.readOnMain {
        guard let info = NativeWindowShell.describe(windowId), let data = try? JSONSerialization.data(withJSONObject: info) else { return "null" }
        return String(data: data, encoding: .utf8) ?? "null"
      }
    }.runOnQueue(.main)
  }
}
