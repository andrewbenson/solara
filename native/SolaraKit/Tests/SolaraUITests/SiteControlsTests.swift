import Foundation
import Testing
import SolaraModel
import SolaraStore
@testable import SolaraUI

@Suite struct SiteControlsTests {
  func context(_ patch: JSONObject = [:]) -> JSONValue {
    var base: JSONObject = [
      "tabId": "t", "windowId": "w", "url": "https://example.com/a", "title": "Example", "label": "Example",
      "profileId": "default", "profile": "", "pageEngine": "chromium", "privatePage": false,
      "showFullUrl": false, "developerMode": [:], "recommendedEngine": "chromium", "streamingSite": false,
      "muted": false, "playingAudio": false, "camera": false, "microphone": false, "video": false, "pip": false,
      "blocked": 0, "zoom": 1, "dark": false, "theme": [:], "extensions": [], "translate": [],
    ]
    for (key, value) in patch { base[key] = value }
    return .object(base)
  }

  func rows(_ c: JSONValue, section: String? = nil, featured: Set<String>? = nil, settings: JSONValue? = nil, blocker: JSONValue? = nil) throws -> [SitePanelItem] {
    try #require(SiteControlsLogic.state(context: c, expanded: section, featured: featured, settings: settings, blocker: blocker, cleared: nil)).items
  }

  @Test func sleepRowTogglesExactSitesAndSendsParentsAndOffToSettings() throws {
    let plain = context(["sleepInactiveTabs": true, "keepAwakeSites": []])
    #expect(try rows(plain).first { $0.id == "sleep" }?.value == "On")
    #expect(SiteControlsLogic.action(.press("sleep", .zero), context: plain) == .keepAwake(["example.com"]))
    let exact = context(["keepAwakeSites": ["example.com", "other.com"]])
    #expect(try rows(exact).first { $0.id == "sleep" }?.value == "Never")
    #expect(SiteControlsLogic.action(.press("sleep", .zero), context: exact) == .keepAwake(["other.com"]))
    let parent = context(["url": "https://chat.example.com/x", "keepAwakeSites": ["example.com"]])
    #expect(try rows(parent).first { $0.id == "sleep" }?.value == "Never · via example.com")
    #expect(SiteControlsLogic.action(.press("sleep", .zero), context: parent) == .sleepSettings("keepAwake:example.com"))
    let off = context(["sleepInactiveTabs": false, "keepAwakeSites": ["example.com"]])
    #expect(try rows(off).first { $0.id == "sleep" }?.value == "Off")
    #expect(SiteControlsLogic.action(.press("sleep", .zero), context: off) == .sleepSettings(nil))
  }

  @Test func blockingReportsActualEngineAndAllowedState() throws {
    let enabled: JSONValue = ["enabled": true, "allowed": false]
    #expect(try rows(context(["blocked": 7]), blocker: enabled).first { $0.id == "blocker" }?.value == "On · 7 blocked on this page")
    #expect(try rows(context(), blocker: ["enabled": true, "allowed": true]).first { $0.id == "blocker" }?.value == "Off for this site")
    let webkit = try #require(rows(context(["pageEngine": "webkit"]), blocker: enabled).first { $0.id == "blocker" })
    #expect(webkit.value == "Chromium only for now")
    #expect(webkit.on == false && webkit.pressable == false)
  }

  @Test func missingPermissionsAndActiveCaptureRemainFeatured() {
    let settings: JSONValue = ["camera": ["isDefault": true, "value": "ask"], "microphone": ["isDefault": true], "sound": ["isDefault": true]]
    let featured = SiteControlsLogic.featuredPermissions(context: context(["camera": true, "playingAudio": true]), settings: settings)
    #expect(featured == Set(["camera", "sound", "location", "notifications", "popups"]))
    #expect(SiteControlsLogic.featuredPermissions(context: context(["pageEngine": "webkit"]), settings: settings).isEmpty)
  }

  @Test func privateEnginePickerNeverOffersPersistentDefault() throws {
    let c = context(["privatePage": true, "pageEngine": "webkit", "engineRule": "chromium"])
    #expect(SiteControlsLogic.engineChoices(context: c).map(\.id) == ["chromium", "webkit"])
    #expect(SiteControlsLogic.engineChoices(context: c).last?.checked == true)
    #expect(try rows(c).first { $0.id == "engine" }?.value == "WebKit")
  }

