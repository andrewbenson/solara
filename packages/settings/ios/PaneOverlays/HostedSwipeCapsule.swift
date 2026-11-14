import AppKit
import Foundation
import SolaraUI

@MainActor
enum HostedSwipeCapsule {
  static let kind = "swipeCapsule"
  private static var registered = false
  private static var mounts: [String: [String: [Mount]]] = [:]
  private static let favicons: SidebarFavicons = {
    let made = SidebarFavicons()
    made.loader = { request in try await NativeSidebar.favicon(request) }
    return made
  }()

  private final class Mount {
    let windowId: String
    var tabId = ""
    var markUri: String?
    weak var capsule: SwipeCapsuleView?

    init(windowId: String, capsule: SwipeCapsuleView) {
      self.windowId = windowId
      self.capsule = capsule
    }
  }

  static func register() {
    guard !registered else { return }
    registered = true
    HostedViews.register(kind) { windowId, state in
      let capsule = SwipeCapsuleView(frame: .zero)
      capsule.favicons = favicons
      let mount = Mount(windowId: windowId, capsule: capsule)
      apply(state, to: mount)
      return HostedContent(view: capsule, onUnmount: {
        remove(mount)
      }, takesFocus: false, onState: { state in
        apply(state, to: mount)
      })
    }
  }

  private static func apply(_ json: String, to mount: Mount) {
    let data = json.data(using: .utf8)
    let value = data.flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] }
    if let uri = value?["newTabMark"] as? String, uri != mount.markUri, let capsule = mount.capsule {
      mount.markUri = uri
      loadMark(uri, into: capsule)
    }
    let tabId = value?["tabId"] as? String ?? ""
    guard tabId != mount.tabId else { return }
    let changingTab = !mount.tabId.isEmpty
    remove(mount)
    if changingTab { mount.capsule?.dismiss() }
    mount.tabId = tabId
    guard !tabId.isEmpty else { return }
    mounts[mount.windowId, default: [:]][tabId, default: []].append(mount)
  }

  private static func remove(_ mount: Mount) {
    guard var tabs = mounts[mount.windowId], let entries = tabs[mount.tabId] else { return }
    let remaining = entries.filter { $0 !== mount && $0.capsule != nil }
    if remaining.isEmpty { tabs[mount.tabId] = nil }
    else { tabs[mount.tabId] = remaining }
    if tabs.isEmpty { mounts[mount.windowId] = nil }
    else { mounts[mount.windowId] = tabs }
  }

  private static func latest(_ windowId: String, _ tabId: String) -> SwipeCapsuleView? {
    mounts[windowId]?[tabId]?.reversed().compactMap(\.capsule).first { $0.window != nil && !$0.isHiddenOrHasHiddenAncestor }
  }

  @discardableResult
  static func send(_ windowId: String, _ tabId: String, _ message: [String: Any]) -> Bool {
    guard let capsule = latest(windowId, tabId) else { return false }
    let number = { (key: String) -> CGFloat? in (message[key] as? NSNumber).map { CGFloat($0.doubleValue) } }
    switch message["op"] as? String {
    case "show":
      loadMark(message["newTabMark"] as? String, into: capsule)
      let theme = message["theme"] as? [String: Any] ?? [:]
      let direction = SwipeCapsuleDirection(rawValue: message["direction"] as? String ?? "") ?? .back
      capsule.show(direction, theme: SwipeCapsuleTheme(dark: theme["dark"] as? Bool ?? false, textPrimary: theme["textPrimary"] as? String ?? "#000000D9", textSecondary: theme["textSecondary"] as? String ?? "#00000080"), profileId: message["profileId"] as? String ?? "")
    case "move": capsule.move(x: number("x"), nudge: number("nudge"))
    case "confirm": capsule.setConfirmed(message["confirmed"] as? Bool ?? false)
    case "list":
      let items = (message["items"] as? [[String: Any]] ?? []).map { SwipeCapsuleItem(title: $0["title"] as? String ?? "", url: $0["url"] as? String ?? "", favicon: $0["favicon"] as? String, newTab: $0["newTab"] as? Bool ?? false) }
      capsule.presentList(items)
    case "select":
      capsule.move(nudge: number("nudge"))
      capsule.select(message["index"] as? Int ?? 0)
    case "dismiss": capsule.dismiss(delay: (message["delay"] as? NSNumber)?.doubleValue ?? 0)
    default: return false
    }
    return true
  }

  static func loadMark(_ uri: String?, into capsule: SwipeCapsuleView) {
    guard let uri else { return }
    if let image = SettingsAdapters.image(uri) {
      image.isTemplate = true
      capsule.favicons?.newTabMark = image
      return capsule.rebuildIcons()
    }
    guard let url = URL(string: uri) else { return }
    Task { @MainActor [weak capsule] in
      let image = await Task.detached { (try? Data(contentsOf: url)).flatMap(NSImage.init(data:)) }.value
      guard let capsule, let image else { return }
      image.isTemplate = true
      capsule.favicons?.newTabMark = image
      capsule.rebuildIcons()
    }
  }

  #if DEBUG
    static func describe(_ windowId: String) -> [String: Any]? {
      guard let entries = mounts[windowId] else { return nil }
      var tabs: [String: [String: Any]] = [:]
      for tabId in entries.keys {
        guard let capsule = latest(windowId, tabId) else { continue }
        let sample = capsule.sample()
        func inWindow(_ rect: CGRect) -> [Double] {
          let frame = capsule.convert(rect, to: nil)
          let height = capsule.window?.contentView?.bounds.height ?? 0
          return [frame.minX, height - frame.maxY, frame.width, frame.height]
        }
        tabs[tabId] = ["swipe": ["shown": capsule.shown, "active": capsule.active, "direction": capsule.direction.rawValue, "confirmed": capsule.confirmed, "items": capsule.items?.map(\.title) ?? NSNull(), "selected": capsule.selected, "newTabMark": capsule.favicons?.newTabMark != nil,
          "frame": inWindow(sample.frame), "area": inWindow(capsule.bounds), "radius": sample.radius, "opacity": sample.opacity, "scale": sample.scale, "iconScale": sample.iconScale, "list": sample.list, "pill": sample.pill]]
      }
      return tabs.isEmpty ? nil : ["top": false, "inCard": false, "tabs": tabs]
    }
  #endif
}
