import Foundation
import SolaraModel
import SolaraOmnibox
import SolaraStore
import Testing
@testable import SolaraUI

@MainActor
struct OmniboxActionControllerTests {
  @MainActor
  final class Fixture {
    let store: Store
    let model: HeroBarModel
    let controller: OmniboxActionController
    let field = FakeHeroField()
    let sources: NewTabSources
    var owned = true
    var available = true
    var fallback: [String] = []
    var copied: [String] = []
    var clipboard = ""
    var performed: [String] = []
    var dismissed: [BarDismissal?] = []
    var focused: [String] = []
    var menus = 0
    var extensions: [Suggestion] = []
    var removedHistory: [String] = []
    var dictations = 0
    var settingsPanes: [String?] = []

    init(variant: BarVariant = .panel, opensTab: Bool = false) {
      let madeSources = NewTabSources()
      sources = madeSources
      var state = BrowserState()
      var window = BrowserWindow(id: "w", profileId: "default", incognito: false, frame: nil, createdAt: 0)
      window.tabIds = ["t", "other"]
      window.activeTabIds["default"] = "t"
      state.windows["w"] = window
      state.windowOrder = ["w"]
      state.ui.focusedWindowId = "w"
      var tab = Tab(id: "t", windowId: "w", profileId: "default", url: "https://example.com/?utm_source=test&keep=yes", now: 0)
      tab.title = "An [example]"
      state.tabs["t"] = tab
      state.tabs["other"] = Tab(id: "other", windowId: "w", profileId: "default", url: "https://other.example/", now: 0)
      state.windowUi["w"] = WindowUi(json: ["panel": ["open": true, "initialText": ""]])
      store = Store(state: state, checksInvariants: false)
      model = HeroBarModel(windowId: "w", tabId: "t", profileId: "default", incognito: false,
        settings: { Settings(values: [:]) }, sources: madeSources, variant: variant, opensTab: opensTab, currentUrl: tab.url)
      controller = OmniboxActionController()
      model.field = field
      controller.ownsWorkspace = { [weak self] in self?.owned ?? false }
      controller.resolve = { [weak self] in guard let self, self.available else { return nil }; return self.store }
      controller.openSettings = { [weak self] pane in self?.settingsPanes.append(pane) }
      controller.performAction = { [weak self] id, _ in self?.performed.append(id); return true }
      controller.performExtension = { [weak self] suggestion, _ in self?.extensions.append(suggestion); return true }
      controller.removeHistory = { [weak self] url, _ in self?.removedHistory.append(url); return true }
      controller.dictate = { [weak self] _ in self?.dictations += 1; return true }
      controller.presentContextMenu = { [weak self] _ in self?.menus += 1 }
      controller.didDismiss = { [weak self] _, reason in self?.dismissed.append(reason) }
      controller.didSwitch = { [weak self] id in self?.focused.append(id) }
      var events = HeroBarEvents()
      events.open = { [weak self] _, _ in self?.fallback.append("open") }
      events.switchTo = { [weak self] _, _, _ in self?.fallback.append("switch") }
      events.runAction = { [weak self] _ in self?.fallback.append("action") }
      events.runExtension = { [weak self] _ in self?.fallback.append("extension") }
      events.removeHistory = { [weak self] _ in self?.fallback.append("history") }
      events.dictate = { [weak self] in self?.fallback.append("dictation") }
      events.done = { [weak self] _ in self?.fallback.append("done") }
      events.cancel = { [weak self] _ in self?.fallback.append("cancel") }
      events.contextMenu = { [weak self] _, _ in self?.fallback.append("menu") }
      events.copy = { [weak self] in self?.copied.append($0) }
      events.readClipboard = { [weak self] in self?.clipboard ?? "" }
      model.events = controller.decorate(events, model: { [weak self] in self?.model })
    }
  }

  @Test(arguments: [BarVariant.hero, .sidebar, .panel])
  func returnNavigatesEverySurfaceWithoutJavaScript(_ variant: BarVariant) {
    let fixture = Fixture(variant: variant)
    fixture.model.driverType("https://swift.example/path")
    fixture.model.key(HeroKey(.enter))
    #expect(fixture.store.state.tabs["t"]?.navigation?.url == "https://swift.example/path")
    #expect(fixture.fallback.isEmpty)
  }

