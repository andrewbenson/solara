import SolaraModel
import SolaraStore

@MainActor
public final class ExtensionPresentation {
  public struct WindowContext: Equatable {
    public let windowId: String
    public let profileId: String
    public let engineProfile: String
    let incognito: Bool

    public init?(state: BrowserState, window: String) {
      guard let row = state.windows[window] else { return nil }
      windowId = window
      profileId = row.profileId
      engineProfile = OmniboxCommandSources.extensionProfile(state: state, windowId: window)
      incognito = row.incognito
    }

    public func matches(state: BrowserState) -> Bool {
      let original = Ids.isIncognitoProfile(profileId) ? Ids.incognitoOriginal(profileId) : profileId
      return state.profiles[original] != nil && self == Self(state: state, window: windowId)
    }

    public static func profileExists(state: BrowserState, engineProfile: String) -> Bool {
      state.profileOrder.contains { state.profiles[$0] != nil && state.engineProfile($0) == engineProfile }
    }
  }

  private struct ToolbarContext: Equatable {
    let window: String
    let tab: String
    let profile: WindowContext?
    let engine: String?
    let popup: String?

    init(window: String, tab: String, store: Store?, state: BrowserState?, popup: String?) {
      self.window = window
      self.tab = tab
      self.popup = popup
      profile = state.flatMap { WindowContext(state: $0, window: window) }
      engine = state.flatMap { $0.tabs[tab]?.windowId == window ? store?.pageEngine(tab, in: $0) : nil }
    }
  }

  private struct NewTabInput: Equatable {
    let window: WindowContext
    let rows: [JSONObject]
  }

  private var published: (lists: [String: [JSONObject]], states: [Int: JSONValue])?
  private var toolbars: [String: ToolbarContext] = [:]
  private var newTabInputs: [String: NewTabInput] = [:]
  private var focusedWindow: String?

  public init() {}

  public func trackToolbar(host: String, window: String, tab: String, store: Store?, popup: String?) {
    toolbars[host] = ToolbarContext(window: window, tab: tab, store: store, state: store?.state, popup: popup)
  }

  public func releaseToolbar(host: String) {
    toolbars[host] = nil
  }

  public nonisolated static func pinWindow(invoker: String, state: BrowserState, closing: Set<String>) -> String? {
    guard let window = state.windows[invoker] else { return nil }
    if !window.isSmall { return invoker }
    return CommandRoute.resolve("pinExtensions", windowId: invoker, state: state, closing: closing).focusWindow
  }

  public nonisolated static func focusedProfile(in state: BrowserState) -> String {
    let window = (state.ui.focusOrder + state.windowOrder).first { state.windows[$0] != nil }
    guard let window, let profile = state.windows[window]?.profileId else { return state.settings.defaultProfileId }
    return Ids.isIncognitoProfile(profile) ? Ids.incognitoOriginal(profile) : profile
  }

  public nonisolated static func focusedProfileChange(_ commit: Commit, from previous: String?) -> String? {
    let changes = commit.changes
    guard !changes.windows.isEmpty || changes.lists.contains("ui") || changes.lists.contains("windowOrder")
      || changes.settingsChanged.contains("defaultProfileId") || changes.settingsRemoved.contains("defaultProfileId") else { return nil }
    let profile = focusedProfile(in: commit.state)
    return profile == previous ? nil : profile
  }

  public nonisolated static func affectsActions(_ commit: Commit) -> Bool {
    let changes = commit.changes
    if !changes.windows.isEmpty || !changes.tabs.removed.isEmpty || changes.tabs.reordered
      || changes.lists.contains("windowOrder") { return true }
    guard !changes.tabs.upserted.isEmpty else { return false }
    let tabs = Set(changes.tabs.upserted)
    return commit.state.windowOrder.contains { window in commit.state.activeTabId(window).map(tabs.contains) == true }
  }

  public nonisolated static func affectsContext(_ commit: Commit) -> Bool {
    let changes = commit.changes
    if !changes.profiles.isEmpty || !changes.peeks.isEmpty || !changes.splits.isEmpty { return true }
    let engineSettings = ["pageEngine", "websiteEngines", "protectedVideoInWebKit"]
    if changes.settingsChanged.contains(where: engineSettings.contains) || changes.settingsRemoved.contains(where: engineSettings.contains) {
      return true
    }
    guard !changes.tabs.upserted.isEmpty else { return false }
    let tabs = Set(changes.tabs.upserted)
    return commit.state.peeks.values.contains { tabs.contains($0.tabId) }
      || commit.state.splits.values.contains { $0.tabIds.contains(where: tabs.contains) }
  }

  public func publish(store: Store?, lists: [String: [JSONObject]], states: [Int: JSONValue],
    popup: (String) -> String?, sources: NewTabSources, force: Bool = false) -> (catalog: Bool, toolbar: Bool, windows: Bool) {
    let state = store?.state
    var nextInputs: [String: NewTabInput] = [:]
    if let state {
      for window in state.windowOrder {
        guard let context = WindowContext(state: state, window: window) else { continue }
        let input = NewTabInput(window: context, rows: lists[context.engineProfile] ?? [])
        nextInputs[window] = input
        if newTabInputs[window] != input {
          sources.setExtensions(OmniboxCommandSources.extensions(state: state, windowId: window, displayed: input.rows), windowId: window)
        }
      }
    }
    let focus = state?.ui.focusedWindowId
    let windowsChanged = nextInputs != newTabInputs || focusedWindow != focus
    for window in newTabInputs.keys where nextInputs[window] == nil {
      sources.setExtensions([], windowId: window)
    }
    newTabInputs = nextInputs
    focusedWindow = focus

    let nextToolbars = toolbars.mapValues {
      ToolbarContext(window: $0.window, tab: $0.tab, store: store, state: state, popup: popup($0.window))
    }
    let toolbarChanged = nextToolbars != toolbars
    toolbars = nextToolbars

    let catalogChanged = force || published?.lists != lists
    let actionsChanged = published?.states != states
    if catalogChanged || actionsChanged { published = (lists, states) }
    return (catalogChanged, catalogChanged || actionsChanged || toolbarChanged, windowsChanged)
  }
}
