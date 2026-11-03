import Foundation
import Testing
@testable import SolaraUI

struct SettingsSearchTests {
  let index = SettingsIndex(appName: "Solara")
  let prepared: [SettingsSearch.Prepared]

  init() {
    prepared = SettingsSearch.prepare(index.entries)
  }

  func hits(_ query: String) -> [SettingsSearchHit] { SettingsSearch.search(prepared, query) }
  func ids(_ query: String) -> [String] { hits(query).map(\.entry.id) }
  func first(_ query: String) -> String? { ids(query).first }

  @Test func synonymsFindTheSettingTheyStandFor() {
    #expect(first("cookies") == "privacy.blockCookieBanners")
    #expect(first("dark") == "appearance.theme")
    #expect(first("dark mode") == "appearance.theme")
    #expect(first("adblock") == "privacy.blockAds")
    #expect(first("pip") == "tabs.autoPictureInPicture")
    #expect(first("vertical tabs") == "tabs.layout")
    #expect(first("1password") == "passwords.managerApps")
    #expect(first("app icon") == "appearance.appIcon")
    #expect(first("dock") == "appearance.appIcon")
  }

  @Test func aPanesNameFindsThatPanesRowsFirst() {
    let found = hits("password")
    let passwordRows = index.entries.filter { $0.pane == .passwords }.map(\.id)
    #expect(passwordRows.allSatisfy { id in found.contains { $0.entry.id == id } })
    #expect(SettingsSearch.groupByPane(found).first?.pane == .passwords)
  }

  @Test func titlesRankAboveDescriptions() {
    #expect(first("history") == "advanced.history")
    #expect(first("recently closed") == "general.windowsAndTabs")
    let dark = hits("dark")
    #expect(dark.allSatisfy { $0.entry.id == "appearance.theme" || $0.score < dark[0].score })
  }

  @Test func typosStillFindTheSetting() {
    #expect(first("trakers") == "privacy.blockTrackers")
    #expect(hits("pasword").first?.entry.pane == .passwords)
    #expect(first("appearence") == "appearance.theme")
    #expect(first("upscalling") == "tabs.videoUpscaling")
    #expect(first("extensoins") == "extensions.installed")
  }

  @Test func everyWordOfTheQueryHasToMatch() {
    #expect(first("block ads") == "privacy.blockAds")
    #expect(!ids("block ads").contains("privacy.blockTrackers"))
    #expect(first("warn quitting") == "general.warnBeforeQuitting")
  }

  @Test(arguments: ["zzzz", "qwxv", "xylophone", "asdfgh", "kubernetes"])
  func garbageFindsNothing(_ query: String) {
    #expect(ids(query).isEmpty)
  }

  @Test func shortQueriesMatchWordStartsOnly() {
    #expect(ids("ta").allSatisfy { index.entry($0) != nil })
    #expect(!ids("ar").contains("privacy.blockTrackers"))
  }