  @Test func developerModeHonorsDefaultsPrivateOwnerAndBoundedChanges() {
    let local = context(["url": "http://LOCALHOST:8080", "developerMode": ["default": ["on": [], "off": [], "reload": "forceReload"]]])
    #expect(SiteControlsLogic.developerEnabled(context: local))
    let changed = SiteControlsLogic.developerSettings(context: local, on: false)
    #expect(changed?["default"]?["off"]?.array == ["localhost"])
    #expect(changed?["default"]?["reload"] == "forceReload")
    let privateLocal = context(["url": "http://localhost", "profileId": "incognito:window@default", "privatePage": true])
    #expect(SiteControlsLogic.developerSettings(context: privateLocal, on: false) == nil)
    #expect(SiteControlsLogic.origin("HTTPS://EXAMPLE.COM:443/a") == "https://example.com")
    #expect(SiteControlsLogic.host("http://[::1]:8000") == "[::1]")
  }

  @Test func untrustedSecurityCannotBecomeSecureFromUrl() throws {
    let warning = try #require(rows(context(["security": ["level": "certificateError"]]), section: "connection").last?.chip)
    #expect(warning.title == "Not Secure" && warning.color == "#FF6B63")
    #expect(try rows(context()).last?.chip?.title == "Local Page")
    #expect(try rows(context(["security": ["level": "mixed"]])).last?.chip?.title == "Not Fully Secure")
  }

  @Test func contributionsStayInOrderAndMediaControlsDoNotDisappear() throws {
    let c = context([
      "extensions": [["kind": "section", "title": "Extensions"], ["kind": "extensions", "columns": 4, "extensions": []]],
      "translate": [["kind": "row", "id": "translate:toggle", "title": "Translate", "pressable": true]],
      "video": true, "pip": true,
    ])
    let all = try rows(c, section: "more", featured: [])
    #expect(all.first?.tiles?.last?.id == "pip")
    #expect(all.first?.tiles?.last?.active == true)
    let ids = all.compactMap(\.id)
    #expect(try #require(ids.firstIndex(of: "other-engine")) < #require(ids.firstIndex(of: "translate:toggle")))
    #expect(try #require(ids.firstIndex(of: "translate:toggle")) < #require(ids.firstIndex(of: "clear")))
    let internalRows = try rows(context(["url": "solara://settings"]), section: "more")
    #expect(!internalRows.contains { $0.id == "engine" || $0.id == "clear" })
    #expect(internalRows.contains { $0.id == "full-url" })
  }

