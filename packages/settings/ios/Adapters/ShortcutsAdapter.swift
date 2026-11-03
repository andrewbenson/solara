import AppKit
import Foundation
import SolaraUI

@MainActor
final class ShortcutsAdapter: ShortcutsServices {
  func menuShortcuts() async -> [MenuShortcutItem] {
    let list = await SettingsAdapters.js("shortcuts.menuShortcuts") as? [[String: Any]] ?? []
    return list.compactMap(Self.item)
  }

  func menuShortcutChanges() -> AsyncStream<Void> {
    AsyncStream { continuation in
      let token = NotificationCenter.default.addObserver(forName: .init("SolaraMenuShortcutsChanged"), object: nil, queue: .main) { _ in
        continuation.yield()
      }
      let box = ObserverToken(token)
      continuation.onTermination = { _ in NotificationCenter.default.removeObserver(box.token) }
    }
  }

  func openURLs(_ urls: [String]) { SettingsJS.shared.fire("app.openUrls", urls) }

  static func item(_ dict: [String: Any]) -> MenuShortcutItem? {
    guard let id = dict.string("id") else { return nil }
    let defaultKey = dict.string("defaultKey") ?? ""
    return MenuShortcutItem(
      id: id,
      title: dict.string("title") ?? id,
      path: dict.strings("path"),
      defaultShortcut: defaultKey.isEmpty ? .empty : KeyShortcut(stored: [defaultKey] + dict.strings("defaultModifiers")),
      remappable: dict.bool("remappable") ?? false,
      aliases: dict["aliases"] as? [[String]] ?? [],
      defaultPrecedence: dict.string("defaultPrecedence").flatMap(ShortcutPrecedence.init(rawValue:)),
      precedenceFixed: dict.bool("precedenceFixed") ?? false
    )
  }
}

private final class ObserverToken: @unchecked Sendable {
  let token: NSObjectProtocol

  init(_ token: NSObjectProtocol) { self.token = token }
}
