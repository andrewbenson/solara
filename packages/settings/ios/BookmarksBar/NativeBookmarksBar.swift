import AppKit
import Foundation
import SolaraEngine
import SolaraShell
import SolaraModel
import SolaraStore
import SolaraUI

@MainActor
enum NativeBookmarksBar {
  nonisolated static let kind = "bookmarksBar"

  nonisolated static var enabled: Bool {
    LaunchSwitches.shared.isOn(.nativeBookmarksBar)
  }

  static func registerMenuSource() {
    NativeBookmarkMenuSource.read = { profile in
      nonisolated(unsafe) var result: [String: Any]?
      MainActor.assumeIsolated {
        guard let owner = NativeBookmarkOwner.displayCurrent, let snapshot = try? owner.snapshot(profile: profile), snapshot.hasView else { return }
        result = bookmarkMenus(snapshot.document, profile: profile, engine: snapshot.binding.engine)
      }
      return result
    }
  }

  static func bookmarkMenus(_ document: JSONValue, profile: String, engine: String) -> [String: Any] {
    let nodes = document["nodes"]?.object ?? [:]
    let roots = BookmarkFlat.roots(engine)
    let bar = document["roots"]?[profile]?["bar"]?.string ?? roots.bar
    let other = document["roots"]?[profile]?["other"]?.string ?? roots.other
    func children(_ id: String) -> [String] { nodes[id]?["children"]?.array?.compactMap(\.string).filter { nodes[$0] != nil } ?? [] }
    func tree(_ parent: String, depth: Int = 0) -> [[String: Any]] {
      children(parent).compactMap { id in
        guard let node = nodes[id] else { return nil }
        let title = node["title"]?.string ?? ""
        if node["kind"] == "url" { return ["id": id, "title": title.isEmpty ? node["url"]?.string ?? "" : title, "url": node["url"]?.string ?? ""] }
        return ["id": id, "title": title, "children": depth < 6 ? tree(id, depth: depth + 1) : []]
      }
    }
    let rootKeys: Set<JSKey> = [JSKey(bar), JSKey(other)]
    func belongs(_ id: String) -> Bool {
      var current: String? = id
      var seen = Set<JSKey>()
      var depth = 0
      while let id = current, depth < 64, seen.insert(JSKey(id)).inserted {
        depth += 1
        if rootKeys.contains(JSKey(id)) { return true }
        current = nodes[id]?["parentId"]?.string
      }
      return false
    }
    let recent = nodes.enumerated().filter { $0.element.value["kind"] == "url" && belongs($0.element.key) }.sorted {
      let a = $0.element.value["addedAt"]?.number ?? 0, b = $1.element.value["addedAt"]?.number ?? 0
      return a == b ? $0.offset < $1.offset : a > b
    }.prefix(5).map { entry -> [String: Any] in
      let node = entry.element.value, url = node["url"]?.string ?? "", title = node["title"]?.string ?? ""
      return ["id": entry.element.key, "title": title.isEmpty ? url : title, "url": url]
    }
    let folders: [[String: Any]] = [["id": bar, "title": "Bookmarks Bar"], ["id": other, "title": "Other Bookmarks"]]
      + (children(bar) + children(other)).filter { nodes[$0]?["kind"] == "folder" }.map { ["id": $0, "title": nodes[$0]?["title"]?.string ?? ""] }
    return ["bookmarkFolders": folders, "recentBookmarks": recent, "bookmarksBar": tree(bar), "otherBookmarks": tree(other)]
  }

  static func register() {
    guard enabled else { return }
    HostedViews.register(kind) { windowId, state in
      let host = BookmarksBarHost(windowId: windowId)
      host.apply(state)
      let environment = ProcessInfo.processInfo.environment
      if !LaunchSwitches.shared.distribution, environment["AC_BENCH_BOOKMARKS"] == "1",
        environment["SOLARA_BACKGROUND"] == "1", environment["SOLARA_DATA_DIR"]?.isEmpty == false { scaleHosts[windowId] = BookmarkScaleHost(host) }
      #if DEBUG
      devHosts[windowId] = BookmarksBarDevHost(host)
      return HostedContent(view: host.view, onUnmount: { [weak host] in
        if devHosts[windowId]?.value === host { devHosts[windowId] = nil }
      }, takesFocus: false, onState: { host.apply($0) })
      #else
      return HostedContent(view: host.view, takesFocus: false, onState: { host.apply($0) })
      #endif
    }
  }
}

