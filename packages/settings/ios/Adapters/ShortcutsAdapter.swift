import AppKit
import Foundation
import SolaraModel
import SolaraShell
import SolaraStore
import SolaraUI

@MainActor
final class ShortcutsAdapter: ShortcutsServices {
  private static var lifecycle: Int?
  private static weak var store: Store?
  private static var listener: Int?
  private static var menuObserver: NSObjectProtocol?
  private static var snapshot = CommandShortcutSnapshot(resolvedHints: [:])

  static func install() {
    guard lifecycle == nil else { return }
    captureHints()
    menuObserver = NotificationCenter.default.addObserver(forName: .init("SolaraMenuShortcutsChanged"), object: nil, queue: .main) { _ in
      guard MainActor.assumeIsolated({ captureHints() }) else { return }
      Task { @MainActor in
        NativeToolbarPresenter.refreshContributions()
        NativeSidebar.refreshShortcutHints()
        NativeTopStrip.refreshShortcutHints()
        NativeLayoutChrome.presentationChanged()
      }
    }
    lifecycle = NativeStoreHandle.subscribeLifecycle { bindStore() }
  }

  private static func bindStore() {
    let current = NativeStoreHandle.ownsWorkspace ? NativeStoreHandle.store : nil
    guard store !== current else { return }
    if let listener { store?.unsubscribe(listener) }
    store = current
    listener = current?.subscribe { [weak current] commit in
      let keys: Set<String> = ["shortcuts", "shortcutPrecedence"]
      guard commit.changes.settingsChanged.contains(where: keys.contains) || commit.changes.settingsRemoved.contains(where: keys.contains) else { return }
      Task { @MainActor in
        guard let current, store === current else { return }
        publish(current.state)
      }
    }
    publish(current?.state)
  }

  private static func publish(_ state: BrowserState?) {
    let overrides = state?.settings["shortcuts"]?.object?.compactMap { id, value in
      value.array.map { (id, $0.compactMap(\.string)) }
    } ?? []
    let precedence = state?.settings["shortcutPrecedence"]?.object?.compactMap { id, value in
      value.string.map { (id, $0) }
    } ?? []
    ShellMenus.setShortcutSettings(overrides: overrides, precedence: precedence)
  }

  @discardableResult
  private static func captureHints() -> Bool {
    let rows = ShellMenus.shortcutHints.map { (JSKey($0[0]), $0[1]) }
    let hints = Dictionary(rows, uniquingKeysWith: { first, _ in first })
    guard hints != snapshot.hints else { return false }
    snapshot = CommandShortcutSnapshot(resolvedHints: hints)
    return true
  }

  static var hints: [JSKey: String] { snapshot.hints }

  static func hint(_ id: String) -> String? { snapshot.hint(id) }

  func menuShortcuts() async -> [MenuShortcutItem] {
    ShellMenus.menuShortcuts().compactMap(Self.item)
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

  func openURLs(_ urls: [String]) {
    SettingsDirectWrites.opening?.openURLs(urls)
  }

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
      defaultPrecedence: dict.string("defaultPrecedence").flatMap(SolaraUI.ShortcutPrecedence.init(rawValue:)),
      precedenceFixed: dict.bool("precedenceFixed") ?? false,
      bindings: dict["bindings"] as? [[String]]
    )
  }
}

private final class ObserverToken: @unchecked Sendable {
  let token: NSObjectProtocol

  init(_ token: NSObjectProtocol) { self.token = token }
}
