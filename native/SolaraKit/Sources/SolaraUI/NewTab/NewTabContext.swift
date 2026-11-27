import SolaraModel
import SolaraStore

public struct NewTabContext: Equatable, Sendable {
  public let identity: NewTabIdentity
  public let incognito: Bool
  public let panelOpen: Bool
  public let active: Bool

  public static func resolve(_ state: BrowserState, windowId: String, tabId: String, closing: Set<String> = []) -> Self? {
    guard let window = state.windows[windowId], !window.isSmall, !closing.contains(windowId),
      let tab = state.tabs[tabId], tab.windowId == windowId, tab.profileId == window.profileId, tab.url.isEmpty else { return nil }
    return Self(identity: NewTabIdentity(windowId: windowId, tabId: tabId, profileId: window.profileId),
      incognito: window.incognito, panelOpen: state.windowUi[windowId]?.panelOpen ?? false,
      active: state.activeTabId(windowId) == tabId)
  }

  public static func showsHeading(incognito: Bool, onboarding: Bool) -> Bool {
    incognito && !onboarding
  }

  public func showsHeading(onboarding: Bool) -> Bool {
    Self.showsHeading(incognito: incognito, onboarding: onboarding)
  }

  public func allowsFieldInteraction(onboarding: Bool) -> Bool {
    active && !panelOpen && !onboarding
  }

  public func accepts(_ presented: NewTabIdentity, onboarding: Bool) -> Bool {
    identity == presented && allowsFieldInteraction(onboarding: onboarding)
  }

  public static func changesContext(_ changes: ChangeSet, windowId: String, tabId: String) -> Bool {
    changes.windows.upserted.contains(windowId) || changes.windows.removed.contains(windowId)
      || changes.windowUi.upserted.contains(windowId) || changes.windowUi.removed.contains(windowId)
      || changes.tabs.upserted.contains(tabId) || changes.tabs.removed.contains(tabId)
  }
}

public struct NewTabIntroReceipts {
  private var played: Set<String> = []

  public init() {}

  public mutating func claim(tabId: String) -> Bool {
    played.insert(tabId).inserted
  }
}
