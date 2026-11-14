import AppKit
import Foundation
import Observation
import SolaraEngine
import SolaraModel
import SolaraOmnibox
import Testing
@testable import SolaraUI

struct NewTabSpringTests {
  func run(_ params: SpringParams, from: Double) -> [Double] {
    var spring = RNSpring(params, from: from)
    var out: [Double] = []
    for frame in 0..<200 {
      out.append(spring.step(at: Double(frame) / 60))
      if spring.finished { break }
    }
    return out
  }

  @Test func layersMatchReactNativeFrameByFrame() {
    let expected: [(MarkLayer.Name, Int, [Double])] = [
      (.sun, 76, [55.124572, 49.690077, 37.797695, 22.773031, 10.236090, 3.870401, 0.200112]),
      (.back, 72, [39.576350, 34.064338, 22.923709, 10.717320, 2.779946, 0.158876, -0.218480]),
      (.front, 59, [33.069633, 27.547189, 16.682420, 5.715699, 0.010376, -0.853689, -0.116423]),
    ]
    for (name, frames, values) in expected {
      let layer = MarkIntro.layers.first { $0.name == name }!
      let out = run(layer.spring, from: layer.hidden)
      #expect(out.count == frames, "\(name) settles after \(out.count) frames")
      #expect(out.first == layer.hidden)
      #expect(out.last == 0)
      for (i, frame) in [1, 3, 6, 10, 15, 20, 30].enumerated() {
        #expect(abs(out[frame] - values[i]) < 1e-4, "\(name) frame \(frame): \(out[frame]) vs \(values[i])")
      }
    }
    let drift = run(MarkIntro.sunDriftSpring, from: MarkIntro.sunDrift)
    #expect(drift.count == 80)
    #expect(abs(drift[10] - 2.875801) < 1e-4)
  }

  @Test func aDroppedFrameAdvancesAtMost64Milliseconds() {
    var a = RNSpring(MarkIntro.layers[0].spring, from: 56)
    _ = a.step(at: 0)
    let late = a.step(at: 0.5)
    var b = RNSpring(MarkIntro.layers[0].spring, from: 56)
    _ = b.step(at: 0)
    #expect(late == b.step(at: 0.064))
  }

  @Test func eachLayerWaitsForItsDelay() {
    var player = MarkIntroPlayer()
    player.start(at: 10)
    var offsets = player.step(at: 10)
    #expect(offsets.y[.sun] == 56 && offsets.y[.back] == 40.5 && offsets.y[.front] == 34 && offsets.sunX == 6)
    offsets = player.step(at: 10.1)
    #expect(offsets.y[.front] == 34)
    offsets = player.step(at: 10.12)
    #expect(offsets.y[.front]! < 34)
    #expect(offsets.y[.back] == 40.5)
    var t = 10.12
    while !player.finished && t < 13 {
      t += 1.0 / 60
      offsets = player.step(at: t)
    }
    #expect(player.finished)
    #expect(offsets == .rest)
  }
}

struct NewTabLayoutTests {
  @Test func barMatchesTheReactLayout() {
    #expect(NewTabLayout.barWidth(600) == 572)
    #expect(NewTabLayout.barWidth(700) == 616)
    #expect(NewTabLayout.barWidth(1200) == 652)
    #expect(NewTabLayout.barWidth(1800) == 774)
    #expect(NewTabLayout.barTop(height: 900, under: 0) == 331, "\(NewTabLayout.barTop(height: 900, under: 0))")
    #expect(NewTabLayout.barTop(height: 900, under: 0, headingHeight: 80) == NewTabLayout.barTop(height: 900, under: 0))
    let small = NewTabLayout.barTop(height: 400, under: 0, headingHeight: 80)
    #expect(NewTabLayout.headingTop(barTop: small, headingHeight: 80) >= 16)
  }

  @Test func theMarkSitsOnWholePixelsAboveTheBar() {
    let f = NewTabLayout.frames(size: CGSize(width: 1201, height: 800), under: 0, headingHeight: 0, barHeight: 111, scale: 2)
    #expect(f.bar.minY == 281)
    #expect(f.mark.minY == 197)
    #expect(f.mark.height == 84)
    #expect(f.mark.minX == 551.5)
    #expect(f.bar.minX == 275.5)
  }
}

struct NewTabInlineTests {
  func sup(_ typed: String, _ shown: String, _ next: String) -> Bool {
    InlineRules.preventsInline(typed: typed, shown: shown, next: next, edit: nil)
  }

