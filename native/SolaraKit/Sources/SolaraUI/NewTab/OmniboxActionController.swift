import Foundation
import SolaraModel
import SolaraOmnibox
import SolaraStore

public enum OmniboxApplicationAction: Sendable, Equatable {
  case newTab
  case settings(pane: String?)
}

@MainActor
public final class OmniboxActionController {
  public var ownsWorkspace: () -> Bool
  public var resolve: () -> Store?
  public var openSettings: ((String?) -> Void)?
  public var performAction: (String, String) -> Bool = { _, _ in false }
  public var performExtension: (SolaraOmnibox.Suggestion, HeroBarModel) -> Bool = { _, _ in false }
  public var removeHistory: (String, HeroBarModel) -> Bool = { _, _ in false }
  public var dictate: (HeroBarModel) -> Bool = { _ in false }
  public var presentContextMenu: (HeroBarModel) -> Void = { _ in }
  public var didDismiss: (HeroBarModel, BarDismissal?) -> Void = { model, _ in model.field?.releaseFocus() }
  public var didSwitch: (String) -> Void = { _ in }

  public init(
    ownsWorkspace: @escaping () -> Bool = { NativeStoreHandle.ownsWorkspace },
    resolve: @escaping () -> Store? = { NativeStoreHandle.store }
  ) {
    self.ownsWorkspace = ownsWorkspace
    self.resolve = resolve
  }

  private var ownedStore: Store? { ownsWorkspace() ? resolve() : nil }

  public var ownsActions: Bool { ownedStore != nil }

  @discardableResult
  public func dismiss(_ model: HeroBarModel, reason: BarDismissal? = nil) -> Bool {
    guard let store = ownedStore else { return false }
    dismiss(model, store: store, reason: reason)
    return true
  }

  @discardableResult
  public func cancel(_ model: HeroBarModel, session: UUID? = nil) -> Bool {
    guard let store = ownedStore else { return false }
    guard session == nil || session == model.editingSession else { return true }
    dismiss(model, store: store, reason: nil)
    return true
  }

  public func decorate(_ fallback: HeroBarEvents, model: @escaping () -> HeroBarModel?) -> HeroBarEvents {
    var events = fallback
    events.open = { [self] url, disposition in
      guard let store = ownedStore else { return fallback.open(url, disposition) }
      guard let model = model(), sourceMatches(model, store: store) else { return }
      if openAppURL(url, disposition: disposition, model: model, store: store) { return }
      let result = try? store.dispatch(Command("omniboxOpen", [
        .string(model.windowId), .string(model.tabId), .string(url), .string(disposition.rawValue), .bool(model.opensTab),
      ]), origin: .native)
      if disposition != .backgroundTab, let windowId = result?.result?["windowId"]?.string { didSwitch(windowId) }
    }
    events.switchTo = { [self] target, url, disposition in
      guard let store = ownedStore else { return fallback.switchTo(target, url, disposition) }
      guard let model = model(), sourceMatches(model, store: store) else { return }
      let result = try? store.dispatch(Command("omniboxSwitch", [
        .string(model.windowId), .string(model.tabId), .string(target), .string(url), .string(disposition.rawValue),
      ]), origin: .native)
      if disposition != .backgroundTab, let windowId = result?.result?["windowId"]?.string { didSwitch(windowId) }
    }
    events.done = { [self] reason in
      guard let store = ownedStore else { return fallback.done(reason) }
      guard let model = model() else { return }
      dismiss(model, store: store, reason: reason)
    }
    events.cancel = { [self] session in
      guard let store = ownedStore else { return fallback.cancel(session) }
      guard let model = model(), model.editingSession == session else { return }
      dismiss(model, store: store, reason: nil)
    }
    events.runAction = { [self] id in
      guard let store = ownedStore else { return fallback.runAction(id) }
      guard let model = model(), sourceMatches(model, store: store) else { return }
      if id == "copyUrl" || id == "copyUrlAsMarkdown" {
        guard let tab = store.state.tabs[model.tabId], tab.windowId == model.windowId, !tab.url.isEmpty else { return }
        fallback.copy(id == "copyUrl" ? cleanUrl(tab.url) : markdownLink(title: tab.customTitle ?? tab.title, url: tab.url))
      } else if !performAction(id, model.windowId) {
        fallback.runAction(id)
      }
    }
    events.runExtension = { [self] suggestion in
      guard let store = ownedStore else { return fallback.runExtension(suggestion) }
      guard let model = model(), sourceMatches(model, store: store) else { return }
      if !performExtension(suggestion, model) { fallback.runExtension(suggestion) }
    }
    events.removeHistory = { [self] url in
      guard let store = ownedStore else { return fallback.removeHistory(url) }
      guard let model = model(), sourceMatches(model, store: store) else { return }
      if !removeHistory(url, model) { fallback.removeHistory(url) }
    }
    events.dictate = { [self] in
      guard let store = ownedStore else { return fallback.dictate() }
      guard let model = model(), sourceMatches(model, store: store) else { return }
      if !dictate(model) { fallback.dictate() }
    }
    events.contextMenu = { [self] hasSelection, hasValue in
      guard let store = ownedStore else { return fallback.contextMenu(hasSelection, hasValue) }
      guard let model = model(), sourceMatches(model, store: store) else { return }
      presentContextMenu(model)
    }
    return events
  }

  private static let settingsPanes: [String: String] = [
    "general": "general", "profiles": "profiles", "people": "profiles", "manageprofile": "profiles",
    "sync": "sync", "syncsetup": "sync", "tabs": "tabs", "appearance": "appearance", "privacy": "privacy",
    "passwords": "passwords", "autofill": "autofill", "addresses": "autofill", "payments": "autofill",
    "extensions": "extensions", "search": "search", "searchengines": "search", "engines": "engines",
    "shortcuts": "shortcuts", "livefolders": "liveFolders", "calendar": "calendar", "advanced": "advanced",
  ]

  public static func applicationAction(for url: String) -> OmniboxApplicationAction? {
    switch appUrlRoute(url) {
    case .newTab?: return .newTab
    case .settings(let section)?:
      guard let section else { return .settings(pane: nil) }
      guard let known = settingsPanes[section.lowercased()] else { return nil }
      return .settings(pane: known)
    default: return nil
    }
  }

  private func openAppURL(_ url: String, disposition: Disposition, model: HeroBarModel, store: Store) -> Bool {
    guard disposition != .newWindow, let action = Self.applicationAction(for: url) else { return false }
    switch action {
    case .newTab:
      dismiss(model, store: store, reason: nil)
      let result = try? store.dispatch(Command("omniboxCommand", [.string(model.windowId), "newTab"]), origin: .native)
      if let windowId = result?.result?["windowId"]?.string { didSwitch(windowId) }
      return true
    case .settings(let pane):
      guard let openSettings else { return false }
      dismiss(model, store: store, reason: nil)
      openSettings(pane)
      return true
    }
  }

  private func dismiss(_ model: HeroBarModel, store: Store, reason: BarDismissal?) {
    guard sourceMatches(model, store: store) else { return }
    _ = try? store.dispatch(Command("closePanel", [.string(model.windowId)]), origin: .native)
    didDismiss(model, reason)
  }

  private func sourceMatches(_ model: HeroBarModel, store: Store) -> Bool {
    let state = store.state
    guard let window = state.windows[model.windowId], let tab = state.tabs[model.tabId] else { return false }
    return tab.windowId == model.windowId && tab.profileId == model.profileId && window.profileId == model.profileId
      && state.activeTabId(model.windowId) == model.tabId
  }
}
