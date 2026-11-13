import AppKit
import ExpoModulesCore
import SolaraShell
import SolaraModel
import SolaraStore
import SolaraUI

public class SidebarDragModule: Module {
  public func definition() -> ModuleDefinition {
    Name("SolaraSidebarDrag")

    OnCreate {
      DispatchQueue.main.async {
        MainActor.assumeIsolated {
          SidebarDragHub.bridge = NativeSidebarDrag.shared
          ShellDragEscape.swallows = { SidebarDragHub.escapeCaptureSwallows($0, cancel: $1) }
        }
      }
    }

    AsyncFunction("tabDrag") { (onPage: Bool, insert: Bool) in
      FrameUpdates.readOnMain { NativeTabDrag.shared.pageChanged(onPage: onPage, insert: insert) }
    }.runOnQueue(.main)

    AsyncFunction("escape") {
      FrameUpdates.readOnMain { SidebarDragHub.escape() }
    }.runOnQueue(.main)

    AsyncFunction("external") { (windowId: String, phase: String, x: Double, y: Double, count: Int) -> String? in
      FrameUpdates.readOnMain { NativeSidebarDrag.external(windowId: windowId, phase: phase, at: CGPoint(x: x, y: y), count: count) }
    }.runOnQueue(.main)

    AsyncFunction("startProbe") { (windowId: String) -> String in
      FrameUpdates.readOnMain { NativeSidebarDrag.startProbe(windowId) }
    }.runOnQueue(.main)

    Function("probe") { (windowId: String) -> String in
      NativeSidebarDrag.cached(windowId)
    }

    AsyncFunction("clearLanded") { (windowId: String) in
      FrameUpdates.readOnMain {
        SidebarDragHub.controller(windowId: windowId)?.clearLanded()
        NativeSidebarDrag.refresh(windowId)
      }
    }.runOnQueue(.main)

    AsyncFunction("trace") { (identifier: String, milliseconds: Double) in
      FrameUpdates.readOnMain { SidebarDragTrace.shared.start(identifier, milliseconds: milliseconds) }
    }.runOnQueue(.main)

    AsyncFunction("traceSamples") { () -> String in
      FrameUpdates.readOnMain {
        let data = (try? JSONSerialization.data(withJSONObject: SidebarDragTrace.shared.samples)) ?? Data("[]".utf8)
        return String(decoding: data, as: UTF8.self)
      }
    }.runOnQueue(.main)

    AsyncFunction("scrollTo") { (windowId: String, y: Double) in
      FrameUpdates.readOnMain {
        guard let page = NativeSidebarDrag.page(windowId) else { return }
        SidebarDragController.of(page).scroll(to: y)
        NativeSidebarDrag.refresh(windowId)
      }
    }.runOnQueue(.main)
  }
}

@MainActor
final class NativeSidebarDrag: SidebarDragBridge {
  static let shared = NativeSidebarDrag()

  private var drag: NativeTabDrag { .shared }
  private var pointer = CGPoint.zero

  private func send(_ name: String, _ args: [Any]) { drag.send(name, args) }

  func dragBegan(windowId: String, tabId: String?, tabIds: [String]) {
    drag.begin(windowId: windowId, tabId: tabId, tabIds: tabIds) { [weak self] in
      if SidebarDragHub.cancel(windowId: windowId) { return true }
      self?.escapeCapture(false)
      return false
    }
  }

  func dragPicture(windowId: String, size: CGSize, grab: CGPoint) {
    drag.picture(windowId: windowId, chip: { [weak self] in
      guard let self else { return .zero }
      return NSRect(x: self.pointer.x - grab.x, y: self.pointer.y - grab.y, width: size.width, height: size.height)
    }, grab: grab)
  }

  func dragMoved(windowId: String, x: CGFloat, y: CGFloat) {
    pointer = CGPoint(x: x, y: y)
    drag.move(windowId: windowId, at: pointer)
  }

