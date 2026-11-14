import Foundation
import Testing

@testable import SolaraModel
@testable import SolaraOmnibox
@testable import SolaraUI

@MainActor
struct HeroBarAsyncTests {
  final class Log {
    var opened: [(String, Disposition)] = []
  }

  func make() -> (HeroBarModel, FakeHeroField, NewTabSources, Log) {
    let sources = NewTabSources()
    sources.asynchronous = true
    let now = Date().timeIntervalSince1970 * 1000
    sources.setHistory([
      HistoryRow(url: "https://github.com/", title: "GitHub", favicon: nil, visits: 20, lastVisit: now),
      HistoryRow(url: "https://github.com/andrewbenson/solara", title: "Solara", favicon: nil, visits: 20, lastVisit: now - 500),
      HistoryRow(url: "https://gitlab.com/explore", title: "GitLab Explore", favicon: nil, visits: 2, lastVisit: now - 2000),
      HistoryRow(url: "https://news.ycombinator.com/", title: "Hacker News", favicon: nil, visits: 9, lastVisit: now - 100),
    ], profileId: "p")
    let model = HeroBarModel(
      windowId: "w", tabId: UUID().uuidString, profileId: "p", incognito: false, settings: { Settings(values: [:]) }, sources: sources)
    let field = FakeHeroField()
    model.field = field
    let log = Log()
    var e = HeroBarEvents()
    e.open = { log.opened.append(($0, $1)) }
    model.events = e
    return (model, field, sources, log)
  }

  enum CaretNotice: CaseIterable, Sendable {
    case none, beforeText, afterText
  }

  func edit(_ model: HeroBarModel, _ field: FakeHeroField, to next: String, caret notice: CaretNotice = .none) {
    let before = field.selection
    field.value = next
    field.selection = .caret(next.utf16.count)
    let after = field.selection
    if notice == .beforeText { model.selectionChanged(after) }
    model.textChanged(field.value, edit: EditContext(before: before, after: field.selection))
    if notice == .afterText { model.selectionChanged(field.selection) }
  }

  func type(_ model: HeroBarModel, _ field: FakeHeroField, _ text: String, from start: Int = 1) {
    for i in start...text.count { edit(model, field, to: String(text.prefix(i))) }
  }

  func waitSettled(_ model: HeroBarModel, _ sources: NewTabSources) async {
    for _ in 0..<200 where !model.settled {
      sources.worker.drain()
      await Task.yield()
      try? await Task.sleep(for: .milliseconds(5))
    }
  }

  func pages(_ model: HeroBarModel) -> [String] {
    model.items.compactMap { if case .page(let url, _, _, _, _, _) = $0 { return url }; return nil }
  }

  @Test func resultsArriveOffTheMainThreadAndApply() async {
    let (model, field, sources, _) = make()
    edit(model, field, to: "news")
    #expect(!model.settled)
    await waitSettled(model, sources)
    #expect(model.settled)
    #expect(pages(model).contains("https://news.ycombinator.com/"))
    #expect(model.value.hasPrefix("news"))
  }

  @Test func aStaleResultNeverReplacesANewerOne() async {
    let (model, field, sources, _) = make()
    edit(model, field, to: "gitl")
    edit(model, field, to: "news")
    await waitSettled(model, sources)
    #expect(pages(model).contains("https://news.ycombinator.com/"))
    #expect(!pages(model).contains("https://gitlab.com/explore"))
    let late = sources.suggestNow(SuggestRequest(profileId: "p", typed: "gitl", tabs: [], options: SuggestOptions()))
    model.delivered(late, generation: 1)
    #expect(pages(model).contains("https://news.ycombinator.com/"))
    #expect(!pages(model).contains("https://gitlab.com/explore"))
  }

  @Test func everyGenerationButTheLastIsDroppedOrIgnored() async {
    let (model, field, sources, _) = make()
    for text in ["g", "gi", "git", "gith", "githu", "github"] { edit(model, field, to: text) }
    await waitSettled(model, sources)
    #expect(model.typed == "github")
    #expect(pages(model).first?.hasPrefix("https://github.com") == true)
  }

  @Test func enterBeforeTheResultUsesTheCurrentQuery() async {
    let (model, field, sources, log) = make()
    type(model, field, "news.yc")
    #expect(!model.settled)
    model.key(HeroKey(.enter))
    #expect(model.settled)
    #expect(log.opened.first?.0 == "https://news.ycombinator.com/")
    sources.worker.drain()
    await Task.yield()
    #expect(log.opened.count == 1)
  }

  @Test func theInlineCompletionCarriesOverWhileTypingIntoIt() async {
    let (model, field, sources, _) = make()
    type(model, field, "git")
    await waitSettled(model, sources)
    #expect(model.shown == "hub.com")
    edit(model, field, to: "gith")
    #expect(!model.settled)
    #expect(model.value == "github.com")
    edit(model, field, to: "githx")
    #expect(model.value == "githx")
    await waitSettled(model, sources)
    #expect(model.value == "githx")
  }

  @Test(arguments: [CaretNotice.beforeText, .afterText])
  func typingIntoACarriedCompletionNeverSettlesOnMain(_ notice: CaretNotice) async {
    let (model, field, sources, _) = make()
    type(model, field, "git")
    await waitSettled(model, sources)
    #expect(model.shown == "hub.com")
    edit(model, field, to: "gith", caret: notice)
    #expect(!model.settled)
    #expect(model.value == "github.com")
    edit(model, field, to: "githu", caret: notice)
    #expect(!model.settled)
    #expect(model.typed == "githu")
    await waitSettled(model, sources)
    #expect(model.value == "github.com")
  }

  @Test func aCaretNoticeBeforeTheTextKeepsTheTypedCharacter() async {
    let (model, field, sources, _) = make()
    type(model, field, "git")
    await waitSettled(model, sources)
    #expect(model.shown == "hub.com")
    let now = Date().timeIntervalSince1970 * 1000
    sources.setHistory([
      HistoryRow(url: "https://gitlab.com/explore", title: "GitLab Explore", favicon: nil, visits: 2, lastVisit: now - 2000),
    ], profileId: "p")
    #expect(sources.preparedIndex("p"))
    edit(model, field, to: "gith")
    #expect(!model.settled)
    #expect(model.value == "github.com")
    edit(model, field, to: "githu", caret: .beforeText)
    #expect(model.typed == "githu")
    await waitSettled(model, sources)
    #expect(model.value == "githu")
  }

  @Test(arguments: [CaretNotice.beforeText, .afterText])
  func movingTheCaretToTheEndStillAcceptsTheFreshCompletion(_ notice: CaretNotice) async {
    let (model, field, sources, _) = make()
    type(model, field, "git")
    await waitSettled(model, sources)
    edit(model, field, to: "gith", caret: notice)
    #expect(!model.settled)
    model.selectionChanged(.caret("github.com".utf16.count))
    #expect(model.typed == "github.com")
    #expect(model.shown == "")
  }
}
