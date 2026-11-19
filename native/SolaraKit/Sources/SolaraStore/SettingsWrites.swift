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
  public let run: (Command) -> JSONValue?
  public let focus: (String) -> Void

  public init(state: @escaping () -> BrowserState, run: @escaping (Command) -> JSONValue?, focus: @escaping (String) -> Void) {
    self.state = state
    self.run = run
    self.focus = focus
  }

  public static let internalPages: Set<String> = ["history", "bookmarks", "downloads"]

  public func openURLs(_ urls: [String]) {
    var target = state().resolveWindowId(nil)
    for url in urls {
      if let window = target, state().windows[window]?.incognito != true {
        _ = run(Command("newTab", [.string(window), ["url": .string(url)]]))
      } else {
        target = run(Command("createWindow", [["url": .string(url)]]))?.string
      }
    }
  }

  public func openInNewTab(_ url: String) {
    guard let window = state().resolveWindowId(nil) else { return }
    _ = run(Command("newTab", [.string(window), ["url": .string(url)]]))
  }

  public func openInBrowser(_ url: String) {
    let s = state()
    let regular = { (id: String) in s.windows[id].map { !$0.incognito } ?? false }
    guard let window = s.ui.focusOrder.first(where: regular) ?? s.windowOrder.first(where: regular) else { return }
    _ = run(Command("newTab", [.string(window), ["url": .string(url)]]))
    focus(window)
  }

  public func openInternalPage(_ page: String, scheme: String, isAppScheme: (String) -> Bool) {
    let s = state()
    guard let window = s.resolveWindowId(nil) else { return }
    _ = run(Command("setFocusedWindow", [.string(window)]))
    focus(window)
    let url = "\(scheme)://\(page)"
    if let existing = s.viewTabIds(window).first(where: { id in
      s.tabs[id].map { Self.internalPage(of: $0.navigation?.url ?? $0.url, isAppScheme: isAppScheme) == page } ?? false
    }) {
      _ = run(Command("activate", [.string(existing)]))
      return
    }
    if let active = s.activeTabId(window), s.tabs[active]?.url.isEmpty == true {
      _ = run(Command("navigate", [.string(active), .string(url)]))
    } else {
      _ = run(Command("newTab", [.string(window), ["url": .string(url)]]))
    }
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
    let s = state()
    if let found = s.profileOrder.first(where: { s.engineProfile($0) == engine }), s.profiles[found] != nil { return found }
    let focused = s.ui.focusOrder.first { s.windows[$0] != nil } ?? s.windowOrder.first { s.windows[$0] != nil }
    if let focused, let own = s.windows[focused]?.profileId {
      let profile = Ids.isIncognitoProfile(own) ? Ids.incognitoOriginal(own) : own
      if s.profiles[profile] != nil { return profile }
    }
    return s.settings.defaultProfileId
  }
}