  func dragEnded(windowId: String, commit: Bool, done: @escaping @MainActor (Bool) -> Void) {
    drag.end(windowId: windowId, commit: commit, done: done)
  }

  func drop(windowId: String, ids: [String], drop: JSONValue, sequence: [String]?) {
    if let store = NativeStoreHandle.store {
      _ = try? store.dispatch(Command("dropTabs", [JSONValue(ids), drop]), origin: .native)
      FrameUpdates.flush()
    }
    if let sequence, sequence.contains(where: { $0.hasPrefix(SidebarLive.prefix) }) {
      send("sidebar.drag.live", [sequence])
    }
  }

  private(set) var escaping = false

  func escapeCapture(_ on: Bool) {
    escaping = on
    send("sidebar.drag.escape", [on])
  }

  func haptic() { send("sidebar.drag.haptic", []) }

  func closeFolderPanel(windowId: String) { send("sidebar.drag.closePanel", [windowId]) }

  func changed(windowId: String) {
    if SidebarDragHub.probing { Self.refreshSoon(windowId) }
  }

  nonisolated(unsafe) private static let lock = NSLock()
  nonisolated(unsafe) private static var snapshots: [String: String] = [:]

  nonisolated static func cached(_ windowId: String) -> String {
    lock.withLock { snapshots[windowId] ?? "null" }
  }

  static func page(_ windowId: String) -> SidebarView? {
    NativeSidebar.hosts[windowId]?.view.current
  }

  static func startProbe(_ windowId: String) -> String {
    SidebarDragHub.probing = true
    return refresh(windowId)
  }

  private static var pendingRefresh: Set<String> = []

  static func refreshSoon(_ windowId: String) {
    if let page = page(windowId), SidebarDragController.existing(page)?.active == true {
      refresh(windowId)
      return
    }
    guard pendingRefresh.insert(windowId).inserted else { return }
    DispatchQueue.main.asyncAfter(deadline: .now() + .milliseconds(80)) {
      MainActor.assumeIsolated {
        pendingRefresh.remove(windowId)
        refresh(windowId)
      }
    }
  }

  @discardableResult
  static func refresh(_ windowId: String) -> String {
    guard let page = page(windowId) else { return "null" }
    let controller = SidebarDragController.of(page)
    var probe = controller.probe()
    probe["folderPanel"] = controller.foreignFolder
    probe["escaping"] = shared.escaping
    probe["lastDrop"] = NativeTabDrag.shared.lastDrop
    let json = (try? JSONSerialization.data(withJSONObject: probe)).map { String(decoding: $0, as: UTF8.self) } ?? "null"
    lock.withLock { snapshots[windowId] = json }
    return json
  }

  static func external(windowId: String, phase: String, at: CGPoint, count: Int) -> String? {
    guard let page = page(windowId) else { return nil }
    let controller = SidebarDragController.of(page)
    defer { if SidebarDragHub.probing { refresh(windowId) } }
    switch phase {
    case "enter":
      controller.beginExternal(count: count, at: at)
    case "move":
      controller.moveExternal(at)
    case "leave":
      _ = controller.finishExternal(commit: false)
    case "drop":
      controller.moveExternal(at)
      guard let placement = controller.finishExternal(commit: true) else { return nil }
      return placement.dragText
    default:
      break
    }
    return nil
  }

}

#if SOLARA_PROBES
@MainActor
public enum SidebarDragRead {
  public static func snapshot(windowId: String) -> [String: Any]? {
    guard let page = NativeSidebarDrag.page(windowId), let controller = SidebarDragController.existing(page) else { return nil }
    var result = controller.probe()
    result["folderPanel"] = controller.foreignFolder
    result["escaping"] = NativeSidebarDrag.shared.escaping
    result["lastDrop"] = NativeTabDrag.shared.lastDrop
    return result
  }
}
#endif