  @Test func returnSearchesUsingTheNativeEngine() {
    let fixture = Fixture()
    fixture.model.driverType("two search words")
    fixture.model.key(HeroKey(.enter))
    #expect(fixture.store.state.tabs["t"]?.navigation?.url == searchUrl(fixture.model.engine, "two search words"))
    #expect(fixture.fallback.isEmpty)
  }

  @Test(arguments: [HeroKey(.enter, meta: true), HeroKey(.enter, alt: true)])
  func modifiedReturnCreatesAForegroundTab(_ key: HeroKey) {
    let fixture = Fixture()
    fixture.model.driverType("https://swift.example/")
    fixture.model.key(key)
    let state = fixture.store.state
    let active = state.windows["w"]?.activeTabIds["default"]
    #expect(active != "t")
    #expect(active.flatMap { state.tabs[$0]?.url } == "https://swift.example/")
    #expect(state.tabs["t"]?.url.contains("example.com") == true)
    #expect(fixture.fallback.isEmpty)
  }

  @Test func optionShiftReturnOpensInTheBackground() {
    let fixture = Fixture()
    fixture.model.driverType("https://background.example/")
    fixture.model.key(HeroKey(.enter, shift: true, alt: true))
    #expect(fixture.store.state.windows["w"]?.activeTabIds["default"] == "t")
    #expect(fixture.store.state.tabs.values.contains { $0.url == "https://background.example/" })
    #expect(fixture.focused.isEmpty)
    #expect(fixture.fallback.isEmpty)
  }

  @Test func shiftReturnCreatesAWindow() {
    let fixture = Fixture()
    fixture.model.driverType("https://window.example/")
    fixture.model.key(HeroKey(.enter, shift: true))
    #expect(fixture.store.state.windows.count == 2)
    #expect(fixture.store.state.tabs.values.contains { $0.windowId != "w" && $0.url == "https://window.example/" })
    #expect(fixture.fallback.isEmpty)
  }

  @Test func commandShiftReturnKeepsVerbatimSearch() {
    let fixture = Fixture()
    fixture.model.driverType("example.com")
    fixture.model.key(HeroKey(.enter, shift: true, meta: true))
    #expect(fixture.store.state.tabs["t"]?.navigation?.url == searchUrl(fixture.model.engine, "example.com"))
    #expect(fixture.store.state.tabs.count == 2)
  }

  @Test func controlReturnKeepsTheWwwShortcut() {
    let fixture = Fixture()
    fixture.model.driverType("solara")
    fixture.model.key(HeroKey(.enter, ctrl: true))
    #expect(fixture.store.state.tabs["t"]?.navigation?.url == "https://www.solara.com")
    #expect(fixture.fallback.isEmpty)
  }

  @Test func aSwitchSuggestionActivatesItsExistingTab() {
    let fixture = Fixture()
    fixture.model.chooseRow(.page(url: "https://other.example/", title: "Other", favicon: nil, tabId: "other"))
    #expect(fixture.store.state.windows["w"]?.activeTabIds["default"] == "other")
    #expect(fixture.store.state.tabs.count == 2)
    #expect(fixture.fallback.isEmpty)
  }

  @Test func aMovedSourceCannotSwitchFromItsOldProfile() throws {
    for disposition in [Disposition.current, .newTab] {
      let fixture = Fixture()
      let profile = try fixture.store.dispatch(Command("createProfile", [["name": "Work"]])).result!.string!
      try fixture.store.dispatch(Command("moveTabToProfile", ["t", .string(profile)]))
      try fixture.store.dispatch(Command("switchProfile", ["w", .string(profile)]))
      #expect(fixture.store.state.activeTabId("w") == "t")
      let before = fixture.store.state
      fixture.model.events.switchTo("other", "https://other.example/", disposition)
      #expect(fixture.store.state == before)
      #expect(fixture.fallback.isEmpty)
    }
  }

