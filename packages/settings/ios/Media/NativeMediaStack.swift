import AppKit
import Foundation
import SolaraCore
import SolaraModel
import SolaraShell
import SolaraStore
import SolaraUI

@MainActor
enum NativeMediaStack {
  static let artworkPixels = 256
  static let artworkEntries = 24
  private struct ArtworkKey: Hashable {
    let identity: PageIdentity
    let sessionID: UUID
    let url: String
  }

  private static var artwork: [ArtworkKey: (uri: String?, at: Double)] = [:]
  private static var loading: Set<ArtworkKey> = []
  private static var observer: NSObjectProtocol?
  private static var pipObserver: NSObjectProtocol?
  private static var pipTab: String?
  private static var listeners: [UUID: @MainActor () -> Void] = [:]

  static func listen(_ onChange: @escaping @MainActor () -> Void) -> UUID {
    if observer == nil {
      observer = NotificationCenter.default.addObserver(forName: NowPlayingStore.didChange, object: NowPlayingStore.shared, queue: .main) { _ in
        MainActor.assumeIsolated {
          artwork = artwork.filter { isCurrent($0.key) }
          changed()
        }
      }
    }
    if pipObserver == nil {
      pipTab = MediaStackPiP.center?.tabID
      pipObserver = NotificationCenter.default.addObserver(forName: PictureInPictureHolder.didChange, object: nil, queue: .main) { note in
        let tab = note.userInfo?["tabID"] as? String
        MainActor.assumeIsolated { pictureInPictureChanged(tab) }
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

  private static func pictureInPictureChanged(_ tab: String?) {
    guard tab != pipTab else { return }
    if let old = pipTab, tab != nil { NowPlayingStore.shared.holdOrder(old) }
    pipTab = tab
    if let tab, NowPlayingStore.shared.entries[tab] != nil { NowPlayingStore.shared.touch(tab) } else { changed() }
  }

  private static func changed() {
    for listener in Array(listeners.values) { listener() }
  }

  static func players(state: BrowserState, windowId: String, look: NativeLayoutAppearance) -> [MediaPlayerState] {
    guard let window = state.windows[windowId], !NowPlayingStore.shared.entries.isEmpty else { return [] }
    let shared = MediaStack.entries(state: state, store: NowPlayingStore.shared.entries, kind: window.incognito ? .incognito : .normal)
    let theme = theme(look)
    return MediaStack.visible(shared, state: state, windowId: windowId).compactMap { player(tabId: $0.tabId, report: $0.report, state: state, theme: theme, incognito: window.incognito) }
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

  private static func player(tabId: String, report: NowPlayingReport, state: BrowserState, theme: MediaThemeState, incognito: Bool) -> MediaPlayerState? {
    guard let tab = state.tabs[tabId] else { return nil }
    return MediaPlayerState(
      tabId: tabId, title: report.title.isEmpty ? tab.title : report.title,
      subtitle: report.artist.isEmpty ? host(tab.url) : report.artist, muted: tab.muted, playbackState: report.playbackState,
      position: report.position, timestamp: report.timestamp, playbackRate: report.playbackRate == 0 ? 1 : report.playbackRate,
      duration: report.duration, tracks: report.actions.contains("nexttrack") || report.actions.contains("previoustrack"),
      artwork: art(tabId, report.artwork), url: tab.url, favicon: tab.favicon, profileId: tab.profileId, theme: theme,
      profileName: incognito ? "Private" : state.profiles[tab.profileId]?.name, profileColor: incognito ? nil : NativeLayoutAppearance(state: state, profileId: tab.profileId, incognito: false).tokens["accent"],
      hasVideo: report.hasVideo, holdsPictureInPicture: NowPlayingStore.shared.pictureInPicture[tabId] != nil)
  }

  static func host(_ url: String) -> String {
    guard let host = URLComponents(string: url)?.host else { return "" }
    return host.hasPrefix("www.") ? String(host.dropFirst(4)) : host
  }

  static func hoverPlayer(tabId: String, state: BrowserState, windowId: String) -> MediaPlayerState? {
    guard let tab = state.tabs[tabId], tab.windowId == windowId, tab.pinned, let window = state.windows[windowId],
      state.settings["sidebarMediaControls"]?.bool != false,
      let entry = NowPlayingStore.shared.entries[tabId], entry.report.controllable, entry.report.playbackState != "none",
      !entry.report.title.isEmpty || entry.report.artwork?.isEmpty == false else { return nil }
    let look = NativeLayoutAppearance(state: state, profileId: window.profileId, incognito: window.incognito)
    return player(tabId: tabId, report: entry.report, state: state, theme: theme(look), incognito: window.incognito)
  }

  private static func isCurrent(_ key: ArtworkKey) -> Bool {
    guard let issuer = PageIssuer.shared, let binding = issuer.binding(identity: key.identity) else { return false }
    guard let entry = NowPlayingStore.shared.entries[key.identity.tabId] else { return false }
    return issuer.isCurrent(binding) && entry.sessionID == key.sessionID && entry.report.artwork == key.url
  }

  private static func art(_ tabId: String, _ url: String?) -> String? {
    guard let url, !url.isEmpty, let issuer = PageIssuer.shared,
      let binding = issuer.binding(tabId: tabId), issuer.isCurrent(binding),
      let entry = NowPlayingStore.shared.entries[tabId] else { return nil }
    let key = ArtworkKey(identity: binding.identity, sessionID: entry.sessionID, url: url)
    if let hit = artwork[key] { return hit.uri }
    guard loading.insert(key).inserted else { return nil }
    let command: PageCommand = binding.engine == .webKit ? .downloadFavicon(url) : .downloadImage(url, artworkPixels)
    issuer.issue(tabId: tabId, identity: binding.identity, command: command) { result in
      loading.remove(key)
      guard isCurrent(key) else { return }
      var uri: String?
      if case .success(let value) = result, case .object(let fields) = value, let raw = fields["uri"], case .string(let string) = raw { uri = string }
      artwork[key] = (uri, MediaClock.nowMs())
      let old = artwork.sorted { $0.value.at < $1.value.at }.dropLast(artworkEntries)
      for (stale, _) in old { artwork[stale] = nil }
      changed()
    }
    return nil
  }

  static func togglePictureInPicture(tabId: String, windowId: String, window: NSWindow?, keyboardOrAccessibility: Bool = false) {
    guard let store = WorkspaceWrites.store, store.state.tabs[tabId]?.windowId == windowId,
      let window, let issuer = PageIssuer.shared, let binding = issuer.binding(tabId: tabId) else { return }
    if keyboardOrAccessibility {
      let control = SolaraCoreWebView.recordNativePictureInPicturePress(in: window)
      issuer.toggleMediaPictureInPicture(tabId: tabId, identity: binding.identity, clickAt: 0, control: control)
    } else if let event = NSApp.currentEvent, event.window === window, event.type == .leftMouseUp {
      issuer.toggleMediaPictureInPicture(tabId: tabId, identity: binding.identity, clickAt: event.timestamp * 1000)
    }
  }

  static func perform(windowId: String, tabId: String, action: MediaAction, fromHover: Bool = false) {
    guard let store = WorkspaceWrites.store, let tab = store.state.tabs[tabId],
      let window = store.state.windows[windowId], let source = store.state.windows[tab.windowId],
      window.incognito == source.incognito, let issuer = PageIssuer.shared,
      let binding = issuer.binding(tabId: tabId), issuer.isCurrent(binding) else { return }
    let identity = binding.identity
    let command: PageCommand
    switch action {
    case .dismiss:
      return issuer.dismissMedia(tabId: tabId, identity: identity)
    case .toggle: command = .mediaCommand("toggle", 0)
    case .previous: command = .mediaCommand("previous", 0)
    case .next: command = .mediaCommand("next", 0)
    case .skip(let seconds):
      NowPlayingStore.shared.seek(tabId: tabId, seconds: Double(seconds), relative: true)
      command = .mediaCommand("seekBy", Double(seconds))
    case .seek(let seconds):
      guard seconds.isFinite else { return }
      NowPlayingStore.shared.seek(tabId: tabId, seconds: seconds, relative: false)
      command = .mediaCommand("seekTo", seconds)
    case .backToTab:
      let command = fromHover ? Command("clickTab", [.string(windowId), .string(tabId), [:]]) : Command("activate", [.string(tabId)])
      guard (try? store.dispatch(command, origin: .native)) != nil else { return }
      if !fromHover, store.state.ui.focusedWindowId != tab.windowId {
        _ = try? store.dispatch(Command("setFocusedWindow", [.string(tab.windowId)]), origin: .native)
        ShellDrag.focus(tab.windowId)
      }
      FrameUpdates.flush()
      return
    case .toggleMute:
      _ = NativeTabMenu.sidebarAction("toggleMute", tabId: tabId, windowId: windowId)
      return
    case .enterPictureInPicture:
      if let old = pipTab, old != tabId { NowPlayingStore.shared.holdOrder(old) }
      NowPlayingStore.shared.touch(tabId)
      if binding.engine == .webKit {
        command = .requestPictureInPicture(0, 0)
        break
      }
      guard let center = MediaStackPiP.center else { return }
      Task { @MainActor in
        guard issuer.isCurrent(binding), WorkspaceWrites.store === store else { return }
        _ = await center.enter(tabID: tabId)
      }
      return
    case .minimizePictureInPicture:
      if pipTab == tabId { MediaStackPiP.center?.minimize(); return }
      guard let kind = NowPlayingStore.shared.pictureInPicture[tabId] else { return }
      command = kind == "document" ? .executeJavaScript("window.documentPictureInPicture?.window?.close()") : .exitPictureInPicture
    }
    issuer.issue(tabId: tabId, identity: identity, command: command) { _ in }
  }
}