  func sel(_ start: Int, _ end: Int? = nil) -> TextSelection { TextSelection(start: start, end: end ?? start) }

  func edit(_ typed: String, _ shown: String, _ next: String, _ before: TextSelection, _ after: TextSelection) -> Bool {
    InlineRules.preventsInline(typed: typed, shown: shown, next: next, edit: EditContext(before: before, after: after))
  }

  @Test func deletionDropsTheCompletionTypingBringsItBack() {
    #expect(sup("gi", "thub.com", "gi"))
    #expect(sup("gi", "", "g"))
    #expect(sup("github", "", ""))
    #expect(sup("github", "", "gihub"))
    #expect(sup("github", "", "hub"))
    #expect(sup("gi", "thub.com", "thub.com"))
    #expect(!sup("gi", "thub.com", "git"))
    #expect(!sup("gi", "thub.com", "gix"))
    #expect(!sup("gi", "", "git"))
    #expect(!sup("", "", "g"))
    #expect(!sup("github", "", "gx"))
    #expect(!sup("github", "", "xthub"))
  }

  @Test func aReplacedSelectionIsTypingARemovalIsADeletion() {
    #expect(!edit("gi", "", "g", sel(0, 2), sel(1)))
    #expect(!edit("gi", "thub.com", "g", sel(0, 10), sel(1)))
    #expect(edit("gi", "", "g", sel(2), sel(1)))
    #expect(edit("gi", "thub.com", "gi", sel(2, 10), sel(2)))
    #expect(edit("github", "", "gihub", sel(2), sel(2)))
    #expect(edit("github", "", "gihub", sel(3), sel(2)))
    #expect(edit("github", "", "ghub", sel(1, 3), sel(1)))
    #expect(edit("gi", "", "g", sel(1), sel(1)))
    #expect(!edit("gi", "thub.com", "git", sel(2, 10), sel(3)))
    #expect(!edit("gi", "", "git", sel(2), sel(3)))
    #expect(!edit("", "", "g", sel(0), sel(1)))
    #expect(edit("", "", "git", sel(0), sel(3)))
    #expect(edit("gi", "thub.com", "gitlab", sel(2, 10), sel(6)))
    #expect(edit("github", "", "gixyzthub", sel(2), sel(5)))
    #expect(!edit("gi", "", "g😀", sel(1, 2), sel(3)))
    #expect(!edit("gi", "", "git", sel(0), sel(3)))
    #expect(edit("", "", "github", sel(9), sel(6)))
    #expect(edit("github.com", "", "github.co", sel(10), sel(9)))
  }

  @Test func pastingMoreThanACharacterBlocksTheCompletion() {
    #expect(sup("", "", "github"))
    #expect(sup("gi", "", "gitlab"))
    #expect(!sup("gi", "thub.com", "git"))
    #expect(!sup("", "", "g"))
  }

  @Test func theCaretReachingTheEndAcceptsTheCompletion() {
    #expect(InlineRules.acceptsCompletion(typed: "git", shown: "hub.com", selection: sel(10)))
    #expect(!InlineRules.acceptsCompletion(typed: "git", shown: "hub.com", selection: sel(3, 10)))
    #expect(!InlineRules.acceptsCompletion(typed: "git", shown: "hub.com", selection: sel(3)))
    #expect(!InlineRules.acceptsCompletion(typed: "git", shown: "", selection: sel(3)))
  }
}

@MainActor
final class FakeHeroField: HeroFieldControl {
  var value = ""
  var selection = TextSelection.caret(0)
  var focused = 0
  func show(value: String, selection: TextSelection) {
    self.value = value
    self.selection = selection
  }
  func focusField() { focused += 1 }
  func releaseFocus() {}
  var hasFocus: Bool { false }
  var fieldSelection: TextSelection { selection }
  var fieldValue: String { value }
}

@MainActor
struct HeroBarModelTests {
  final class Log {
    var opened: [(String, Disposition)] = []
    var switched: [(String, String, Disposition)] = []
    var actions: [String] = []
    var removed: [String] = []
    var copied: [String] = []
    var journeys: [HeroJourney] = []
  }