  @Test func chosenPagesAndSuggestedSearchesOpenTheirExactNativeTargets() {
    let fixture = Fixture()
    fixture.model.chooseRow(.page(url: "https://chosen.example/path", title: "Chosen", favicon: nil))
    #expect(fixture.store.state.tabs["t"]?.navigation?.url == "https://chosen.example/path")
    fixture.model.chooseRow(.search(query: "suggested words", url: "https://search.example/?q=suggested", engine: "Custom", suggested: true))
    #expect(fixture.store.state.tabs["t"]?.navigation?.url == "https://search.example/?q=suggested")
    fixture.model.chooseRow(.create(id: "new-document", title: "New Document", url: "https://docs.example/create", site: "docs.example"))
    #expect(fixture.store.state.tabs["t"]?.navigation?.url == "https://docs.example/create")
    #expect(fixture.fallback.isEmpty)
  }

  @Test func calculatorCopiesInsteadOfNavigating() {
    let fixture = Fixture()
    fixture.model.chooseRow(.calc(expression: "2+2", value: "4", url: "https://search.example/?q=2%2B2"))
    #expect(fixture.copied == ["4"])
    #expect(fixture.model.typed == "4")
    #expect(fixture.store.state.tabs["t"]?.url.contains("example.com") == true)
    #expect(fixture.fallback.isEmpty)
  }

  @Test func clipboardClassificationAndPasteAndGoStayNative() {
    let fixture = Fixture()
    fixture.clipboard = "  https://example.com/path?utm_source=tracking&keep=1  "
    #expect(fixture.model.pasteAction == .go(url: "https://example.com/path?keep=1"))
    fixture.model.apply(.pasteAndGo)
    #expect(fixture.store.state.tabs["t"]?.navigation?.url == "https://example.com/path?keep=1")
    #expect(fixture.fallback.isEmpty)
  }

  @Test func pasteAndSearchUsesTheSelectedEngineAndRejectsAnEmptyClipboard() {
    let fixture = Fixture()
    fixture.clipboard = "two\nwords"
    #expect(fixture.model.pasteAction == .search(query: "two words"))
    fixture.model.apply(.pasteAndGo)
    #expect(fixture.store.state.tabs["t"]?.navigation?.url == searchUrl(fixture.model.engine, "two words"))
    fixture.clipboard = " \n "
    let revision = fixture.store.rev
    fixture.model.apply(.pasteAndGo)
    #expect(fixture.store.rev == revision)
  }

  @Test func ordinaryPasteSanitizesWithoutNavigating() {
    for (clipboard, expected) in [
      ("  alpha\n beta  ", "alphabeta"),
      ("  alpha beta\n gamma  ", "alpha beta gamma"),
    ] {
      let fixture = Fixture()
      let before = fixture.store.snapshot
      fixture.clipboard = clipboard
      fixture.model.apply(.paste)
      #expect(fixture.model.typed == expected)
      #expect(fixture.model.suppressCompletion)
      #expect(fixture.store.state == before.state)
      #expect(fixture.store.rev == before.rev)
    }
  }

  @Test func copyURLAndMarkdownUseTheNativeCurrentTab() {
    let fixture = Fixture()
    fixture.model.apply(.copyURL)
    fixture.model.events.runAction("copyUrl")
    fixture.model.events.runAction("copyUrlAsMarkdown")
    #expect(fixture.copied == ["https://example.com/?keep=yes", "https://example.com/?keep=yes", "[An \\[example\\]](https://example.com/?keep=yes)"])
    #expect(fixture.performed.isEmpty)
    #expect(fixture.fallback.isEmpty)
  }

  @Test func escapeClosesTheNativePanel() {
    let fixture = Fixture()
    fixture.model.key(HeroKey(.escape))
    #expect(fixture.store.state.windowUi["w"]?.panelOpen == false)
    #expect(fixture.dismissed.count == 1)
    #expect(fixture.dismissed.first! == .escape)
    #expect(fixture.fallback.isEmpty)
  }

