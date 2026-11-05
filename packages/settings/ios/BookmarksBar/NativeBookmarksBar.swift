import AppKit
import Foundation
import SolaraModel
import SolaraStore
import SolaraUI

@MainActor
enum NativeBookmarksBar {
  nonisolated static let kind = "bookmarksBar"

  nonisolated static var enabled: Bool {
    LaunchSwitches.shared.isOn(.nativeBookmarksBar)
  }

  static func register() {
    guard enabled else { return }
    HostedViews.register(kind) { windowId, state in
      let host = BookmarksBarHost(windowId: windowId)
      host.apply(state)
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
  }

  func apply(_ json: String) {
    guard let data = json.data(using: .utf8),
      let snapshot = try? JSONDecoder().decode(BookmarksBarSnapshot.self, from: data) else { return }
    view.update(snapshot)
  }
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