  func make(_ tabId: String = UUID().uuidString) -> (HeroBarModel, FakeHeroField, Log) {
    let sources = NewTabSources()
    sources.setHistory([HistoryRow(url: "https://github.com/", title: "GitHub", favicon: nil, visits: 20, lastVisit: Date().timeIntervalSince1970 * 1000)], profileId: "p")
    sources.setTabs([TabRow(id: "t2", url: "https://news.ycombinator.com/", title: "Hacker News", favicon: nil)], profileId: "p")
    let model = HeroBarModel(windowId: "w", tabId: tabId, profileId: "p", incognito: false, settings: { Settings(values: [:]) }, sources: sources)
    let field = FakeHeroField()
    model.field = field
    let log = Log()
    var e = HeroBarEvents()
    e.open = { log.opened.append(($0, $1)) }
    e.switchTo = { log.switched.append(($0, $1, $2)) }
    e.runAction = { log.actions.append($0) }
    e.removeHistory = { log.removed.append($0) }
    e.copy = { log.copied.append($0) }
    e.journey = { log.journeys.append($0) }
    model.events = e
    return (model, field, log)
  }

  func type(_ model: HeroBarModel, _ field: FakeHeroField, _ text: String) {
    for i in 1...text.count {
      let next = String(text.prefix(i))
      let before = field.selection
      field.value = next
      field.selection = .caret(next.utf16.count)
      model.textChanged(next, edit: EditContext(before: before, after: field.selection))
    }
  }

  @Test func queryProbeRejectsSupersededAndResetCommits() {
    let (model, _, _) = make()
    var commits: [@MainActor () -> Void] = []
    var journeys: [(HeroJourney, String, String)] = []
    model.events.queryCommit = { commits.append($0) }
    model.events.queryJourney = { mark, _, query, generation, _ in journeys.append((mark, query, generation)) }
    model.driverType("g")
    model.driverType("gi")
    let keys = journeys.filter { $0.0 == .keystroke }
    #expect(keys.map { $0.1 } == ["g", "gi"])
    #expect(keys[0].2 != keys[1].2)
    #expect(journeys.contains { $0.0 == .queryInvalidated && $0.2 == keys[0].2 })
    commits[0]()
    #expect(!journeys.contains { $0.0 == .suggestions })
    commits[1]()
    #expect(journeys.last?.0 == .suggestions)
    #expect(journeys.last?.1 == "gi")
    #expect(journeys.last?.2 == keys[1].2)
    model.driverType("git")
    model.reset()
    let count = journeys.count
    commits[2]()
    #expect(journeys.count == count)
  }

  @Test func queryProbeRejectsBlurAndDetachedModels() {
    var commits: [@MainActor () -> Void] = []
    var completed = 0
    var first: HeroBarModel? = make().0
    first!.events.queryCommit = { commits.append($0) }
    first!.events.queryJourney = { mark, _, _, _, _ in if mark == .suggestions { completed += 1 } }
    first!.driverType("g")
    first!.didBlur(session: first!.editingSession)
    commits[0]()
    #expect(completed == 0)
    first!.driverType("g")
    first = nil
    commits[1]()
    #expect(completed == 0)
  }

  @Test func queryProbeHasNoUnprobedCommitWork() {
    let (model, _, _) = make()
    var scheduled = 0
    model.events.queryCommit = { _ in scheduled += 1 }
    model.driverType("g")
    #expect(scheduled == 0)
  }

  @Test func typingCompletesInlineAndSelectsTheCompletion() {
    let (model, field, log) = make()
    type(model, field, "git")
    #expect(model.typed == "git")
    #expect(model.shown == "hub.com")
    #expect(field.value == "github.com")
    #expect(field.selection == TextSelection(start: 3, end: 10))
    #expect(log.journeys.contains(.keystroke) && log.journeys.contains(.suggestions))
    #expect(model.goEnabled)
  }

  @Test func escapeDropsTheCompletionThenClears() {
    let (model, field, _) = make()
    type(model, field, "git")
    model.key(HeroKey(.escape))
    #expect(model.shown.isEmpty)
    #expect(field.value == "git")
    model.key(HeroKey(.escape))
    #expect(model.typed.isEmpty)
    #expect(field.value.isEmpty)
    #expect(!model.goEnabled)
  }

  @Test func enterOpensTheTopRowInTheCurrentTab() {
    let (model, field, log) = make()
    type(model, field, "git")
    model.key(HeroKey(.enter))
    #expect(log.opened.first?.0 == "https://github.com/")
    #expect(log.opened.first?.1 == .current)
    #expect(log.journeys.last == .navigate)
    #expect(model.typed == "git")
  }

