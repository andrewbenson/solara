import Testing
import SolaraUI
import SolaraModel
import SolaraStore

@MainActor
struct ExtensionInstallLifetimeTests {
  private let tab = ExtensionInstallLifetime.Requester.page(tabId: "t1", browserId: 17, url: "https://store.example/", navigation: 1)

  @Test func disappearedRequesterCancelsOnce() {
    var lifetime = ExtensionInstallLifetime()
    let request = ExtensionInstallLifetime.Receipt(id: "install", windowId: "w", requester: tab)
    _ = lifetime.begin(request)
    #expect(lifetime.reconcile(windowExists: true, requester: nil) == request)
    #expect(lifetime.reconcile(windowExists: false, requester: nil) == nil)
    #expect(lifetime.answer("install") == nil)
  }

  @Test func navigationCancelsEvenWhenTheURLIsUnchanged() {
    var lifetime = ExtensionInstallLifetime()
    let request = ExtensionInstallLifetime.Receipt(id: "install", windowId: "w", requester: tab)
    _ = lifetime.begin(request)
    let navigated = ExtensionInstallLifetime.Requester.page(tabId: "t1", browserId: 17, url: "https://store.example/", navigation: 2)
    #expect(lifetime.reconcile(windowExists: true, requester: navigated) == request)
    #expect(lifetime.answer("install") == nil)
  }

  @Test func staleAnswerCannotSpendTheNextReceipt() {
    var lifetime = ExtensionInstallLifetime()
    let first = ExtensionInstallLifetime.Receipt(id: "first", windowId: "w", requester: tab)
    let second = ExtensionInstallLifetime.Receipt(id: "second", windowId: "w", requester: tab)
    _ = lifetime.begin(first)
    #expect(lifetime.begin(second) == first)
    #expect(lifetime.answer("first") == nil)
    #expect(lifetime.answer("second") == second)
    #expect(lifetime.answer("second") == nil)
    _ = lifetime.begin(first)
    #expect(lifetime.pending == nil)
  }

  @Test func replacingPopupCancelsEvenForTheSameExtension() {
    var lifetime = ExtensionInstallLifetime()
    let request = ExtensionInstallLifetime.Receipt(id: "optional", windowId: "w", requester: .popup("first-host"))
    _ = lifetime.begin(request)
    #expect(lifetime.reconcile(windowExists: true, requester: .popup("first-host")) == nil)
    #expect(lifetime.reconcile(windowExists: true, requester: .popup("replacement")) == request)
  }

  @Test func requesterlessInstallCanBeAnsweredAfterTheWindowCloses() {
    var lifetime = ExtensionInstallLifetime()
    let request = ExtensionInstallLifetime.Receipt(id: "enable", windowId: "w", requester: nil)
    _ = lifetime.begin(request)
    #expect(lifetime.reconcile(windowExists: true, requester: nil) == nil)
    #expect(lifetime.reconcile(windowExists: false, requester: nil) == nil)
    #expect(lifetime.answer("enable") == request)
  }
  @Test func explicitBrowserIdentityMustMatchTheActionPopup() {
    #expect(ExtensionInstallLifetime.matchesPopup(requesterBrowserId: nil, popupBrowserId: 17) == false)
    #expect(ExtensionInstallLifetime.matchesPopup(requesterBrowserId: 18, popupBrowserId: 17) == false)
    #expect(ExtensionInstallLifetime.matchesPopup(requesterBrowserId: 17, popupBrowserId: 17))
  }

  @Test(arguments: [nil, "work"] as [String?])
  func requesterlessPermissionsMatchTheOpenPopupByExtensionAndSuppliedProfile(profile: String?) {
    #expect(ExtensionInstallLifetime.matchesPermissionPopup(extensionId: "extension", originalProfile: profile, privateProfile: nil,
      popupExtensionId: "extension", popupOriginalProfile: "work"))
  }

  @Test func requesterlessPermissionsRejectAnUnrelatedPopup() {
    #expect(!ExtensionInstallLifetime.matchesPermissionPopup(extensionId: "other", originalProfile: "", privateProfile: nil,
      popupExtensionId: "extension", popupOriginalProfile: ""))
    #expect(!ExtensionInstallLifetime.matchesPermissionPopup(extensionId: nil, originalProfile: "", privateProfile: nil,
      popupExtensionId: "extension", popupOriginalProfile: ""))
    #expect(!ExtensionInstallLifetime.matchesPermissionPopup(extensionId: "extension", originalProfile: "", privateProfile: nil,
      popupExtensionId: "extension", popupOriginalProfile: "work"))
  }

  @Test func requesterlessPermissionsMatchTheSuppliedPrivateSession() {
    #expect(ExtensionInstallLifetime.matchesPermissionPopup(extensionId: "extension", originalProfile: "work", privateProfile: "private@work",
      popupExtensionId: "extension", popupOriginalProfile: "work", popupPrivateProfile: "private@work"))
    #expect(!ExtensionInstallLifetime.matchesPermissionPopup(extensionId: "extension", originalProfile: "work", privateProfile: "private@work",
      popupExtensionId: "extension", popupOriginalProfile: "work", popupPrivateProfile: "other@work"))
    #expect(!ExtensionInstallLifetime.matchesPermissionPopup(extensionId: "extension", originalProfile: "work", privateProfile: "private@work",
      popupExtensionId: "extension", popupOriginalProfile: "work"))
  }

  @Test func destinationSelectsTheMatchingProfileAndPrivateSession() throws {
    let store = Store(state: BrowserState(settings: Settings.hydrated(from: nil)))
    let profile = try #require(try store.dispatch(Command("createProfile", [["name": "Other"]])).result?.string)
    let regular = try #require(try store.dispatch(Command("createWindow", [["profileId": .string(profile)]])).result?.string)
    let privateWindow = try #require(try store.dispatch(Command("createWindow", [["profileId": .string(profile), "incognito": true]])).result?.string)
    _ = try store.dispatch(Command("createWindow", []))
    let original = store.state.engineProfile(profile)
    let session = store.state.engineProfile(try #require(store.state.windows[privateWindow]?.profileId))
    #expect(ExtensionInstallLifetime.host(in: store.state, originalProfile: original, privateProfile: nil) == regular)
    #expect(ExtensionInstallLifetime.host(in: store.state, originalProfile: original, privateProfile: session) == privateWindow)
    #expect(ExtensionInstallLifetime.host(in: store.state, originalProfile: original, privateProfile: "another-session") == nil)
  }
}