  @Test func escapeRestoresAHighlightedFillBeforeDismissing() throws {
    let fixture = Fixture()
    fixture.sources.setHistory([
      HistoryRow(url: "https://github.com/", title: "GitHub", favicon: nil, visits: 20, lastVisit: Date().timeIntervalSince1970 * 1000),
    ], profileId: "default")
    fixture.model.driverType("git")
    let typed = fixture.model.value
    fixture.model.key(HeroKey(.arrowDown))
    _ = try #require(fixture.model.filled)
    fixture.model.key(HeroKey(.escape))
    #expect(fixture.model.value == typed)
    #expect(fixture.dismissed.isEmpty)
    #expect(fixture.store.state.windowUi["w"]?.panelOpen == true)
    #expect(fixture.fallback.isEmpty)
  }

  @Test func escapeLeavesAScopeBeforeClosingThePanel() {
    let fixture = Fixture()
    fixture.model.enterScope(SearchScope(kind: .site, name: "Example", host: "example.com", url: "https://example.com/search?q=%s"), from: "example.com")
    fixture.model.key(HeroKey(.escape))
    #expect(fixture.model.scope == nil)
    #expect(fixture.dismissed.isEmpty)
    #expect(fixture.store.state.windowUi["w"]?.panelOpen == true)
    fixture.model.key(HeroKey(.escape))
    #expect(fixture.dismissed.count == 1)
    #expect(fixture.store.state.windowUi["w"]?.panelOpen == false)
  }

  @Test func escapeInTheHeroClearsTextWithoutClosingAPanel() {
    let fixture = Fixture(variant: .hero)
    fixture.model.driverType("some text")
    fixture.model.key(HeroKey(.escape))
    #expect(fixture.model.typed.isEmpty)
    #expect(fixture.dismissed.isEmpty)
    #expect(fixture.store.state.windowUi["w"]?.panelOpen == true)
  }

  @Test func commandActionsAndContextMenusUseTheirNativeOwners() {
    let fixture = Fixture()
    fixture.model.events.runAction("newTab")
    fixture.model.contextMenu()
    #expect(fixture.performed == ["newTab"])
    #expect(fixture.menus == 1)
    #expect(fixture.fallback.isEmpty)
  }

  @Test func commandsOutsideTheNativeActionOwnersKeepTheirExistingFallback() {
    let fixture = Fixture()
    fixture.controller.performAction = { _, _ in false }
    fixture.model.events.runAction("renameTab")
    #expect(fixture.fallback == ["action"])
  }

  @Test func extensionsHistoryRemovalAndDictationUseNativeOwners() {
    let fixture = Fixture()
    let suggestion = Suggestion.extension(id: "fixture-extension", title: "Fixture", icon: nil, open: .options)
    fixture.model.chooseRow(suggestion)
    fixture.model.removeRow("https://history.example/")
    fixture.model.dictatePressed()
    #expect(fixture.extensions == [suggestion])
    #expect(fixture.removedHistory == ["https://history.example/"])
    #expect(fixture.dictations == 1)
    #expect(fixture.fallback.isEmpty)
  }

  @Test func unownedExtensionHistoryAndDictationCallbacksKeepTheirFallback() {
    let fixture = Fixture()
    fixture.controller.performExtension = { _, _ in false }
    fixture.controller.removeHistory = { _, _ in false }
    fixture.controller.dictate = { _ in false }
    fixture.model.events.runExtension(.extension(id: "fixture", title: "Fixture", icon: nil, open: .action))
    fixture.model.removeRow("https://history.example/")
    fixture.model.dictatePressed()
    #expect(fixture.fallback == ["extension", "history", "dictation"])
  }

  @Test func ownershipLossAndMissingStoreReturnToTheFallback() {
    let fixture = Fixture()
    fixture.owned = false
    #expect(!fixture.controller.ownsActions)
    fixture.model.events.open("https://fallback.example/", .current)
    fixture.model.events.switchTo("other", "https://other.example/", .current)
    fixture.model.events.runAction("newTab")
    fixture.model.events.runExtension(.extension(id: "fixture", title: "Fixture", icon: nil, open: .action))
    fixture.model.removeRow("https://history.example/")
    fixture.model.dictatePressed()
    fixture.model.events.done(.escape)
    fixture.model.events.cancel(fixture.model.editingSession)
    fixture.model.contextMenu()
    #expect(fixture.fallback == ["open", "switch", "action", "extension", "history", "dictation", "done", "cancel", "menu"])
    fixture.owned = true
    fixture.available = false
    fixture.model.events.open("https://fallback.example/", .current)
    #expect(fixture.fallback.last == "open")
    fixture.available = true
    #expect(fixture.controller.ownsActions)
    fixture.model.events.open("https://native.example/", .current)
    #expect(fixture.fallback.count == 10)
    #expect(fixture.store.state.tabs["t"]?.navigation?.url == "https://native.example/")
  }