  @Test func commandEnterOpensANewTabAndResets() {
    let (model, field, log) = make()
    type(model, field, "git")
    model.key(HeroKey(.enter, meta: true))
    #expect(log.opened.first?.1 == .newTab)
    #expect(model.typed.isEmpty)
  }

  @Test func controlEnterWrapsAWordInWwwDotCom() {
    let (model, field, log) = make()
    type(model, field, "apple")
    model.key(HeroKey(.enter, ctrl: true))
    #expect(log.opened.first?.0 == "https://www.apple.com")
  }

  @Test func plainTextSearchesWithTheDefaultEngine() {
    let (model, field, log) = make()
    type(model, field, "how tall is everest")
    model.submit()
    let url = log.opened.first?.0 ?? ""
    #expect(url.contains("everest"))
  }

  @Test func anOpenTabSwitchesInsteadOfNavigating() {
    let (model, field, log) = make()
    type(model, field, "hacker")
    guard let index = model.items.firstIndex(where: { if case .page(_, _, _, let tabId, _, _) = $0 { return tabId == "t2" } else { return false } }) else {
      Issue.record("no switch-to-tab row in \(model.items)")
      return
    }
    for _ in 0..<index { model.key(HeroKey(.arrowDown)) }
    model.submit()
    #expect(log.switched.first?.0 == "t2")
    #expect(model.typed.isEmpty)
  }

  @Test func arrowsWrapAround() {
    let (model, field, _) = make()
    type(model, field, "git")
    let n = model.items.count
    #expect(n > 1)
    model.key(HeroKey(.arrowUp))
    #expect(model.selectedIndex == n - 1)
    model.key(HeroKey(.arrowDown))
    #expect(model.selectedIndex == 0)
  }

  @Test func calcCopiesTheResultInPlace() {
    let (model, field, log) = make()
    type(model, field, "12*12")
    guard let row = model.items.firstIndex(where: { if case .calc = $0 { true } else { false } }) else {
      Issue.record("no calculation row: \(model.items)")
      return
    }
    for _ in 0..<row { model.key(HeroKey(.arrowDown)) }
    model.submit()
    #expect(log.copied == ["144"])
    #expect(model.typed == "144")
    #expect(field.selection == TextSelection(start: 0, end: 3))
  }

  @Test func theQueryOutlivesTheView() {
    let tab = UUID().uuidString
    let (model, field, _) = make(tab)
    type(model, field, "hello")
    model.save()
    let (again, _, _) = make(tab)
    #expect(again.typed == "hello")
    again.reset()
    again.save()
    let (third, _, _) = make(tab)
    #expect(third.typed.isEmpty)
  }

  @Test func theGoPillNamesTheEngine() {
    let (model, field, _) = make()
    type(model, field, "weather tomorrow")
    #expect(model.goLabel != "Go")
    #expect(model.placeholder == "Search or enter address")
    model.incognito = true
    #expect(model.placeholder == "Search privately or enter address")
  }
}

struct NewTabThemeTests {
  @Test func everyGeneratedTokenParses() {
    for table in [NewTabThemeTokens.dark, NewTabThemeTokens.light] {
      for key in NewTabThemeTokens.keys {
        #expect(table[key].flatMap { CSSColor($0) } != nil, "\(key): \(table[key] ?? "missing")")
      }
    }
  }

  @Test func tokensFromJSWinOverTheDefaults() {
    let fallback = NewTabTheme(dark: true, tokens: [:])
    #expect(fallback.ntpBarSolid == CSSColor(NewTabThemeTokens.dark["ntpBarSolid"]!))
    let themed = NewTabTheme(dark: true, tokens: ["ntpBarSolid": "#112233", "goButton": "not a color"])
    #expect(themed.ntpBarSolid == CSSColor("#112233"))
    #expect(themed.goButton == fallback.goButton)
  }
}

@MainActor
final class NewTabHistoryClient: EngineClient {
  var rows: [String: [EngineHistoryRow]] = [:]
  var handler: (@MainActor @Sendable (HistoryChange) -> Void)?
  var bookmarkTrees: [String: EngineBookmarkTree] = [:]
  var bookmarkHandler: (@MainActor @Sendable (String) -> Void)?

  func observeBookmarks(_ handler: @escaping @MainActor @Sendable (String) -> Void) { bookmarkHandler = handler }
  func watchBookmarks(engineProfile: String) async throws {}
  func readBookmarks(engineProfile: String) async throws -> EngineBookmarkTree {
    guard let tree = bookmarkTrees[engineProfile] else { throw BookmarkReadUnavailable.unsupported }
    return tree
  }
  func emitBookmark(_ profile: String) { bookmarkHandler?(profile) }

