import AppKit
import SolaraShell
import ExpoModulesCore
import Foundation
import SolaraUI

public class DownloadsModule: Module {
  public func definition() -> ModuleDefinition {
    Name("SolaraDownloads")

    View(NativeDownloadsView.self) {
      Events("onDownloadsEvent", "onDownloadsHeight")

      Prop("state") { (view: NativeDownloadsView, v: String) in MainActor.assumeIsolated { view.setState(v) } }
    }

    AsyncFunction("devHoverShifts") { () -> String in
      MainActor.assumeIsolated { DownloadsHoverShifts.check() }
    }.runOnQueue(.main)

    AsyncFunction("devLastFileDrag") { () -> [String] in
      #if DEBUG
      return MainActor.assumeIsolated { DownloadsDrags.lastPaths }
      #else
      return []
      #endif
    }.runOnQueue(.main)
  }
}

final class NativeDownloadsView: ExpoView {
  let onDownloadsEvent = EventDispatcher()
  let onDownloadsHeight = EventDispatcher()
  let list = DownloadsListView(frame: .zero)
  private var json = ""

  override var isFlipped: Bool { true }

  required init(appContext: AppContext? = nil) {
    super.init(appContext: appContext)
    DownloadsHoverShifts.shown.add(list)
    list.autoresizingMask = [.width, .height]
    list.frame = bounds
    list.onHeight = { [weak self] h in self?.onDownloadsHeight(["height": h]) }
    list.onEvent = { [weak self] e in
      let (kind, id): (String, String?) =
        switch e {
        case .open(let id): ("open", id)
        case .reveal(let id): ("reveal", id)
        case .pause(let id): ("pause", id)
        case .resume(let id): ("resume", id)
        case .keep(let id): ("keep", id)
        case .cancel(let id): ("cancel", id)
        case .menu(let id): ("menu", id)
        case .clear: ("clear", nil)
        case .viewAll: ("viewAll", nil)
        }
      self?.onDownloadsEvent(["kind": kind, "id": id ?? NSNull()])
    }
    addSubview(list)
  }

  func setState(_ next: String) {
    guard next != json, let state = DownloadsListState.decode(next) else { return }
    json = next
    list.update(state)
  }
}

@MainActor
enum DownloadsHoverShifts {
  static let shown = NSHashTable<DownloadsListView>.weakObjects()

  static func check() -> String {
    #if DEBUG
    var hosts = 0
    var hovered = 0
    var shifts: [[String: Any]] = []
    let locked = (CGSessionCopyCurrentDictionary() as? [String: Any])?["CGSSessionScreenIsLocked"] as? Bool ?? false
    for root in shown.allObjects where root.window != nil {
      hosts += 1
      root.layoutSubtreeIfNeeded()
      if locked { for view in descendants(of: root) { view.updateTrackingAreas() } }
      for target in descendants(of: root) where target.trackingAreas.contains(where: { $0.owner === target }) {
        guard let enter = event(.mouseEntered, in: target), let exit = event(.mouseExited, in: target) else { continue }
        hovered += 1
        let before = frames(in: root)
        target.mouseEntered(with: enter)
        root.layoutSubtreeIfNeeded()
        let after = frames(in: root)
        target.mouseExited(with: exit)
        root.layoutSubtreeIfNeeded()
        for (id, was) in before {
          guard let now = after[id], moved(was.frame, now.frame), !labelMakesRoom(was.view, was.frame, now.frame) else { continue }
          shifts.append(["hovered": name(target), "view": name(was.view), "before": rect(was.frame), "after": rect(now.frame)])
        }
      }
    }
    let json = try? JSONSerialization.data(withJSONObject: ["hosts": hosts, "hovered": hovered, "shifts": shifts, "forced": locked ? "locked" as Any : NSNull()])
    return json.flatMap { String(data: $0, encoding: .utf8) } ?? "{}"
    #else
    return "{}"
    #endif
  }

  private static func descendants(of view: NSView) -> [NSView] {
    view.subviews.flatMap { [$0] + descendants(of: $0) }
  }