  @Test func staleSourcesAndEditingSessionsNeverFallThroughToJavaScript() throws {
    let fixture = Fixture()
    fixture.model.events.cancel(UUID())
    #expect(fixture.store.state.windowUi["w"]?.panelOpen == true)
    _ = try fixture.store.dispatch(Command("closeTab", [.string("t")]))
    fixture.model.events.open("https://stale.example/", .current)
    fixture.model.events.switchTo("other", "https://other.example/", .current)
    #expect(fixture.fallback.isEmpty)
    #expect(fixture.store.state.tabs.values.allSatisfy { $0.url != "https://stale.example/" })
  }

  @Test func explicitHostCancellationUsesTheSameOwnershipAndSessionFences() {
    let fixture = Fixture()
    #expect(fixture.controller.cancel(fixture.model, session: UUID()))
    #expect(fixture.dismissed.isEmpty)
    #expect(fixture.controller.cancel(fixture.model, session: fixture.model.editingSession))
    #expect(fixture.dismissed.count == 1)
    fixture.owned = false
    #expect(!fixture.controller.dismiss(fixture.model, reason: .escape))
    #expect(!fixture.controller.cancel(fixture.model))
  }

  @Test func replacedBarsCannotDismissCopyOrRunActionsForTheNewActiveTab() throws {
    let fixture = Fixture()
    _ = try fixture.store.dispatch(Command("activate", [.string("other")]))
    _ = try fixture.store.dispatch(Command("openPanel", [.string("w"), .string("replacement")]))
    fixture.model.events.cancel(fixture.model.editingSession)
    fixture.model.events.done(.escape)
    #expect(fixture.controller.cancel(fixture.model))
    fixture.model.events.runAction("copyUrl")
    fixture.model.events.runAction("copyUrlAsMarkdown")
    fixture.model.events.runAction("newTab")
    fixture.model.events.runExtension(.extension(id: "fixture", title: "Fixture", icon: nil, open: .action))
    fixture.model.removeRow("https://history.example/")
    fixture.model.dictatePressed()
    fixture.model.contextMenu()
    #expect(fixture.store.state.windowUi["w"]?.panelOpen == true)
    #expect(fixture.store.state.windowUi["w"]?.json["panel"]?["initialText"]?.string == "replacement")
    #expect(fixture.dismissed.isEmpty)
    #expect(fixture.copied.isEmpty)
    #expect(fixture.performed.isEmpty)
    #expect(fixture.menus == 0)
    #expect(fixture.extensions.isEmpty)
    #expect(fixture.removedHistory.isEmpty)
    #expect(fixture.dictations == 0)
    #expect(fixture.fallback.isEmpty)
  }

  @Test func returnToSettingsOpensTheNativeUtilityWithoutChangingTheSource() {
    let fixture = Fixture()
    let before = fixture.store.state.tabs["t"]
    fixture.model.driverType("solara://settings")
    fixture.model.key(HeroKey(.enter))
    #expect(fixture.settingsPanes.count == 1)
    #expect(fixture.settingsPanes[0] == nil)
    #expect(fixture.store.state.tabs["t"] == before)
    #expect(fixture.store.state.tabs.count == 2)
    #expect(fixture.store.state.windowUi["w"]?.panelOpen == false)
    #expect(fixture.fallback.isEmpty)
  }