  func observeHistory(_ handler: @escaping @MainActor @Sendable (HistoryChange) -> Void) { self.handler = handler }
  func watchHistory(engineProfile: String) async throws {}
  func queryHistory(engineProfile: String, maxUrls: Int, maxVisits: Int) async throws -> [EngineHistoryRow] { rows[engineProfile] ?? [] }
  func emit(_ change: HistoryChange) { handler?(change) }
}

@MainActor
struct NewTabCatalogTests {
  @Test func benchSnapshotDescribesOnlyPublishedSources() {
    let sources = NewTabSources()
    #expect(sources.omniboxBenchSnapshot(profileId: "default")["sourceMode"] as? String == "unpublished")
    sources.setEngineProfile("", profileId: "default")
    sources.setTabs([TabRow(id: "t", url: "https://example.com", title: "Example", favicon: nil)], profileId: "default")
    sources.setHistory([HistoryRow(url: "https://example.com", title: "Example", favicon: nil, visits: 1, lastVisit: 10)], profileId: "default")
    sources.setBookmarks([BookmarkRow(url: "https://example.com", title: "Example", favicon: nil)], profileId: "default")
    let snapshot = sources.omniboxBenchSnapshot(profileId: "default")
    #expect(snapshot["sourceMode"] as? String == "js-feed")
    #expect(snapshot["engineProfile"] as? String == "")
    #expect(snapshot["tabs"] as? Int == 1)
    #expect(snapshot["history"] as? Int == 1)
    #expect(snapshot["bookmarks"] as? Int == 1)
  }

  @Test func profilesUseTheirEngineSnapshotsAndWaitForReadiness() async throws {
    let client = NewTabHistoryClient()
    client.rows[""] = [.init(url: "https://personal.example/", title: "Personal", visits: 3, visitTimes: [10, 20])]
    client.rows["shared"] = [.init(url: "https://shared.example/", title: "Shared", visits: 5, visitTimes: [30])]
    let catalog = LibraryCatalog(client: client, bookmarkSelection: { false })
    let sources = NewTabSources()
    sources.useHistoryCatalog(catalog)
    sources.setEngineProfile("", profileId: "default")
    sources.setEngineProfile("shared", profileId: "work")
    sources.setEngineProfile("shared", profileId: "copy")
    #expect(sources.history("default").isEmpty)
    #expect(sources.history("work").isEmpty)
    await catalog.start(engineProfiles: ["", "shared"])
    for _ in 0..<100 where sources.history("copy").isEmpty { try await Task.sleep(for: .milliseconds(1)) }
    #expect(sources.history("default").map(\.url) == ["https://personal.example/"])
    #expect(sources.history("work").map(\.url) == ["https://shared.example/"])
    #expect(sources.history("copy").map(\.url) == ["https://shared.example/"])
    #expect(sources.history("work").first?.visits == 5)
    #expect(sources.history("work").first?.lastVisit == 30)
    #expect(sources.history("work").first?.favicon == nil)
    #expect(sources.knownHosts("work").contains("shared.example"))
    #expect(sources.suggestNow(SuggestRequest(profileId: "work", typed: "shared", tabs: [], options: SuggestOptions())).items.contains { if case .page(let url, _, _, _, _, _) = $0 { return url == "https://shared.example/" }; return false })
  }