  private static func frames(in root: NSView) -> [ObjectIdentifier: (view: NSView, frame: NSRect)] {
    var out: [ObjectIdentifier: (view: NSView, frame: NSRect)] = [:]
    for view in descendants(of: root) where !view.isHiddenOrHasHiddenAncestor && view.alphaValue > 0 {
      out[ObjectIdentifier(view)] = (view, view.convert(view.bounds, to: root))
    }
    return out
  }

  private static func event(_ type: NSEvent.EventType, in view: NSView) -> NSEvent? {
    NSEvent.enterExitEvent(
      with: type, location: view.convert(NSPoint(x: view.bounds.midX, y: view.bounds.midY), to: nil), modifierFlags: [],
      timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: view.window?.windowNumber ?? 0, context: nil,
      eventNumber: 0, trackingNumber: 0, userData: nil)
  }

  private static func moved(_ a: NSRect, _ b: NSRect) -> Bool {
    abs(a.minX - b.minX) > 0.01 || abs(a.minY - b.minY) > 0.01 || abs(a.width - b.width) > 0.01 || abs(a.height - b.height) > 0.01
  }

  private static func labelMakesRoom(_ view: NSView, _ a: NSRect, _ b: NSRect) -> Bool {
    let label = view is NSTextField || view.superview is NSTextField
    return label && abs(a.minX - b.minX) <= 0.01 && abs(a.minY - b.minY) <= 0.01 && abs(a.height - b.height) <= 0.01 && b.width < a.width
  }

  private static func rect(_ r: NSRect) -> [Double] { [r.minX, r.minY, r.width, r.height].map { Double($0) } }

  private static func name(_ view: NSView) -> String {
    let label = (view as? NSTextField)?.stringValue ?? view.accessibilityLabel() ?? ""
    return label.isEmpty ? String(describing: type(of: view)) : "\(type(of: view)) \"\(label)\""
  }
}

#if SOLARA_PROBES
@MainActor
extension DownloadsHoverShifts {
  private static func probeRoots(windowId: String) -> [DownloadsListView] {
    guard let number = WindowHost.window(id: windowId)?.windowNumber else { return [] }
    return shown.allObjects.filter { $0.window?.windowNumber == number }.sorted { String(describing: ObjectIdentifier($0)) < String(describing: ObjectIdentifier($1)) }
  }

  private static func probeViews(_ root: NSView) -> [(String, NSView)] {
    var result: [(String, NSView)] = []
    func walk(_ parent: NSView, _ path: String) {
      for (index, view) in parent.subviews.enumerated() {
        let key = path.isEmpty ? "\(index)" : "\(path)/\(index)"
        result.append((key, view))
        walk(view, key)
      }
    }
    walk(root, "")
    return result
  }

  static func probeSnapshot(windowId: String) -> [String: Any] {
    let roots = probeRoots(windowId: windowId)
    var targets: [String] = []
    var frames: [[String: Any]] = []
    for (index, root) in roots.enumerated() {
      for (path, view) in probeViews(root) {
        let id = "\(index)/\(path)"
        if view.trackingAreas.contains(where: { $0.owner === view }) { targets.append(id) }
        if !view.isHiddenOrHasHiddenAncestor && view.alphaValue > 0 {
          frames.append(["id": id, "frame": rect(view.convert(view.bounds, to: root)), "label": view is NSTextField || view.superview is NSTextField])
        }
      }
    }
    return ["hosts": roots.count, "targets": targets, "frames": frames]
  }

  static func probeHover(windowId: String, key: String, on: Bool) -> Bool {
    let roots = probeRoots(windowId: windowId)
    let parts = key.split(separator: "/", maxSplits: 1).map(String.init)
    guard parts.count == 2, let index = Int(parts[0]), roots.indices.contains(index),
      let target = probeViews(roots[index]).first(where: { $0.0 == parts[1] })?.1,
      target.trackingAreas.contains(where: { $0.owner === target }),
      let input = event(on ? .mouseEntered : .mouseExited, in: target) else { return false }
    if on { target.mouseEntered(with: input) } else { target.mouseExited(with: input) }
    roots[index].layoutSubtreeIfNeeded()
    return true
  }
}
#endif

#if SOLARA_PROBES
@MainActor
public enum DownloadDragRead {
  public static var urls: [String] { DownloadsDrags.lastPaths.prefix(16).map { URL(fileURLWithPath: $0).absoluteString } }
}
#endif
