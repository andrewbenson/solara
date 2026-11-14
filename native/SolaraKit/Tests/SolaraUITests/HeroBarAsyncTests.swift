import Foundation
import Observation
import Synchronization
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
    #expect(sources.preparedIndex("p"))
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

  func hold(_ sources: NewTabSources) -> DispatchSemaphore {
    let entered = DispatchSemaphore(value: 0)
    let release = DispatchSemaphore(value: 0)
    sources.worker.submit(SuggestRequest(profileId: "gate", typed: "gate", tabs: [], options: SuggestOptions()), for: UUID(), generation: 1) { _ in
      entered.signal()
      _ = release.wait(timeout: .now() + .seconds(2))
    }
    #expect(entered.wait(timeout: .now() + .seconds(1)) == .success)
    return release
  }

  @Test(arguments: [CaretNotice.beforeText, .afterText], ["x", "m"])
  func replacingTheLastCarriedCharacterKeepsWhatWasTyped(_ notice: CaretNotice, _ final: String) async {
    let (model, field, sources, _) = make()
    type(model, field, "github.c")
    await waitSettled(model, sources)
    #expect(model.shown == "om")
    let release = hold(sources)
    defer { release.signal() }
    edit(model, field, to: "github.co", caret: notice)
    #expect(model.shown == "m")
    edit(model, field, to: "github.co" + final, caret: notice)
    #expect(model.typed == "github.co" + final)
    #expect(field.value == "github.co" + final)
    #expect(model.shown.isEmpty)
  }

  @Test(arguments: [false, true])
  func enterWithAPreparedIndexWaitsForASlowWorker(_ rebuilding: Bool) async {
    let (model, field, sources, log) = make()
    #expect(sources.preparedIndex("p"))
    let release = hold(sources)
    defer { release.signal() }
    if rebuilding {
      sources.setHistory(sources.history("p") + OmniboxScaleRows.history(20000), profileId: "p")
    }
    #expect(sources.worker.hasPreparedIndex("p"))
    type(model, field, "gith")
    #expect(!model.settled)
    DispatchQueue.global().asyncAfter(deadline: .now() + .milliseconds(50)) { release.signal() }
    let start = ContinuousClock.now
    model.key(HeroKey(.enter))
    #expect(ContinuousClock.now - start >= .milliseconds(30))
    #expect(log.opened.first?.0 == "https://github.com/")
    #expect(model.settled)
    sources.worker.drain()
    await Task.yield()
    #expect(log.opened.count == 1)
  }

  @Test(arguments: ["first", "clear", "switch"], ["typed.com", "cold query", "gith"])
  func enterWithoutAPreparedIndexUsesTheTypedFallbackImmediately(_ change: String, _ text: String) {
    let sources = NewTabSources()
    sources.asynchronous = true
    if change != "first" {
      sources.setHistory([HistoryRow(url: "https://github.com/", title: "GitHub", favicon: nil, visits: 20, lastVisit: 1)], profileId: "p")
      #expect(sources.preparedIndex("p"))
    }
    let release = hold(sources)
    defer { release.signal() }
    sources.setHistory(change == "clear" ? [] : OmniboxScaleRows.history(20000), profileId: "p", sameSource: change != "switch")
    #expect(!sources.worker.hasPreparedIndex("p"))
    let model = HeroBarModel(windowId: "w", tabId: UUID().uuidString, profileId: "p", incognito: false, settings: { Settings(values: [:]) }, sources: sources)
    let field = FakeHeroField()
    model.field = field
    let log = Log()
    var events = HeroBarEvents()
    events.open = { log.opened.append(($0, $1)) }
    model.events = events
    edit(model, field, to: text)
    let start = ContinuousClock.now
    model.key(HeroKey(.enter))
    #expect(ContinuousClock.now - start < .milliseconds(100))
    let expected = text == "typed.com" ? "https://typed.com" : "https://www.google.com/search?q=" + text.replacingOccurrences(of: " ", with: "%20")
    #expect(log.opened.first?.0 == expected)
    #expect(model.settled)
    #expect(!sources.worker.hasPreparedIndex("p"))
  }

  @Test func anIndexSwapRefreshesOnlyBarsInItsProfile() async {
    let (model, field, sources, _) = make()
    #expect(sources.preparedIndex("p"))
    sources.setHistory([HistoryRow(url: "https://other.example/", title: "Other", favicon: nil, visits: 4, lastVisit: 1)], profileId: "q")
    #expect(sources.preparedIndex("q"))
    for _ in 0..<100 where findScope("other.example", sources.scopeSources("q", engines: builtInEngines)) == nil
      || findScope("github.com", sources.scopeSources("p", engines: builtInEngines)) == nil {
      try? await Task.sleep(for: .milliseconds(2))
    }
    let other = HeroBarModel(windowId: "other", tabId: UUID().uuidString, profileId: "q", incognito: false, settings: { Settings(values: [:]) }, sources: sources)
    let otherField = FakeHeroField()
    other.field = otherField
    edit(model, field, to: "beta")
    edit(other, otherField, to: "other")
    await waitSettled(model, sources)
    await waitSettled(other, sources)
    let release = hold(sources)
    let updated = sources.history("p") + [HistoryRow(url: "https://github.com/beta", title: "Beta", favicon: nil, visits: 20, lastVisit: 1)]
    sources.setHistory(updated, profileId: "p")
    model.sourcesChanged()
    other.sourcesChanged()
    let changed = Mutex<[String]>([])
    withObservationTracking {
      _ = model.sourcesRevision
    } onChange: {
      changed.withLock { $0.append("p") }
    }
    withObservationTracking {
      _ = other.sourcesRevision
    } onChange: {
      changed.withLock { $0.append("q") }
    }
    release.signal()
    #expect(sources.preparedIndex("p"))
    await waitSettled(model, sources)
    await waitSettled(other, sources)
    for _ in 0..<10 { await Task.yield() }
    #expect(changed.withLock { $0 } == ["p"])
    other.sourcesChanged()
    #expect(other.settled)
    model.sourcesChanged()
    await waitSettled(model, sources)
    #expect(pages(model).contains("https://github.com/beta"))
  }

}
