import Testing
@testable import SolaraUI

@Suite struct WebKitVisitRecorderTests {
  @Test func recordsCommittedPagesWithTheirOwnTitle() {
    var recorder = WebKitVisitRecorder()
    let url = "https://b.example/"
    let pending = recorder.note(tabId: "tab", profile: "work", url: url, committedURL: "https://a.example/", title: "A", loading: true, now: 0)
    #expect(pending.writes.isEmpty)
    #expect(pending.timer == nil)
    let committed = recorder.note(tabId: "tab", profile: "work", url: url, committedURL: url, title: "A", loading: true, now: 1)
    #expect(committed.writes.isEmpty)
    let titled = recorder.note(tabId: "tab", profile: "work", url: url, committedURL: url, title: "B", loading: true, now: 2)
    #expect(titled.writes.count == 1)
    #expect(titled.writes.first?.profile == "work")
    #expect(titled.writes.first?.url == url)
    #expect(titled.writes.first?.time == 1)
    #expect(titled.writes.first?.title == "B")
    let duplicate = recorder.note(tabId: "tab", profile: "work", url: url, committedURL: url, title: "B", loading: false, now: 3)
    #expect(duplicate.timer == nil)
  }

  @Test func settlementAndClosureKeepTheOriginalProfileAndDropPrivateVisits() throws {
    var recorder = WebKitVisitRecorder()
    let url = "https://a.example/"
    let first = recorder.note(tabId: "tab", profile: "work", url: url, committedURL: url, title: "A", loading: false, now: 0)
    let timer = try #require(first.timer)
    let moved = recorder.note(tabId: "tab", profile: "home", url: url, committedURL: url, title: "A", loading: false, now: 1)
    #expect(moved.timer == nil)
    let visit = recorder.settle(tabId: "tab", timer: timer)
    #expect(visit?.profile == "work")
    let privatePage = recorder.note(tabId: "private", profile: nil, url: url, committedURL: url, title: "A", loading: false, now: 0)
    #expect(privatePage.timer == nil)
    let closing = recorder.note(tabId: "closing", profile: "work", url: url, committedURL: url, title: "A", loading: false, now: 0)
    let closed = recorder.closeMissing(known: [])
    #expect(closed.map(\.profile) == ["work"])
    let stale = recorder.settle(tabId: "closing", timer: try #require(closing.timer))
    #expect(stale == nil)
  }
}
