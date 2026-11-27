import SolaraModel
import SolaraStore

public struct NewTabNoticeContext: Equatable, Sendable {
  public let identity: NewTabIdentity
  public let focusContext: String

  public static func resolve(_ state: BrowserState, windowId: String, tabId: String? = nil,
    explicitPage: Bool, closing: Set<String> = []) -> Self?
  {
    guard let activeTabId = state.activeTabId(windowId), tabId == nil || tabId == activeTabId,
      let context = NewTabContext.resolve(state, windowId: windowId, tabId: activeTabId, closing: closing),
      explicitPage || !context.incognito,
      context.incognito || state.profiles[context.identity.profileId] != nil else { return nil }
    let focus = JSONValue.array([.string(windowId), .string(context.identity.profileId),
      .string(activeTabId), state.ui.focusedWindowId.map(JSONValue.string) ?? .null]).text()
    return Self(identity: context.identity, focusContext: focus)
  }
}