  @Test func nativeContextUsesStoreFieldsAndSettingsInsteadOfPublishedOverrides() throws {
    var state = BrowserState()
    var tab = Tab(id: "t", windowId: "native-window", profileId: "default", url: "https://www.example.com:443/a", now: 0)
    tab.title = "Native title"
    tab.customTitle = "Custom title"
    tab.muted = true
    tab.zoom = 1.25
    state.tabs["t"] = tab
    state.settings["showFullUrl"] = true
    state.settings["websiteEngines"] = ["https://www.example.com": "webkit"]
    state.settings["pageEngine"] = "webkit"
    let c = try #require(SiteControlsLogic.context(state: state, tabId: "t", pageEngine: "chromium", input: [
      "url": "https://wrong.example", "windowId": "wrong", "profileId": "wrong", "pageEngine": "webkit",
      "privatePage": true, "zoom": 4, "muted": false, "showFullUrl": false, "engineRule": "chromium",
      "video": true, "blocked": 8, "security": ["level": "mixed"], "extensions": [], "translate": [],
    ]))
    #expect(c["url"] == .string(tab.url))
    #expect(c["windowId"] == "native-window" && c["profileId"] == "default" && c["profile"] == "")
    #expect(c["pageEngine"] == "chromium" && c["privatePage"] == false)
    #expect(c["muted"] == true && c["zoom"] == 1.25 && c["showFullUrl"] == true)
    #expect(c["title"] == "Native title" && c["label"] == "Custom title")
    #expect(c["engineRule"] == "webkit" && c["recommendedEngine"] == "webkit" && c["streamingSite"] == false)
    #expect(c["video"] == true && c["blocked"] == 8 && c["security"]?["level"] == "mixed")
    #expect(SiteControlsLogic.context(state: state, tabId: "gone", pageEngine: "chromium", input: [:]) == nil)
  }

  @Test func nativeRecommendationRequiresAnEnabledHttpsProtectedHost() throws {
    var state = BrowserState()
    state.settings["pageEngine"] = "chromium"
    state.settings["protectedVideoInWebKit"] = true
    for url in ["https://netflix.com/watch", "https://video.netflix.com/watch", "HTTPS://TV.APPLE.COM/"] {
      state.tabs["t"] = Tab(id: "t", windowId: "w", profileId: "default", url: url, now: 0)
      let c = try #require(SiteControlsLogic.context(state: state, tabId: "t", pageEngine: "chromium", input: [:]))
      #expect(c["streamingSite"] == true && c["recommendedEngine"] == "webkit")
    }
    for url in ["http://netflix.com/", "https://notnetflix.com/", "https://netflix.com.example/"] {
      state.tabs["t"]?.url = url
      let c = try #require(SiteControlsLogic.context(state: state, tabId: "t", pageEngine: "chromium", input: [:]))
      #expect(c["streamingSite"] == false && c["recommendedEngine"] == "chromium")
    }
    state.tabs["t"]?.url = "https://netflix.com/"
    state.settings["protectedVideoInWebKit"] = false
    #expect(SiteControlsLogic.context(state: state, tabId: "t", pageEngine: "chromium", input: [:])?["recommendedEngine"] == "chromium")
  }

  @Test func privateDeveloperModeInheritsTheOriginalProfileWithoutAllowingWrites() throws {
    var state = BrowserState()
    state.tabs["t"] = Tab(id: "t", windowId: "w", profileId: "incognito:w@work", url: "https://www.example.com", now: 0)
    state.settings["developerMode"] = ["work": ["on": ["example.com"], "off": [], "reload": "forceReload"]]
    let c = try #require(SiteControlsLogic.context(state: state, tabId: "t", pageEngine: "chromium", input: [:]))
    #expect(c["profile"] == "incognito:w@work" && c["privatePage"] == true)
    #expect(SiteControlsLogic.developerEnabled(context: c))
    #expect(SiteControlsLogic.developerSettings(context: c, on: false) == nil)
    #expect(try rows(c).first { $0.id == "developer" }?.pressable == false)
    let legacy = context(["profileId": "incognito:old", "privatePage": true, "developerMode": ["default": ["on": ["example.com"]]]])
    #expect(SiteControlsLogic.developerEnabled(context: legacy))
  }

  @Test func developerSettingsSanitizeDeduplicateAndPreserveOtherProfiles() throws {
    var on = (0..<1002).map { JSONValue.string("site\($0).example") }
    on += ["SITE1001.EXAMPLE", "", "localhost", .string(String(repeating: "x", count: 254)), true]
    let c = context(["url": "https://www.new.example", "developerMode": [
      "default": ["on": .array(on), "off": ["EXAMPLE.COM", "LOCALHOST", "localhost"], "reload": "forceReload"],
      "other": ["on": ["untouched.example"], "off": []],
    ]])
    let changed = try #require(SiteControlsLogic.developerSettings(context: c, on: true))
    let hosts = try #require(changed["default"]?["on"]?.array)
    #expect(hosts.count == 1000 && hosts.first == "site3.example" && hosts.last == "new.example")
    #expect(changed["default"]?["off"] == ["localhost"])
    #expect(changed["default"]?["reload"] == "forceReload")
    #expect(changed["other"] == c["developerMode"]?["other"])
    #expect(SiteControlsLogic.developerSettings(context: context(["url": "file:///a"]), on: true) == nil)
  }

  @Test func permissionChoicesAndPickerChecksMatchTheirSettings() throws {
    #expect(SiteControlsLogic.permissionChoices("camera") == ["ask", "allow", "block"])
    #expect(SiteControlsLogic.permissionChoices("sound") == ["allow", "block"])
    #expect(SiteControlsLogic.permissionChoices("popups") == ["allow", "block"])
    #expect(SiteControlsLogic.choiceTitle("sound", "ask") == "Allowed")
    #expect(SiteControlsLogic.choiceTitle("sound", "block") == "Muted")
    let choice = SiteControlsLogic.engineChoices(context: context(["recommendedEngine": "webkit", "streamingSite": true]))
    #expect(choice.map(\.id) == ["default", "chromium", "webkit"])
    #expect(choice.first?.title == "Recommended (WebKit)" && choice.first?.checked == true)
    let explicit = SiteControlsLogic.engineChoices(context: context(["engineRule": "webkit"]))
    #expect(explicit.first?.checked == false && explicit.last?.checked == true)
    let loaded = try rows(context(), featured: ["sound"], settings: ["sound": ["value": "block"]])
    #expect(loaded.first { $0.id == "perm:sound" }?.value == "Muted")
    #expect(loaded.first { $0.id == "perm:sound" }?.on == false)
    #expect(try rows(context(), featured: ["camera"]).first { $0.id == "perm:camera" }?.value == "…")
  }

  @Test func actionTilesAndExtensionColumnsFollowTheSamePageCapabilities() throws {
    let contribution: JSONValue = [["kind": "extensions", "columns": 99, "extensions": []]]
    let web = try rows(context(["extensions": contribution]))
    #expect(web.first?.tiles?.map(\.id) == ["share", "copy", "find", "cast"])
    #expect(web.first { $0.kind == "extensions" }?.columns == 4)
    let file = try rows(context(["url": "file:///a.pdf", "video": true, "extensions": contribution]))
    #expect(file.first?.tiles?.map(\.id) == ["copy", "find", "pip"])
    #expect(file.first { $0.kind == "extensions" }?.columns == 3)
    let internalPage = try rows(context(["url": "solara://settings", "extensions": contribution]))
    #expect(internalPage.first?.tiles?.map(\.id) == ["copy"])
    #expect(internalPage.first { $0.kind == "extensions" }?.columns == 4)
    #expect(internalPage.last?.top == 14)
    let malformed = try rows(context(["url": "https:"]))
    #expect(malformed.first?.tiles?.map(\.id) == ["share", "copy", "find"])
    #expect(!malformed.contains { $0.id == "engine" })
  }

  @Test func connectionDetailsPreserveCertificateWarningsNamesAndFingerprint() throws {
    let security: JSONValue = ["level": "secure", "protocol": "TLS 1.3", "certificate": [
      "subject": ["commonName": "", "displayName": "example.com", "organizations": ["Example", "Company"]],
      "issuer": ["commonName": "Issuer name", "displayName": "Issuer display", "organizations": ["Issuer organization"]],
      "validFrom": 0, "validUntil": 86400000, "sha256": "AB:cd 01-23",
    ]]
    let all = try rows(context(["security": security]), section: "connection")
    let detail = try #require(all.first { $0.id == "connection-row" })
    #expect(detail.title == "Connection is secure" && detail.detail == "Certificate issued by Issuer organization")
    let cert = try #require(all.first { $0.kind == "certificate" }?.rows)
    #expect(cert.first == ["Issued to", "example.com"])
    #expect(cert.contains(["Organization", "Example, Company"]))
    #expect(cert.contains(["Issued by", "Issuer name"]))
    #expect(cert.contains(["Protocol", "TLS 1.3"]))
    #expect(cert.last == ["SHA-256", "AB cd 01 23…"])
    #expect(cert.first { $0[0] == "Valid from" }?[1].isEmpty == false)
    let warning = try rows(context(["security": ["level": "insecure"]]), section: "connection")
    #expect(warning.first { $0.id == "connection-row" }?.detail == "Don't enter sensitive information on this site.")
  }

  @Test func refreshTokensIgnoreObsoleteCompletionsAndLatchFeaturedPermissionsOnce() throws {
    var session = SiteControlsSession()
    let first = context()
    let firstRefresh = session.beginRefresh(context: first)
    let token = try #require(firstRefresh)
    let unchangedRefresh = session.beginRefresh(context: first)
    #expect(unchangedRefresh == nil)
    let changed = context(["url": "https://next.example", "pageEngine": "webkit"])
    let changedRefresh = session.beginRefresh(context: changed)
    let next = try #require(changedRefresh)
    #expect(!session.accepts(token: token) && session.accepts(token: next))
    let obsoletePermissions = session.receivePermissions(context: first, settings: [:], token: token)
    #expect(!obsoletePermissions)
    #expect(session.featured == nil)
    let currentPermissions = session.receivePermissions(context: changed, settings: ["camera": ["isDefault": true], "microphone": ["isDefault": false]], token: next)
    #expect(currentPermissions)
    #expect(session.featured == ["microphone"])
    let finalRefresh = session.beginRefresh(context: first)
    let last = try #require(finalRefresh)
    let refreshedPermissions = session.receivePermissions(context: first, settings: [:], token: last)
    #expect(refreshedPermissions)
    #expect(session.featured == ["microphone"])
    session.invalidate()
    #expect(!session.accepts(token: last))
    let unsupportedRefresh = session.beginRefresh(context: context(["url": "file:///a"]))
    #expect(unsupportedRefresh == nil)
  }

  @Test func nativeContextResolvesSharedProfileDataForPrivateAndRegularTabs() throws {
    var state = BrowserState()
    state.profiles["work"] = Profile(id: "work", name: "Work", color: "blue", icon: nil, createdAt: 0, dataId: "shared-work")
    state.tabs["t"] = Tab(id: "t", windowId: "w", profileId: "work", url: "https://example.com", now: 0)
    #expect(SiteControlsLogic.context(state: state, tabId: "t", pageEngine: "chromium", input: [:])?["profile"] == "shared-work")
    state.tabs["t"]?.profileId = "incognito:w@work"
    #expect(SiteControlsLogic.context(state: state, tabId: "t", pageEngine: "chromium", input: [:])?["profile"] == "incognito:w@shared-work")
  }

  @Test func clickDecisionsPreserveExpansionPickersAndSharedActionNames() {
    let rect = CGRect(x: 10, y: 20, width: 30, height: 40)
    let c = context()
    #expect(SiteControlsLogic.action(.press("connection", rect), context: c) == .expand("connection"))
    #expect(SiteControlsLogic.action(.press("more", rect), context: c) == .expand("more"))
    #expect(SiteControlsLogic.action(.press("blocker", rect), context: c) == .blocker)
    #expect(SiteControlsLogic.action(.press("engine", rect), context: c) == .enginePicker)
    #expect(SiteControlsLogic.action(.press("clear", rect), context: c) == .clear)
    #expect(SiteControlsLogic.action(.press("perm:camera", rect), context: c) == .permission("camera"))
    for id in ["share", "copy", "find", "cast", "pip", "other-engine"] {
      #expect(SiteControlsLogic.action(.press(id, rect), context: c) == .shared(id))
    }
    #expect(SiteControlsLogic.action(.press("unknown", rect), context: c) == .none)
    #expect(SiteControlsLogic.action(.press("perm:unknown", rect), context: c) == .none)
    #expect(SiteControlsLogic.action(.press("perm:location", rect), context: context(["pageEngine": "webkit"])) == .none)
    #expect(SiteControlsLogic.action(.menu("engine", rect), context: c) == .none)
    #expect(SiteControlsLogic.action(.toggle("unknown", true), context: c) == .none)
    #expect(SiteControlsLogic.action(.press("full-url", rect), context: c) == .none)
  }

  @Test func developerClickUsesInheritedStateAndRejectsPrivateOrUnsupportedPages() throws {
    let rect = CGRect.zero
    let c = context(["developerMode": ["default": ["on": ["example.com"], "off": [], "reload": "forceReload"]]])
    let action = SiteControlsLogic.action(.press("developer", rect), context: c)
    guard case .developer(let changed) = action else { Issue.record("Expected developer settings"); return }
    #expect(changed["default"]?["on"] == [])
    #expect(changed["default"]?["reload"] == "forceReload")
    let local = context(["url": "http://localhost"])
    let expected = try #require(SiteControlsLogic.developerSettings(context: local, on: false))
    #expect(SiteControlsLogic.action(.press("developer", rect), context: local) == .developer(expected))
    #expect(SiteControlsLogic.action(.press("developer", rect), context: context(["privatePage": true])) == .none)
    #expect(SiteControlsLogic.action(.press("developer", rect), context: context(["url": "file:///a"])) == .none)
  }

  @Test func contributionEventsKeepTheirOwnersAndZoomAndFullURLUseTypedValues() {
    let c = context()
    for id in ["ext:add", "ext:an-extension", "translate:toggle", "translate:never"] {
      for event in [SitePanelEvent.press(id, .zero), .menu(id, .zero), .toggle(id, true), .zoom(id, 40)] {
        #expect(SiteControlsLogic.action(event, context: c) == .contribution)
      }
    }
    #expect(SiteControlsLogic.action(.toggle("full-url", true), context: c) == .fullURL(true))
    #expect(SiteControlsLogic.action(.toggle("full-url", false), context: c) == .fullURL(false))
    #expect(SiteControlsLogic.action(.zoom("zoom", 40), context: c) == .zoom(1))
    #expect(SiteControlsLogic.action(.zoom("zoom", -40), context: c) == .zoom(-1))
    #expect(SiteControlsLogic.action(.zoom("anything", -40), context: c) == .none)
    #expect(SiteControlsLogic.action(.zoom("zoom", 0), context: c) == .zoom(0))
  }
}