  @Test func bookmarkRowsFollowCatalogAndOriginalProfileMapping() async throws {
    let client = NewTabHistoryClient()
    func tree(_ title: String) -> EngineBookmarkTree {
      let link = EngineBookmarkNode(id: "a", kind: "u", title: title, url: "https://a.example/")
      return EngineBookmarkTree(bar: EngineBookmarkNode(id: "bar", kind: "f", title: "Bar", children: [link]),
        other: EngineBookmarkNode(id: "other", kind: "f", title: "Other", children: []))
    }
    client.bookmarkTrees["shared"] = tree("First")
    let catalog = LibraryCatalog(client: client, bookmarkSelection: { false })
    let sources = NewTabSources()
    sources.useBookmarkCatalog(catalog)
    sources.setBookmarkIcons(["https://a.example/": "data:image/png;base64,a"], engineProfile: "shared", profileId: "private")
    sources.setEngineProfile("incognito:w@shared", bookmarkEngineProfile: "shared", profileId: "private")
    sources.setEngineProfile("shared", profileId: "regular")
    #expect(sources.bookmarks("private").isEmpty)
    await catalog.start(engineProfiles: ["shared"])
    for _ in 0..<100 where sources.bookmarks("private").isEmpty { try await Task.sleep(for: .milliseconds(1)) }
    #expect(sources.bookmarks("private").map(\.title) == ["First"])
    #expect(sources.bookmarks("regular").map(\.url) == ["https://a.example/"])
    #expect(sources.bookmarks("private").first?.favicon == "data:image/png;base64,a")
    client.bookmarkTrees["shared"] = tree("Updated")
    client.emitBookmark("shared")
    for _ in 0..<100 where sources.bookmarks("private").first?.title != "Updated" { try await Task.sleep(for: .milliseconds(1)) }
    #expect(sources.bookmarks("regular").first?.title == "Updated")
    client.bookmarkTrees["other"] = tree("Other")
    sources.setBookmarkIcons(["https://a.example/": "data:image/png;base64,b"], engineProfile: "other", profileId: "private")
    sources.setEngineProfile("incognito:w@other", bookmarkEngineProfile: "other", profileId: "private")
    await catalog.start(engineProfiles: ["other"])
    for _ in 0..<100 where sources.bookmarks("private").first?.title != "Other" { try await Task.sleep(for: .milliseconds(1)) }
    #expect(sources.bookmarks("private").first?.favicon == "data:image/png;base64,b")
  }

  @Test func deletionUpdatesEverySharedViewAndChangingMappingDropsOldRows() async throws {
    let client = NewTabHistoryClient()
    client.rows["shared"] = [.init(url: "https://shared.example/", title: "Shared", visits: 2, visitTimes: [10])]
    let catalog = LibraryCatalog(client: client, bookmarkSelection: { false })
    await catalog.start(engineProfiles: ["shared", "other"])
    let sources = NewTabSources()
    sources.useHistoryCatalog(catalog)
    sources.setEngineProfile("shared", profileId: "one")
    sources.setEngineProfile("shared", profileId: "two")
    #expect(sources.history("one").count == 1)
    client.emit(.deleted(profile: "shared", all: false, urls: ["https://shared.example/"]))
    await catalog.flushPending()
    for _ in 0..<100 where !sources.history("two").isEmpty { try await Task.sleep(for: .milliseconds(1)) }
    #expect(sources.history("one").isEmpty)
    #expect(sources.history("two").isEmpty)
    sources.setEngineProfile("other", profileId: "one")
    #expect(sources.history("one").isEmpty)
  }
}

@MainActor
struct OmniboxPanelModelTests {
  func make(_ variant: BarVariant, opensTab: Bool = false, initialText: String = "", currentUrl: String = "") -> (HeroBarModel, FakeHeroField, [String]) {
    let sources = NewTabSources()
    let now = Date().timeIntervalSince1970 * 1000
    sources.setHistory(
      (0..<6).map { HistoryRow(url: "https://site\($0).example/", title: "Site \($0)", favicon: nil, visits: 2, lastVisit: now - Double($0) * 1000) },
      profileId: "p")
    sources.setTabs([TabRow(id: "t1", url: currentUrl, title: "Current", favicon: nil)], profileId: "p")
    let model = HeroBarModel(
      windowId: "w", tabId: "t1", profileId: "p", incognito: false, settings: { Settings(values: [:]) }, sources: sources, variant: variant,
      opensTab: opensTab, initialText: initialText, currentUrl: currentUrl)
    let field = FakeHeroField()
    model.field = field
    return (model, field, [])
  }

