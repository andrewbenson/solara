import SolaraModel
import SolaraStore

public enum GroupActions {
  public struct CloseConfirm: Equatable, Sendable {
    public let title: String
    public let message: String
    public let confirmTitle: String
    public let suppression: String
    public let windowId: String
  }

  public enum Close: Equatable, Sendable {
    case nothing
    case unload([String])
    case close(confirm: CloseConfirm?)
  }

  public static func close(_ state: BrowserState, groupId: String) -> Close {
    let query = SidebarQuery(state)
    guard let group = state.groups[groupId] else { return .nothing }
    switch query.groupClose(groupId) {
    case nil: return .nothing
    case .unload?: return .unload(group.tabIds.flatMap { query.openPages($0) })
    case .close?:
      guard let window = state.windows[group.windowId] else { return .nothing }
      guard state.settings["warnBeforeClosingTabGroup"]?.truthy ?? true, Groups.rootOf(state.groups, groupId)?.pinned != true else { return .close(confirm: nil) }
      let count = group.tabIds.count
      let tabs = "\(count) \(count == 1 ? "tab" : "tabs")"
      return .close(confirm: CloseConfirm(
        title: "Close “\(query.groupLabel(groupId))”?",
        message: window.incognito ? "Its \(tabs) close with it." : "Its \(tabs) close with it. History › Recently Closed Groups brings it back.",
        confirmTitle: "Close Group", suppression: "Don’t ask me again", windowId: window.id))
    }
  }

  public static func tuckTarget(_ state: BrowserState, windowId: String, groupId: String) -> String? {
    guard let group = state.groups[groupId] else { return nil }
    return StripQuery(state).tuckTarget(windowId: windowId, profileId: group.profileId, groupId: groupId)
  }

  public static func collapse(_ groupId: String, _ collapsed: Bool) -> Command {
    Command("updateGroup", [.string(groupId), ["collapsed": .bool(collapsed)]])
  }
}
