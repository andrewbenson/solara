import SolaraModel
import SolaraStore
import Testing

@Suite struct NotificationMutesTests {
  let root = "/Users/me/Library/Application Support/Solara/Chromium"

  func twoProfiles() throws -> (store: Store, work: String, window: String) {
    let store = makeStore()
    let work = try store.dispatch(Command("createProfile", [["name": "Work"]])).result!.string!
    let window = try store.dispatch(Command("createWindow", [["url": "https://chat.example/", "profileId": .string(work)]])).result!.string!
    return (store, work, window)
  }

  func directory(_ store: Store, _ profileId: String) -> String {
    let engine = store.state.engineProfile(profileId)
    return "\(root)/\(engine.isEmpty ? "Default" : "Profile \(engine)")"
  }

  @Test func aMutedTabSilencesItsSitesNotificationsInItsOwnProfileOnly() throws {
    let (store, work, window) = try twoProfiles()
    let tab = store.state.windows[window]!.tabIds[0]
    try store.dispatch(Command("setMuted", [[.string(tab)], true]))
    #expect(store.silencesNotifications(profileDirectory: directory(store, work), origin: "https://chat.example/"))
    #expect(store.silencesNotifications(profileDirectory: directory(store, work), origin: "https://www.chat.example/"))
    #expect(!store.silencesNotifications(profileDirectory: directory(store, Settings.defaultProfileID), origin: "https://chat.example/"))
    #expect(!store.silencesNotifications(profileDirectory: directory(store, work), origin: "https://other.example/"))
  }

  @Test func anUnmutedTabLeavesNotificationsTheirSound() throws {
    let (store, work, _) = try twoProfiles()
    #expect(!store.silencesNotifications(profileDirectory: directory(store, work), origin: "https://chat.example/"))
  }

  @Test func aMutedSiteSilencesItsNotifications() throws {
    let (store, work, window) = try twoProfiles()
    let tab = store.state.windows[window]!.tabIds[0]
    try store.dispatch(Command("setSiteMuted", [.string(tab), true]))
    try store.dispatch(Command("closeTab", [.string(tab)]))
    #expect(store.silencesNotifications(profileDirectory: directory(store, work), origin: "https://chat.example/"))
    #expect(!store.silencesNotifications(profileDirectory: directory(store, work), origin: "https://other.example/"))
  }

  @Test func aDirectoryThatIsNoSolaraProfileSilencesNothing() throws {
    let (store, _, window) = try twoProfiles()
    let tab = store.state.windows[window]!.tabIds[0]
    try store.dispatch(Command("setMuted", [[.string(tab)], true]))
    #expect(!store.silencesNotifications(profileDirectory: "\(root)/Profile nobody", origin: "https://chat.example/"))
    #expect(!store.silencesNotifications(profileDirectory: "\(root)/System Profile", origin: "https://chat.example/"))
    #expect(!store.silencesNotifications(profileDirectory: directory(store, Settings.defaultProfileID), origin: "not a url"))
  }
}
