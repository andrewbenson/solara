import SolaraModel

public struct WorkspaceMenuDestinations: Equatable, Sendable {
  public struct Entry: Equatable, Sendable {
    public let id: String
    public let title: String
    public let current: Bool
  }

  public let profiles: [Entry]
  public let windows: [Entry]
  public let bookmarkProfile: String

  public init(state: BrowserState, windowId: String?, closing: Set<String>) {
    let window = windowId.flatMap { id in closing.contains(id) || state.windows[id]?.keptOnClose == true ? nil : state.windows[id] }
    profiles = Self.profileRows(state: state, window: window)
    bookmarkProfile = state.bookmarkProfileId(window)
    windows = window?.incognito == true ? [] : state.windowOrder.compactMap { id in
      guard id != windowId, !closing.contains(id), let target = state.windows[id],
        !target.incognito, !target.isSmall, target.keptOnClose != true else { return nil }
      return Entry(id: id, title: TabMenuPlan.windowTitle(state, id), current: false)
    }
  }

  public static func profileRows(state: BrowserState, window: BrowserWindow?) -> [Entry] {
    state.profileOrder.compactMap { id in
      state.profiles[id].map { Entry(id: id, title: $0.name, current: window?.profileId == id) }
    }
  }
}
