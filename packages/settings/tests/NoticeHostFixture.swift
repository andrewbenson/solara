import SolaraModel
import SolaraStore

@MainActor
enum NoticeHostFixture {
  private static var state = BrowserState()

  static func make(_ kind: String, windowId: String) -> HostedContent? {
    guard let content = HostedViews.make(kind, windowId: windowId) else { return nil }
    return HostedContent(view: content.view, onUnmount: content.onUnmount, takesFocus: content.takesFocus,
      focusRestoration: content.focusRestoration, onState: { json in
        guard var payload = (try? JSONValue.parse(json))?.object,
          let profileId = payload.removeValue(forKey: "profileId")?.string,
          let context = payload.removeValue(forKey: "focusContext")?.string else {
          content.onState?(json)
          return
        }
        let tabId = "\(windowId)-\(profileId)-\(context)"
        if state.activeTabId(windowId) != tabId {
          state.profiles[profileId] = Profile(id: profileId, name: profileId, color: "plum", icon: nil, createdAt: 0)
          state.windows[windowId] = BrowserWindow(id: windowId, profileId: profileId, incognito: false, frame: nil, createdAt: 0)
          state.windows[windowId]?.tabIds = [tabId]
          state.windows[windowId]?.activeTabIds[profileId] = tabId
          state.tabs[tabId] = Tab(id: tabId, windowId: windowId, profileId: profileId, url: "", now: 0)
          let store = Store(state: state, checksInvariants: false)
          NativeStoreHandle.ownsWorkspace = true
          NativeStoreHandle.resolve = { store }
        }
        payload["tabId"] = .string(tabId)
        content.onState?(JSONValue.object(payload).text())
      })
  }
}
