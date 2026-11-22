import AppKit
import Foundation
import SolaraModel
import SolaraUI

@MainActor
enum NativeMediaStack {
  static let artworkPixels = 256
  static let artworkEntries = 24
  private static var artwork: [String: (uri: String?, at: Double)] = [:]
  private static var loading: Set<String> = []
  private static var observer: NSObjectProtocol?
  private static var listeners: [UUID: @MainActor () -> Void] = [:]

  static func listen(_ onChange: @escaping @MainActor () -> Void) -> UUID {
    if observer == nil {
      observer = NotificationCenter.default.addObserver(forName: NowPlayingStore.didChange, object: NowPlayingStore.shared, queue: .main) { _ in
        MainActor.assumeIsolated { changed() }
      }
    }
    let id = UUID()
    listeners[id] = onChange
    return id
  }

  static func stopListening(_ id: UUID?) {
    guard let id else { return }
    listeners[id] = nil
  }

  private static func changed() {
    for listener in listeners.values { listener() }
  }

  static func players(state: BrowserState, windowId: String, look: NativeLayoutAppearance) -> [MediaPlayerState] {
    guard let window = state.windows[windowId], !NowPlayingStore.shared.entries.isEmpty else { return [] }
    if NowPlayingStore.shared.entries.keys.contains(where: { state.tabs[$0] == nil }) { NowPlayingStore.shared.retain(tabIds: Set(state.tabs.keys)) }
    let shared = MediaStack.entries(state: state, store: NowPlayingStore.shared.entries, kind: window.incognito ? .incognito : .normal)
    let theme = theme(look)
    return MediaStack.visible(shared, state: state, windowId: windowId).compactMap { player($0, state: state, theme: theme, incognito: window.incognito) }
  }

  static func theme(_ look: NativeLayoutAppearance) -> MediaThemeState {
    var colors: [String: String] = [:]
    for key in ["panel", "panelBorder", "textPrimary", "textSecondary", "textTertiary", "icon", "accent", "rowHover", "toolbarHover", "toolbarPressed"] {
      if let value = look.tokens[key] { colors[key] = value }
    }
    colors["groupFill"] = look.dark ? "#FFFFFF1A" : "#0000000D"
    colors["groupStroke"] = look.dark ? "#FFFFFF1A" : "#0000001A"
    return MediaThemeState(dark: look.dark, colors: colors, panelShadowOpacity: look.panel.shadowOpacity)
  }

  static func player(_ entry: MediaStackEntry, state: BrowserState, theme: MediaThemeState, incognito: Bool) -> MediaPlayerState? {
    guard let tab = state.tabs[entry.tabId] else { return nil }
    let report = entry.report
    return MediaPlayerState(
      tabId: entry.tabId, title: report.title.isEmpty ? tab.title : report.title,
      subtitle: report.artist.isEmpty ? host(tab.url) : report.artist, muted: tab.muted, playbackState: report.playbackState,
      position: report.position, timestamp: report.timestamp, playbackRate: report.playbackRate == 0 ? 1 : report.playbackRate,
      duration: report.duration, tracks: report.actions.contains("nexttrack") || report.actions.contains("previoustrack"),
      artwork: art(entry.tabId, report.artwork), url: tab.url, favicon: tab.favicon, profileId: tab.profileId, theme: theme,
      profileName: incognito ? "Private" : state.profiles[tab.profileId]?.name, profileColor: incognito ? nil : state.profiles[tab.profileId]?.color)
  }

  static func host(_ url: String) -> String {
    guard let host = URLComponents(string: url)?.host else { return "" }
    return host.hasPrefix("www.") ? String(host.dropFirst(4)) : host
  }

  private static func art(_ tabId: String, _ url: String?) -> String? {
    guard let url, !url.isEmpty else { return nil }
    let key = "\(tabId) \(url)"
    if let hit = artwork[key] { return hit.uri }
    guard !loading.contains(key), let issuer = PageIssuer.shared, let binding = issuer.binding(tabId: tabId), binding.host == .pooled else { return nil }
    loading.insert(key)
    issuer.issue(tabId: tabId, identity: binding.identity, command: .downloadImage(url, artworkPixels)) { result in
      MainActor.assumeIsolated {
        loading.remove(key)
        var uri: String?
        if case .success(let value) = result, case .object(let fields) = value, let raw = fields["uri"], case .string(let string) = raw { uri = string }
        artwork[key] = (uri, MediaClock.nowMs())
        let old = artwork.sorted { $0.value.at < $1.value.at }.dropLast(artworkEntries)
        for (stale, _) in old { artwork[stale] = nil }
        changed()
      }
    }
    return nil
  }

  static func perform(windowId: String, tabId: String, action: MediaAction) {
    switch action {
    case .dismiss:
      NowPlayingStore.shared.remove(tabId)
      pauseIfPlaying(windowId: windowId, tabId: tabId)
    case .toggle: command(windowId: windowId, tabId: tabId, name: "toggle", seconds: 0, fallback: action)
    case .previous: command(windowId: windowId, tabId: tabId, name: "previous", seconds: 0, fallback: action)
    case .next: command(windowId: windowId, tabId: tabId, name: "next", seconds: 0, fallback: action)
    case .skip(let seconds): command(windowId: windowId, tabId: tabId, name: "seekBy", seconds: Double(seconds), fallback: action)
    case .seek(let seconds): command(windowId: windowId, tabId: tabId, name: "seekTo", seconds: seconds, fallback: action)
    case .backToTab, .toggleMute: NativeMedia.player("sidebarPlayer", windowId, tabId, action)
    }
  }

  static func pauseIfPlaying(windowId: String, tabId: String) {
    command(windowId: windowId, tabId: tabId, name: "pause", seconds: 0, fallback: .toggle, onlyIfPlaying: true)
  }

  private static func command(windowId: String, tabId: String, name: String, seconds: Double, fallback: MediaAction, onlyIfPlaying: Bool = false) {
    if onlyIfPlaying, NowPlayingStore.shared.entries[tabId]?.report.playing != true { return }
    guard let issuer = PageIssuer.shared, let binding = issuer.binding(tabId: tabId), binding.host == .pooled else {
      return NativeMedia.player("sidebarPlayer", windowId, tabId, fallback)
    }
    issuer.issue(tabId: tabId, identity: binding.identity, command: .mediaCommand(name, seconds)) { _ in }
  }
}
