import SolaraModel

public struct CommandContext: Sendable {
  public let activeTab: Tab?
  public let viewTabIds: [String]
  public let canTidyPins: Bool
  public let hiddenEmptyCard: Bool

  public init(state: BrowserState, windowId: String, env: WebAddressing = PlainWebAddressing()) {
    let window = state.windows[windowId]
    let active = window.flatMap { $0.activeTabIds[$0.profileId] }.flatMap { state.tabs[$0] }
    activeTab = active.flatMap { JSKey($0.windowId) == JSKey(windowId) ? $0 : nil }
    viewTabIds = window.map { w in w.tabIds.filter { state.tabs[$0].map { JSKey($0.profileId) == JSKey(w.profileId) } ?? false } } ?? []
    canTidyPins = Self.canTidyPins(state: state, windowId: windowId, env: env)
    hiddenEmptyCard = activeTab?.newTabPlaceholder == true || state.settings.string("newTabOpens") == "commandBar" && activeTab.map { tab in
      !tab.pinned && tab.url.isEmpty && tab.navigation == nil && (tab.adoptId ?? "").isEmpty
        && !state.splits.values.contains { $0.tabIds.contains { JSKey($0) == JSKey(tab.id) } }
    } == true
  }

  public static func canTidyPins(state: BrowserState, windowId: String, profileId: String? = nil, env: WebAddressing = PlainWebAddressing()) -> Bool {
    Session(state: state, memory: StoreMemory(), env: env, config: StoreConfig(), now: 0).tidyPlan(state, windowId, profileId) != nil
  }
}