@MainActor
private final class BookmarksBarHost {
  let view: BookmarksBarView
  private var metadata: BookmarksBarSnapshot?
  private var bookmarkObserver: NSObjectProtocol?

  init(windowId: String) {
    view = BookmarksBarView(favicons: PageNetwork.favicons)
    view.windowId = windowId
    view.resolveTab = { id in
      guard let tab = NativeStoreHandle.store?.state.tabs[id] else { return nil }
      return BookmarksBarDroppedLink(url: tab.url, title: tab.title)
    }
    view.onFocusPage = {
      HostedViews.send(NativeBookmarksBar.kind, windowId: windowId, "focusPage", [:])
    }
    view.onAction = { name, payload in
      HostedViews.send(NativeBookmarksBar.kind, windowId: windowId, name, payload)
    }
    bookmarkObserver = NotificationCenter.default.addObserver(forName: NativeBookmarkOwner.projectionChanged, object: nil, queue: .main) { [weak self] _ in
      MainActor.assumeIsolated { self?.refresh() }
    }
  }

  func apply(_ json: String) {
    guard let data = json.data(using: .utf8),
      let snapshot = try? JSONDecoder().decode(BookmarksBarSnapshot.self, from: data) else { return }
    if let state = try? JSONSerialization.jsonObject(with: data) as? [String: Any], state["nativeSource"] as? Bool == true {
      metadata = snapshot
      refresh()
    } else {
      metadata = nil
      view.update(snapshot)
    }
  }

  private func refresh() {
    guard let metadata else { return }
    guard let owner = NativeBookmarkOwner.displayCurrent, let snapshot = try? owner.snapshot(profile: metadata.profileId) else {
      view.update(metadata)
      return
    }
    view.update(snapshot.hasView ? metadata.reading(snapshot.document, engine: snapshot.binding.engine) : metadata)
  }

  isolated deinit { if let bookmarkObserver { NotificationCenter.default.removeObserver(bookmarkObserver) } }
}

#if DEBUG
@MainActor
extension NativeBookmarksBar {
  private static var devHosts: [String: BookmarksBarDevHost] = [:]

  static func devLayout(windowId: String) -> [String: Any]? {
    guard let view = devHosts[windowId]?.value?.view, view.window != nil, !view.isHiddenOrHasHiddenAncestor else { return nil }
    view.layoutSubtreeIfNeeded()
    return view.devLayout()
  }

  static func devLayoutJSON(windowId: String) -> String {
    guard let layout = devLayout(windowId: windowId), let data = try? JSONSerialization.data(withJSONObject: layout) else { return "null" }
    return String(decoding: data, as: UTF8.self)
  }

  static func devMenuJSON(windowId: String, trigger: String, id: String?) -> String {
    guard let view = devHosts[windowId]?.value?.view, view.window != nil, !view.isHiddenOrHasHiddenAncestor,
      let data = try? JSONSerialization.data(withJSONObject: view.devMenu(trigger: trigger, id: id)) else { return "null" }
    return String(decoding: data, as: UTF8.self)
  }