  func drainBlurCallbacks() async {
    await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
      DispatchQueue.main.async { continuation.resume() }
    }
  }

  @Test(arguments: [BarVariant.panel, .sidebar])
  func staleBlurDoesNotCancelCurrentSession(_ variant: BarVariant) {
    let (model, _, _) = make(variant)
    var cancelled: [UUID] = []
    model.events.cancel = { cancelled.append($0) }
    model.didFocus()
    let endedSession = model.editingSession
    model.didFocus()
    let currentSession = model.editingSession
    #expect(endedSession != currentSession)
    model.didBlur(session: endedSession)
    #expect(cancelled.isEmpty)
    #expect(model.editing)
    model.didBlur(session: currentSession)
    #expect(cancelled == [currentSession])
    #expect(!model.editing)
  }

  @Test func deferredBlurKeepsEndedSession() async {
    let (model, _, _) = make(.panel)
    let coordinator = HeroFieldCoordinator(model: model)
    var cancelled: [UUID] = []
    model.events.cancel = { cancelled.append($0) }
    model.didFocus()
    coordinator.controlTextDidEndEditing(Notification(name: NSControl.textDidEndEditingNotification))
    model.didFocus()
    let currentSession = model.editingSession
    await drainBlurCallbacks()
    #expect(cancelled.isEmpty)
    #expect(model.editing)
    coordinator.controlTextDidEndEditing(Notification(name: NSControl.textDidEndEditingNotification))
    await drainBlurCallbacks()
    #expect(cancelled == [currentSession])
    #expect(!model.editing)
    #expect(coordinator.model === model)
  }

  @Test func deferredBlurAfterReboundEndsOnlyTheOldModel() async {
    let (endedModel, _, _) = make(.panel)
    let (currentModel, _, _) = make(.sidebar)
    let coordinator = HeroFieldCoordinator(model: endedModel)
    var cancelled: [UUID] = []
    endedModel.events.cancel = { cancelled.append($0) }
    currentModel.events.cancel = { cancelled.append($0) }
    endedModel.didFocus()
    let endedSession = endedModel.editingSession
    coordinator.controlTextDidEndEditing(Notification(name: NSControl.textDidEndEditingNotification))
    coordinator.model = currentModel
    currentModel.didFocus()
    let currentSession = currentModel.editingSession
    #expect(endedSession != currentSession)
    await drainBlurCallbacks()
    #expect(cancelled == [endedSession])
    #expect(!endedModel.editing)
    #expect(currentModel.editing)
    #expect(coordinator.model === currentModel)
    currentModel.didBlur(session: currentSession)
    #expect(cancelled == [endedSession, currentSession])
    #expect(!currentModel.editing)
  }

  @Test func escapeClosesThePanelAndLeavesAScopeFirst() {
    let (model, _, _) = make(.panel)
    var done: [BarDismissal?] = []
    var e = HeroBarEvents()
    e.done = { done.append($0) }
    model.events = e
    model.textChanged("youtube.com", edit: nil)
    model.textChanged("youtube.com ", edit: nil)
    #expect(model.scope != nil)
    model.key(HeroKey(.escape))
    #expect(model.scope == nil && done.isEmpty)
    model.key(HeroKey(.escape))
    #expect(done == [.escape])
  }

  @Test func openingElsewhereOrRunningAnActionClosesThePanel() {
    let (model, _, _) = make(.panel)
    var done = 0
    var opened: [Disposition] = []
    var e = HeroBarEvents()
    e.done = { _ in done += 1 }
    e.open = { opened.append($1) }
    model.events = e
    model.textChanged("site1", edit: nil)
    model.key(HeroKey(.enter, meta: true))
    #expect(opened == [.newTab] && done == 1)
    model.textChanged("site1", edit: nil)
    model.key(HeroKey(.enter))
    #expect(opened == [.newTab, .current] && done == 1)
  }

  @Test func theDropdownStartsWithTheCurrentPageAndFourRecent() {
    let (model, _, _) = make(.sidebar, currentUrl: "https://site2.example/")
    let urls = model.items.map { if case .page(let url, _, _, _, _, _) = $0 { url } else { "" } }
    #expect(urls == ["https://site2.example/", "https://site0.example/", "https://site1.example/", "https://site3.example/", "https://site4.example/"])
    model.textChanged("site5", edit: nil)
    #expect(model.items.contains { if case .page(let url, _, _, _, _, _) = $0 { url == "https://site5.example/" } else { false } })
    #expect(model.items.count != 5 || !model.items.allSatisfy { if case .page(_, _, _, _, _, let visited) = $0 { visited } else { false } })
  }

  @Test func theNewTabBarStartsWithNoRowSelected() {
    let (model, _, _) = make(.panel, opensTab: true)
    var state = BrowserState()
    state.tabs["t9"] = Tab(id: "t9", windowId: "w", profileId: "p", url: "https://a.example/", now: 1)
    model.sources.applyWorkspace(OmniboxWorkspaceSources(state))
    #expect(model.items.count == 1)
    #expect(model.selectedIndex == -1)
    model.key(HeroKey(.arrowDown))
    #expect(model.selectedIndex == 0)
    model.textChanged("x", edit: nil)
    model.textChanged("", edit: nil)
    #expect(model.selectedIndex == -1)
  }

  @Test func idleRowsFollowWorkspaceAndActiveTabChanges() {
    let sources = NewTabSources()
    var state = BrowserState()
    var window = BrowserWindow(id: "w", profileId: "p", incognito: false, frame: nil, createdAt: 0)
    window.activeTabIds["p"] = "active"
    state.windows["w"] = window
    state.tabs["active"] = Tab(id: "active", windowId: "w", profileId: "p", url: "https://active.example/", now: 30)
    state.tabs["old"] = Tab(id: "old", windowId: "w", profileId: "p", url: "https://old.example/", now: 20)
    state.tabs["recent"] = Tab(id: "recent", windowId: "w", profileId: "p", url: "https://recent.example/", now: 10)
    sources.applyWorkspace(OmniboxWorkspaceSources(state))
    let model = HeroBarModel(windowId: "w", tabId: "old", profileId: "p", incognito: false,
      settings: { Settings(values: [:]) }, sources: sources, variant: .panel, opensTab: true)
    #expect(model.items.map { if case .page(_, _, _, let id, _, _) = $0 { id ?? "" } else { "" } } == ["old", "recent"])
    #expect(model.current == nil && model.selectedIndex == -1)
    state.windows["w"]?.activeTabIds["p"] = "old"
    state.tabs["recent"]?.lastActiveAt = 40
    sources.applyWorkspace(OmniboxWorkspaceSources(state))
    model.sourcesChanged()
    #expect(model.items.map { if case .page(_, _, _, let id, _, _) = $0 { id ?? "" } else { "" } } == ["recent", "active"])
    #expect(model.selectedIndex == -1)
    model.textChanged("query with spaces", edit: nil)
    #expect(model.items.allSatisfy { if case .page(_, _, _, let id, _, _) = $0 { id != "recent" } else { true } })
    model.textChanged("", edit: nil)
    #expect(model.items.map { if case .page(_, _, _, let id, _, _) = $0 { id ?? "" } else { "" } } == ["recent", "active"])
    sources.resetWorkspace()
    model.sourcesChanged()
    #expect(model.items.isEmpty)
  }

  @Test func idleWorkspaceChangesInvalidateObservedRows() {
    let sources = NewTabSources()
    var state = BrowserState()
    state.tabs["recent"] = Tab(id: "recent", windowId: "w", profileId: "p", url: "https://recent.example/", now: 10)
    sources.applyWorkspace(OmniboxWorkspaceSources(state))
    let model = HeroBarModel(windowId: "w", tabId: "current", profileId: "p", incognito: false,
      settings: { Settings(values: [:]) }, sources: sources, variant: .panel, opensTab: true)
    nonisolated(unsafe) var invalidated = false
    withObservationTracking {
      _ = model.items
    } onChange: {
      invalidated = true
    }
    state.tabs["recent"]!.customTitle = "Changed"
    sources.applyWorkspace(OmniboxWorkspaceSources(state))
    model.sourcesChanged()
    #expect(invalidated)
  }

  @Test func sidebarRecentsCollapseHashesAndKeepTheCurrentPage() {
    let (model, _, _) = make(.sidebar, currentUrl: "https://site2.example/#current")
    model.sources.setHistory([
      HistoryRow(url: "https://site2.example/#other", title: "Same page", favicon: nil, visits: 1, lastVisit: 100),
      HistoryRow(url: "https://recent.example/#first", title: "First", favicon: nil, visits: 1, lastVisit: 90),
      HistoryRow(url: "https://recent.example/#second", title: "Second", favicon: nil, visits: 1, lastVisit: 80),
    ] + (0..<5).map { HistoryRow(url: "https://extra\($0).example/", title: "Extra", favicon: nil, visits: 1, lastVisit: Double(70 - $0)) }, profileId: "p")
    #expect(model.items.map { if case .page(let url, _, _, _, _, _) = $0 { url } else { "" } } == [
      "https://site2.example/#current", "https://recent.example/#first", "https://extra0.example/", "https://extra1.example/", "https://extra2.example/",
    ])
  }

  @Test func thePanelOpensWithItsTextSelected() {
    let (model, _, _) = make(.panel, initialText: "https://site0.example/", currentUrl: "https://site0.example/")
    #expect(model.typed == "https://site0.example/")
    #expect(model.selection == TextSelection(start: 0, end: 22))
    #expect(model.items.isEmpty)
    #expect(model.goEnabled)
  }
}
