import SolaraModel
import SolaraStore

public struct ExtensionInstallLifetime {
  public enum Requester: Equatable {
    case page(tabId: String, browserId: Int, url: String, navigation: Double?)
    case popup(String)
    case browser(Int32)
  }
  public struct Receipt: Equatable {
    public let id: String
    public let windowId: String
    public let requester: Requester?
    public init(id: String, windowId: String, requester: Requester?) {
      self.id = id
      self.windowId = windowId
      self.requester = requester
    }
  }
  public private(set) var pending: Receipt?
  private var seen: Set<String> = []

  public init() {}

  public static func matchesPopup(requesterBrowserId: Int?, popupBrowserId: Int) -> Bool {
    popupBrowserId > 0 && requesterBrowserId == popupBrowserId
  }

  public static func matchesPermissionPopup(extensionId: String?, originalProfile: String?, privateProfile: String?,
    popupExtensionId: String, popupOriginalProfile: String, popupPrivateProfile: String? = nil) -> Bool {
    extensionId == popupExtensionId
      && (originalProfile == nil || originalProfile == popupOriginalProfile)
      && (privateProfile == nil || privateProfile == popupPrivateProfile)
  }

  public static func host(in state: BrowserState, originalProfile: String, privateProfile: String?) -> String? {
    let ordered = [state.ui.focusedWindowId].compactMap { $0 } + state.ui.focusOrder + state.windowOrder
    return ordered.first { id in
      guard let window = state.windows[id], window.incognito == (privateProfile != nil) else { return false }
      let profile = window.profileId
      if let privateProfile {
        return state.engineProfile(profile) == privateProfile && state.privateSession(profile) == originalProfile
      }
      return state.engineProfile(profile) == originalProfile
    }
  }

  public mutating func begin(_ receipt: Receipt) -> Receipt? {
    guard seen.insert(receipt.id).inserted else { return nil }
    let replaced = pending
    pending = receipt
    return replaced
  }

  public mutating func answer(_ id: String) -> Receipt? {
    guard let receipt = pending, receipt.id == id else { return nil }
    pending = nil
    return receipt
  }

  public mutating func reconcile(windowExists: Bool, requester: Requester?) -> Receipt? {
    guard let receipt = pending, let owner = receipt.requester,
      !windowExists || owner != requester else { return nil }
    return answer(receipt.id)
  }
}