  @Test func nativeSettingsRoutesKeepTheExistingPaneAliases() {
    let aliases: [(String, String)] = [
      ("general", "general"), ("profiles", "profiles"), ("people", "profiles"), ("manageProfile", "profiles"),
      ("sync", "sync"), ("syncSetup", "sync"), ("tabs", "tabs"), ("appearance", "appearance"), ("privacy", "privacy"),
      ("passwords", "passwords"), ("autofill", "autofill"), ("addresses", "autofill"), ("payments", "autofill"),
      ("extensions", "extensions"), ("search", "search"), ("searchEngines", "search"), ("engines", "engines"),
      ("shortcuts", "shortcuts"), ("liveFolders", "liveFolders"), ("calendar", "calendar"), ("advanced", "advanced"),
    ]
    for (section, pane) in aliases {
      let fixture = Fixture()
      fixture.model.events.open("solara://settings/" + section, .current)
      #expect(fixture.settingsPanes == [pane])
      #expect(fixture.store.state.tabs["t"]?.navigation == nil)
      #expect(fixture.fallback.isEmpty)
    }
  }

  @Test func pasteAndGoToSettingsUsesTheNativeUtility() {
    let fixture = Fixture()
    fixture.clipboard = "solara://settings/searchEngines"
    fixture.model.apply(.pasteAndGo)
    #expect(fixture.settingsPanes == ["search"])
    #expect(fixture.store.state.tabs["t"]?.navigation == nil)
    #expect(fixture.fallback.isEmpty)
  }

  @Test func modifiedSettingsReturnDoesNotCreateAnEmptyTab() {
    let fixture = Fixture()
    fixture.model.driverType("solara://settings/shortcuts")
    fixture.model.key(HeroKey(.enter, meta: true))
    #expect(fixture.settingsPanes == ["shortcuts"])
    #expect(fixture.store.state.tabs.count == 2)
    #expect(fixture.fallback.isEmpty)
  }

  @Test func unknownSettingsSectionsStayWithTheEngine() {
    let fixture = Fixture()
    fixture.model.events.open("solara://settings/languages", .current)
    #expect(fixture.settingsPanes.isEmpty)
    #expect(fixture.store.state.tabs["t"]?.navigation?.url == "solara://settings/languages")
    #expect(fixture.fallback.isEmpty)
  }

  @Test func shiftReturnToSettingsKeepsANewEngineWindow() {
    let fixture = Fixture()
    fixture.model.events.open("solara://settings/privacy", .newWindow)
    #expect(fixture.settingsPanes.isEmpty)
    #expect(fixture.store.state.windows.count == 2)
    #expect(fixture.store.state.tabs.values.contains { $0.windowId != "w" && $0.navigation?.url == "solara://settings/privacy" })
    #expect(fixture.fallback.isEmpty)
  }

  @Test func returnToNewTabUsesTheCanonicalCreationAction() {
    let fixture = Fixture()
    let before = fixture.store.state.tabs["t"]
    fixture.model.driverType("solara://newtab")
    fixture.model.key(HeroKey(.enter))
    let active = fixture.store.state.activeTabId("w")
    #expect(active != nil && active != "t")
    #expect(active.flatMap { fixture.store.state.tabs[$0]?.url } == "")
    #expect(fixture.store.state.tabs["t"] == before)
    #expect(fixture.store.state.tabs.count == 3)
    #expect(fixture.focused == ["w"])
    #expect(fixture.fallback.isEmpty)
  }

  @Test func pasteAndGoToNewTabKeepsTheSourceAndCreatesAnEmptyPage() {
    let fixture = Fixture()
    fixture.clipboard = "solara://newtab"
    fixture.model.apply(.pasteAndGo)
    #expect(fixture.store.state.activeTabId("w") != "t")
    #expect(fixture.store.state.tabs["t"]?.navigation == nil)
    #expect(fixture.store.state.tabs.count == 3)
    #expect(fixture.fallback.isEmpty)
  }

  @Test func staleApplicationURLsCannotOpenAUtilityOrCreateATab() throws {
    let fixture = Fixture()
    _ = try fixture.store.dispatch(Command("activate", ["other"]))
    let before = fixture.store.state
    fixture.model.events.open("solara://settings", .current)
    fixture.model.events.open("solara://newtab", .current)
    #expect(fixture.settingsPanes.isEmpty)
    #expect(fixture.store.state == before)
    #expect(fixture.fallback.isEmpty)
  }
}
