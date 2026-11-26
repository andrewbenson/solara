import Foundation
import SolaraModel

public enum SettingsWrites {
  @MainActor public static var directStore: Store? {
    guard !NativeStoreHandle.frozen, NativeStoreHandle.ownsWorkspace, let store = NativeStoreHandle.store, !store.config.safeMode else { return nil }
    return store
  }

  public static func createProfile(name: String, color: String, shareWith: String?) -> Command {
    Command("createProfile", [["name": .string(name), "color": .string(color), "shareWith": shareWith.map(JSONValue.string) ?? .null]])
  }

  public static func updateProfile(_ id: String, _ patch: JSONObject) -> Command {
    Command("updateProfile", [.string(id), .object(patch)])
  }

  public static func deleteProfile(_ id: String) -> Command {
    Command("deleteProfile", [.string(id)])
  }

  public static func reorderProfiles(_ ids: [String]) -> Command {
    Command("reorderProfiles", [.array(ids.map(JSONValue.string))])
  }

  public static func chooseTabLayout(_ layout: String, in state: BrowserState) -> [Command] {
    let choose = Command("updateSettings", [["tabLayout": .string(layout)]])
    let current = state.settings.string("tabLayout")
    let toggles = state.windows.values.filter { ($0.tabLayout ?? current) != layout }.map { Command("toggleTabLayout", [.string($0.id)]) }
    return [choose] + toggles + [choose]
  }
}

public struct SettingsOpening {
  public let state: () -> BrowserState
  public let run: (Command) -> Commit?
  public let focus: (String) -> Void

  public init(state: @escaping () -> BrowserState, run: @escaping (Command) -> Commit?, focus: @escaping (String) -> Void) {
    self.state = state
    self.run = run
    self.focus = focus
  }

  public static let internalPages: Set<String> = ["history", "bookmarks", "downloads"]

  @discardableResult
  public func openURLs(_ urls: [String]) -> Bool {
    guard !urls.isEmpty else { return false }
    var target = state().resolveWindowId(nil)
    for url in urls {
      if let window = target, state().windows[window]?.incognito != true {
        guard newTab(in: window, url: url) else { return false }
      } else {
        guard let window = run(Command("createWindow", [["url": .string(url)]]))?.result?.string, !window.isEmpty else { return false }
        target = window
      }
    }
    return true
  }

  @discardableResult
  public func openInNewTab(_ url: String) -> Bool {
    guard let window = state().resolveWindowId(nil) else { return false }
    return newTab(in: window, url: url)
  }

  @discardableResult
  public func openInBrowser(_ url: String) -> Bool {
    let s = state()
    let regular = { (id: String) in s.windows[id].map { !$0.incognito } ?? false }
    guard let window = s.ui.focusOrder.first(where: regular) ?? s.windowOrder.first(where: regular),
          newTab(in: window, url: url) else { return false }
    focus(window)
    return true
  }

  @discardableResult
  public func openInternalPage(_ page: String, scheme: String, isAppScheme: (String) -> Bool) -> Bool {
    let s = state()
    guard let window = s.resolveWindowId(nil),
          run(Command("setFocusedWindow", [.string(window)])) != nil else { return false }
    focus(window)
    let url = "\(scheme)://\(page)"
    if let existing = s.viewTabIds(window).first(where: { id in
      s.tabs[id].map { Self.internalPage(of: $0.navigation?.url ?? $0.url, isAppScheme: isAppScheme) == page } ?? false
    }) {
      return run(Command("activate", [.string(existing)])) != nil
    }
    if let active = s.activeTabId(window), s.tabs[active]?.url.isEmpty == true {
      return run(Command("navigate", [.string(active), .string(url)])) != nil
    }
    return newTab(in: window, url: url)
  }

  private func newTab(in window: String, url: String) -> Bool {
    let tab = run(Command("newTab", [.string(window), ["url": .string(url)]]))?.result?.string
    return tab?.isEmpty == false
  }

  public static func internalPage(of url: String, isAppScheme: (String) -> Bool) -> String? {
    guard let range = url.range(of: "://") else { return nil }
    let scheme = String(url[..<range.lowerBound])
    guard let first = scheme.first, first.isASCII, first.isLetter,
      scheme.allSatisfy({ $0.isASCII && ($0.isLetter || $0.isNumber || "+.-".contains($0)) }),
      isAppScheme(scheme)
    else { return nil }
    let rest = url[range.upperBound...]
    let host = rest.prefix { !"/?#".contains($0) }.lowercased()
    return internalPages.contains(host) ? host : nil
  }

  public func extensionsProfile(engine: String) -> String {
    Self.extensionsProfile(engine: engine, in: state())
  }

  public static func extensionsProfile(engine: String, in s: BrowserState) -> String {
    if let found = s.profileOrder.first(where: { s.engineProfile($0) == engine }), s.profiles[found] != nil { return found }
    let focused = s.ui.focusOrder.first { s.windows[$0] != nil } ?? s.windowOrder.first { s.windows[$0] != nil }
    if let focused, let own = s.windows[focused]?.profileId {
      let profile = Ids.isIncognitoProfile(own) ? Ids.incognitoOriginal(own) : own
      if s.profiles[profile] != nil { return profile }
    }
    return s.settings.defaultProfileId
  }
}

public struct ImportTargetChoice: Sendable, Equatable {
  public let id: String
  public let name: String

  public init(id: String, name: String) {
    self.id = id
    self.name = name
  }
}

public enum ImportTargets {
  public static func list(_ s: BrowserState) -> [ImportTargetChoice] {
    s.profileOrder.compactMap { id in s.profiles[id].map { ImportTargetChoice(id: id, name: $0.name) } }
  }

  public static func defaultTarget(_ s: BrowserState) -> String {
    if let focused = s.ui.focusedWindowId, let window = s.windows[focused], !window.incognito { return window.profileId }
    return s.settings.defaultProfileId
  }
}

public final class ImportTargetsFeed: @unchecked Sendable {
  private let lock = NSLock()
  private var last: [ImportTargetChoice]

  public init(_ state: BrowserState) {
    last = ImportTargets.list(state)
  }

  public func next(_ state: BrowserState) -> [ImportTargetChoice]? {
    let list = ImportTargets.list(state)
    return lock.withLock {
      guard list != last else { return nil }
      last = list
      return list
    }
  }
}

public final class ImportPreferredSource: @unchecked Sendable {
  public static let shared = ImportPreferredSource()
  private let lock = NSLock()
  private var value: String?

  public init() {}

  public func set(_ id: String?) { lock.withLock { value = id } }

  public func take() -> String? {
    lock.withLock {
      let id = value
      value = nil
      return id
    }
  }
}
