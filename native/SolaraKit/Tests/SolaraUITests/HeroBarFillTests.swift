import Foundation
import Testing

@testable import SolaraModel
@testable import SolaraOmnibox
@testable import SolaraUI

@MainActor
struct HeroBarFillTests {
  final class Log {
    var opened: [(String, Disposition)] = []
    var switched: [(String, String, Disposition)] = []
    var done: [BarDismissal?] = []
  }

  func make(variant: BarVariant = .hero, opensTab: Bool = false, initialText: String = "") -> (HeroBarModel, FakeHeroField, Log) {
    let sources = NewTabSources()
    let now = Date().timeIntervalSince1970 * 1000
    sources.setHistory([
      HistoryRow(url: "https://github.com/", title: "GitHub", favicon: nil, visits: 20, lastVisit: now),
      HistoryRow(url: "https://github.com/andrewbenson/solara", title: "andrewbenson/solara: Solara brings sidebar tabs", favicon: nil, visits: 20, lastVisit: now - 500),
      HistoryRow(url: "https://github.com/andrewbenson/solara/releases/tag/v0.1.0", title: "Release Solara 0.1.0", favicon: nil, visits: 3, lastVisit: now - 1000),
      HistoryRow(url: "https://gitlab.com/explore", title: "GitLab Explore", favicon: nil, visits: 2, lastVisit: now - 2000),
    ], profileId: "p")
    sources.setTabs([TabRow(id: "t2", url: "https://news.ycombinator.com/", title: "Hacker News", favicon: nil)], profileId: "p")
    sources.setIdleTabs(OmniboxIdleTabSources(tabs: [Tab(id: "t2", windowId: "w", profileId: "p", url: "https://news.ycombinator.com/", now: 10)], peeks: [:], shared: true))
    let model = HeroBarModel(
      windowId: "w", tabId: UUID().uuidString, profileId: "p", incognito: false, settings: { Settings(values: [:]) }, sources: sources,
      variant: variant, opensTab: opensTab, initialText: initialText)
    let field = FakeHeroField()
    model.field = field
    let log = Log()
    var e = HeroBarEvents()
    e.open = { log.opened.append(($0, $1)) }
    e.switchTo = { log.switched.append(($0, $1, $2)) }
    e.done = { log.done.append($0) }
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

  func edit(_ model: HeroBarModel, _ field: FakeHeroField, to next: String) {
    let before = field.selection
    field.value = next
    field.selection = .caret(next.utf16.count)
    model.textChanged(next, edit: EditContext(before: before, after: field.selection))
  }

  func expectedFill(_ model: HeroBarModel) -> String? { model.current.flatMap { OmniboxFill.text(for: $0) } }

  @Test func arrowingPutsTheHighlightedRowInTheInput() {
    let (model, field, _) = make()
    type(model, field, "git")
    let typedValue = model.value
    let items = model.items
    #expect(items.count > 2)
    model.key(HeroKey(.arrowDown))
    #expect(model.selectedIndex == 1)
    let first = OmniboxFill.text(for: items[1])
    #expect(first != nil)
    #expect(field.value == first)
    #expect(model.value == first)
    #expect(field.selection == .caret(first!.utf16.count))
    model.key(HeroKey(.arrowDown))
    let second = OmniboxFill.text(for: items[2]) ?? typedValue
    #expect(field.value == second)
    #expect(model.typed == "git")
    #expect(model.items == items)
  }

  @Test func aSearchRowFillsItsQueryAndAPageItsAddress() {
    let (model, field, _) = make()
    type(model, field, "solara")
    let search = model.items.firstIndex { if case .search = $0 { return true } else { return false } }
    let release = model.items.firstIndex { if case .page(let url, _, _, _, _, _) = $0 { return url.contains("releases/tag") } else { return false } }
    #expect(search != nil && release != nil)
    for _ in 0..<search! { model.key(HeroKey(.arrowDown)) }
    if search! > 0 { #expect(field.value == "solara") }
    model.key(HeroKey(.pageUp))
    for _ in 0..<release! { model.key(HeroKey(.arrowDown)) }
    #expect(release! == 0 || field.value == "github.com/andrewbenson/solara/releases/tag/v0.1.0")
  }

  @Test func arrowingBackToTheFirstRowRestoresWhatWasTypedWithItsCompletion() {
    let (model, field, _) = make()
    type(model, field, "git")
    let typedValue = model.value
    let typedSelection = field.selection
    #expect(model.shown == "hub.com")
    model.key(HeroKey(.arrowDown))
    #expect(field.value != typedValue)
    model.key(HeroKey(.arrowUp))
    #expect(model.selectedIndex == 0)
    #expect(field.value == typedValue)
    #expect(model.value == typedValue)
    #expect(field.selection == typedSelection)
    #expect(model.typed == "git")
  }

  @Test func theFirstEscapeRestoresAndTheSecondClosesThePanel() {
    let (model, field, log) = make(variant: .panel, initialText: "https://example.com/")
    type(model, field, "git")
    let typedValue = model.value
    model.key(HeroKey(.arrowDown))
    model.key(HeroKey(.arrowDown))
    #expect(field.value != typedValue)
    model.key(HeroKey(.escape))
    #expect(log.done.isEmpty)
    #expect(field.value == typedValue)
    #expect(model.selectedIndex == 0)
    model.key(HeroKey(.escape))
    #expect(log.done.count == 1)
  }

  @Test func theFirstEscapeRestoresInTheNewTabBarToo() {
    let (model, field, _) = make()
    type(model, field, "git")
    let typedValue = model.value
    model.key(HeroKey(.arrowDown))
    model.key(HeroKey(.escape))
    #expect(field.value == typedValue)
    #expect(model.typed == "git")
    #expect(model.shown == "hub.com")
  }

  @Test func enterOpensTheFilledRow() {
    let (model, field, log) = make()
    type(model, field, "solara")
    guard let release = model.items.firstIndex(where: { if case .page(let url, _, _, _, _, _) = $0 { return url.contains("releases/tag") } else { return false } }),
      release > 0
    else { return #expect(Bool(false), "the release page should be a lower row") }
    for _ in 0..<release { model.key(HeroKey(.arrowDown)) }
    model.key(HeroKey(.enter))
    #expect(log.opened.map(\.0) == ["https://github.com/andrewbenson/solara/releases/tag/v0.1.0"])
  }

  @Test func enterOnAFilledSearchRowSearchesItsQuery() {
    let (model, field, log) = make()
    type(model, field, "git")
    guard let search = model.items.firstIndex(where: { if case .search = $0 { return true } else { return false } }), search > 0,
      case .search(let query, let url, _, _, _) = model.items[search]
    else { return #expect(Bool(false), "a search row below the first") }
    for _ in 0..<search { model.key(HeroKey(.arrowDown)) }
    #expect(field.value == query)
    model.key(HeroKey(.enter))
    #expect(log.opened.map(\.0) == [url])
  }

  @Test func aFilledSwitchRowShowsTheTabsAddressAndEnterSwitches() {
    let (model, field, log) = make(opensTab: true)
    #expect(model.selectedIndex == -1)
    model.key(HeroKey(.arrowDown))
    guard case .page(_, _, _, let tabId?, _, _)? = model.current else { return #expect(Bool(false), "an open-tab row") }
    #expect(field.value == "news.ycombinator.com")
    model.key(HeroKey(.enter))
    #expect(log.switched.map(\.0) == [tabId])
    #expect(log.opened.isEmpty)
  }

  @Test func anEditedSwitchRowOpensTheEditedText() {
    let (model, field, log) = make(opensTab: true)
    model.key(HeroKey(.arrowDown))
    #expect(field.value == "news.ycombinator.com")
    edit(model, field, to: "news.ycombinator.com/newest")
    #expect(model.typed == "news.ycombinator.com/newest")
    model.key(HeroKey(.enter))
    #expect(log.switched.isEmpty)
    #expect(log.opened.map(\.0) == ["https://news.ycombinator.com/newest"])
  }

  @Test func editingTheFillMakesItTypedTextAndRefreshesTheRows() {
    let (model, field, _) = make()
    type(model, field, "solara")
    guard let release = model.items.firstIndex(where: { if case .page(let url, _, _, _, _, _) = $0 { return url.contains("releases/tag") } else { return false } }),
      release > 0
    else { return #expect(Bool(false), "the release page should be a lower row") }
    for _ in 0..<release { model.key(HeroKey(.arrowDown)) }
    edit(model, field, to: "github.com/andrewbenson/solara/")
    #expect(model.typed == "github.com/andrewbenson/solara/")
    #expect(model.selectedIndex == 0)
    #expect(field.value == "github.com/andrewbenson/solara/")
    guard case .page(let url, _, _, _, _, _)? = model.items.first else { return #expect(Bool(false), "the address first") }
    #expect(url.hasPrefix("https://github.com/andrewbenson/solara") && !url.contains("releases"))
    #expect(model.items.dropFirst().first.map { if case .search(let q, _, _, _, _) = $0 { return q } else { return "" } } == "github.com/andrewbenson/solara/")
    model.key(HeroKey(.arrowUp))
    model.key(HeroKey(.arrowDown))
    #expect(model.typed == "github.com/andrewbenson/solara/")
  }

  @Test func deletingFromTheFillDoesNotCompleteItAgain() {
    let (model, field, _) = make()
    type(model, field, "g")
    guard let lab = model.items.firstIndex(where: { if case .page(let url, _, _, _, _, _) = $0 { return url.contains("gitlab") } else { return false } }),
      lab > 0
    else { return #expect(Bool(false), "gitlab below the first row") }
    for _ in 0..<lab { model.key(HeroKey(.arrowDown)) }
    #expect(field.value == "gitlab.com/explore")
    let before = field.selection
    field.value = "gitlab.com/explor"
    field.selection = .caret(17)
    model.textChanged("gitlab.com/explor", edit: EditContext(before: before, after: field.selection))
    #expect(model.typed == "gitlab.com/explor")
    #expect(model.shown == "")
  }

  @Test func theCaretSettlingAtTheEndOfAFillDoesNotChangeTheTypedText() {
    let (model, field, _) = make()
    type(model, field, "git")
    model.key(HeroKey(.arrowDown))
    let filled = field.value
    model.selectionChanged(.caret(filled.utf16.count))
    #expect(model.typed == "git")
    #expect(model.value == filled)
  }

  @Test func newRowsArrivingKeepTheFillUntilTheRowIsGone() {
    let (model, field, _) = make()
    type(model, field, "git")
    model.key(HeroKey(.arrowDown))
    let filled = field.value
    model.sourcesChanged()
    #expect(field.value == filled)
  }
}