  static func devChooseJSON(windowId: String, trigger: String, id: String?, choiceId: String) -> String {
    guard let view = devHosts[windowId]?.value?.view, view.window != nil, !view.isHiddenOrHasHiddenAncestor,
      let data = try? JSONSerialization.data(withJSONObject: view.devChoose(trigger: trigger, id: id, choiceId: choiceId)) else { return #"{"accepted":false}"# }
    return String(decoding: data, as: UTF8.self)
  }

  static func devKeyJSON(windowId: String, key: String, id: String?, modifiers: Int, fullKeyboardAccess: Bool) -> String {
    guard let view = devHosts[windowId]?.value?.view, view.window != nil, !view.isHiddenOrHasHiddenAncestor,
      let data = try? JSONSerialization.data(withJSONObject: view.devKey(key: key, id: id, flags: NSEvent.ModifierFlags(rawValue: UInt(bitPattern: modifiers)), fullKeyboardAccess: fullKeyboardAccess)) else { return "null" }
    return String(decoding: data, as: UTF8.self)
  }

  static func devAccessibilityJSON(windowId: String) -> String {
    guard let view = devHosts[windowId]?.value?.view, view.window != nil, !view.isHiddenOrHasHiddenAncestor,
      let data = try? JSONSerialization.data(withJSONObject: view.devAccessibility()) else { return "null" }
    return String(decoding: data, as: UTF8.self)
  }

  static func devDropJSON(windowId: String, x: Double, folderId: String?, payload: String) -> String {
    guard let view = devHosts[windowId]?.value?.view, view.window != nil, !view.isHiddenOrHasHiddenAncestor,
      let data = try? JSONSerialization.data(withJSONObject: view.devDrop(x: CGFloat(x), folderId: folderId, payload: payload)) else { return #"{"accepted":false}"# }
    return String(decoding: data, as: UTF8.self)
  }

  static func devInput(windowId: String, action: String, id: String?, modifiers: Int, x: Double?) -> Bool {
    guard let view = devHosts[windowId]?.value?.view, view.window != nil, !view.isHiddenOrHasHiddenAncestor else { return false }
    view.layoutSubtreeIfNeeded()
    return view.devInput(action: action, id: id, flags: NSEvent.ModifierFlags(rawValue: UInt(bitPattern: modifiers)), x: x.map { CGFloat($0) })
  }
}

@MainActor
private final class BookmarksBarDevHost {
  weak var value: BookmarksBarHost?

  init(_ value: BookmarksBarHost) { self.value = value }
}
#endif

@MainActor
extension NativeBookmarksBar {
  private static var scaleHosts: [String: BookmarkScaleHost] = [:]

  static func scaleJSON(windowId: String, operation: String, value: String?) -> String {
    guard let view = scaleHosts[windowId]?.value?.view, let window = view.window, !view.isHiddenOrHasHiddenAncestor else { return "null" }
    var output: [String: Any]
    if operation == "menu" {
      output = view.benchmarkMenu(trigger: value ?? "overflow", id: nil)
    } else {
      if operation == "resize", let width = value.flatMap(Double.init) {
        var frame = window.frame
        frame.size.width = width
        window.setFrame(frame, display: true)
      }
      output = view.benchmarkLayout()
    }
    output["selectionSequence"] = scaleHosts[windowId]?.selectionSequence ?? 0
    output["selectedTabId"] = scaleHosts[windowId]?.selectedTabId as Any? ?? NSNull()
    guard let data = try? JSONSerialization.data(withJSONObject: output) else { return "null" }
    return String(decoding: data, as: UTF8.self)
  }
}

@MainActor
private final class BookmarkScaleHost {
  weak var value: BookmarksBarHost?
  var selectionSequence = 0
  var selectedTabId: String?
  private var selectionObserver: NSObjectProtocol?

  init(_ value: BookmarksBarHost) {
    self.value = value
    selectionObserver = NotificationCenter.default.addObserver(forName: SidebarView.selectionShown, object: nil, queue: .main) { [weak self] note in
      nonisolated(unsafe) let sidebar = note.object as? SidebarView
      MainActor.assumeIsolated {
        guard let self, let sidebar, sidebar.windowId == self.value?.view.windowId,
          let window = NativeStoreHandle.store?.state.windows[sidebar.windowId] else { return }
        self.selectionSequence += 1
        self.selectedTabId = window.activeTabIds[window.profileId]
      }
    }
  }

  isolated deinit { if let selectionObserver { NotificationCenter.default.removeObserver(selectionObserver) } }
}