  @Test func resultsGroupByPaneBestGroupFirstBestRowFirst() {
    let groups = SettingsSearch.groupByPane(hits("tabs"))
    #expect(groups.first?.pane == .tabs)
    for group in groups {
      for i in group.hits.indices.dropFirst() { #expect(group.hits[i - 1].score >= group.hits[i].score) }
    }
    #expect(Set(groups.map(\.pane)).count == groups.count)
  }

  @Test func anEmptyQueryFindsNothing() {
    #expect(ids("").isEmpty)
    #expect(ids("   ").isEmpty)
  }

  @Test func editDistanceCountsASwapAsOneEdit() {
    #expect(SettingsSearch.editDistance("tabs", "tbas", limit: 2) == 1)
    #expect(SettingsSearch.editDistance("kitten", "sitting", limit: 3) == 3)
    #expect(SettingsSearch.editDistance("abc", "abcdefg", limit: 2) == 3)
  }

  @Test func normalizeMatchesTheJavaScript() {
    #expect(SettingsSearch.normalize("  Café’s ⌘-Click!! ") == "cafes ⌘ click")
    #expect(SettingsSearch.normalize("Privacy & Security") == "privacy security")
    #expect(SettingsSearch.normalize("--") == "")
  }

  @Test func theIndexHas114RowsWithUniqueIds() {
    #expect(index.entries.count == 114)
    #expect(Set(index.entries.map(\.id)).count == index.entries.count)
  }

  @Test func theAppNameFillsTheWording() {
    #expect(index["general.openAtLogin"].title == "Open Solara at login")
    #expect(index["advanced.cliControl"].title == "Let the solara command control Solara")
  }

  @Test func everyDisplayCaptionFitsUnderItsTitle() {
    for entry in index.entries {
      if let caption = entry.displayCaption {
        #expect(caption.count <= 90, "\(entry.id): \(caption.count) characters")
      }
    }
  }

  @Test func searchKeepsWordsDroppedFromTheCaption() {
    let entry = index["tabs.fadeUnloadedTabs"]
    let word = "relaunch"
    #expect(SettingsSearch.words(entry.description ?? "").contains(word))
    let displayed = [entry.title, entry.keywords.joined(separator: " "), entry.section, entry.paneTitle, entry.displayCaption ?? ""]
    #expect(displayed.allSatisfy { !SettingsSearch.words($0).contains(word) })
    #expect(!SettingsSearch.words(entry.displayCaption ?? "").contains(word))
    let found = hits(word)
    #expect(found.contains { $0.entry.id == entry.id && $0.score == 2.0 })
  }

  @Test func searchIndexesWordsFoundOnlyInTheCaption() {
    let entry = SettingEntry(
      id: "tabs.example",
      pane: .tabs,
      section: "General",
      title: "Example",
      description: "Original explanation.",
      caption: "Concise wording.",
      keywords: [],
      liquidGlassOnly: false
    )
    let found = SettingsSearch.search(SettingsSearch.prepare([entry]), "concise")
    #expect(found.map(\.entry.id) == [entry.id])
    #expect(found.first?.score == 2.0)
  }

  @Test func aboutAnswersVersionQuestions() {
    #expect(ids("chromium").contains("about.chromium"))
    #expect(ids("version").contains("about.version"))
    #expect(hits("update").first?.entry.pane == .about)
    #expect(!index.entries.contains { $0.pane == .general && $0.section == "Updates" })
  }

  @Test func thePinnedTabLookIsFoundWithAndWithoutLiquidGlass() async {
    await MainActor.run {
      for liquidGlass in [false, true] {
        let model = SettingsSearchModel(index: index, liquidGlass: liquidGlass)
        model.query = "icon ring"
        #expect(model.results.contains { $0.id == "tabs.classicPinnedTabs" })
      }
    }
  }

  @Test func everyIndexedSettingIsAnchoredInItsPaneAndEveryAnchorIsIndexed() throws {
    let panes = URL(fileURLWithPath: #filePath)
      .deletingLastPathComponent()
      .appendingPathComponent("../../Sources/SolaraUI/Settings/Panes")
      .standardizedFileURL
    let files = try FileManager.default.contentsOfDirectory(at: panes, includingPropertiesForKeys: nil).filter { $0.pathExtension == "swift" }
    let sources = try files.map { try String(contentsOf: $0, encoding: .utf8) }.joined(separator: "\n")
    let paneNames = Set(SettingsPane.allCases.map(\.rawValue))
    let pattern = try NSRegularExpression(pattern: "\"([a-zA-Z]+)\\.([a-zA-Z]+)\"")
    let range = NSRange(sources.startIndex..., in: sources)
    let anchors = Set(pattern.matches(in: sources, range: range).compactMap { match -> String? in
      let pane = String(sources[Range(match.range(at: 1), in: sources)!])
      let key = String(sources[Range(match.range(at: 2), in: sources)!])
      return paneNames.contains(pane) ? "\(pane).\(key)" : nil
    })
    let ported = Set(files.map { $0.deletingPathExtension().lastPathComponent })
    for entry in index.entries where ported.contains(Self.fileName(entry.pane)) {
      #expect(anchors.contains(entry.id), "\(entry.id) is in the index but no pane anchors it")
    }
    for anchor in anchors {
      #expect(index.entry(anchor) != nil, "\(anchor) is anchored in a pane but not in the index")
    }
  }

  static func fileName(_ pane: SettingsPane) -> String {
    switch pane {
    case .general: "GeneralPane"
    case .profiles: "ProfilesPane"
    case .sync: "SyncPane"
    case .tabs: "TabsPane"
    case .appearance: "AppearancePane"
    case .privacy: "PrivacyPane"
    case .passwords: "PasswordsPane"
    case .autofill: "AutofillPane"
    case .extensions: "ExtensionsPane"
    case .search: "SearchEnginePane"
    case .engines: "EnginesPane"
    case .shortcuts: "ShortcutsPane"
    case .liveFolders: "LiveFoldersPane"
    case .calendar: "CalendarPane"
    case .advanced: "AdvancedPane"
    case .about: "AboutPane"
    }
  }
}
