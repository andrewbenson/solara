import AppKit
import Foundation
import SolaraModel
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
      return HostedContent(view: host.view, takesFocus: false, onState: { host.apply($0) })
    }
  }
}

@MainActor
private final class BookmarksBarHost {
  let view: BookmarksBarView

  init(windowId: String) {
    view = BookmarksBarView(favicons: PageNetwork.favicons)
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
