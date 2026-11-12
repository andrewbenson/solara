import AppKit
import Foundation
import ImageIO
import SolaraModel
import Testing

@testable import SolaraUI

@Suite struct UnreadTitleParserTests {
  @Test(arguments: [
    "(3) Inbox", "Inbox (3)", "3 new", "[3]", "[3] Inbox", "Inbox [3]",
    "Inbox (3) - me@example.com - Gmail", "(3) general - Acme - Slack", "[3] Slack",
    "(3) Outlook", "(3) WhatsApp", "(3) Discord", "[3] Discord", "(3) Messenger",
    "3 new messages - Messenger", "(3) Microsoft Teams", "Chat (3)", "(3) Inbox - Linear",
    "(3) Notifications", "Notifications (3)", "3 unread - Inbox",
  ])
  func supportedTitles(_ title: String) { #expect(UnreadTitleParser.count(in: title) == 3) }

  @Test(arguments: [
    "(2024) Annual report", "Annual report (2024)", "Top 10", "Issue #3", "A [3] citation in prose",
    "Version (3.1)", "(-3) Inbox", "(0) Inbox", "(3,4) Inbox", "3 new features available",
    "Release 3", "(999999999999999999999) Inbox", "Inbox (3) discussion", "(3)",
  ])
  func falsePositives(_ title: String) { #expect(UnreadTitleParser.count(in: title) == nil) }

  @Test func largeCountsAndWhitespace() {
    #expect(UnreadTitleParser.count(in: "  (100) Inbox  ") == 100)
    #expect(UnreadTitleParser.count(in: "Inbox (1,234) - Gmail") == 1234)
    #expect(UnreadTitleParser.count(in: "[3]") == 3)
  }
}

@Suite struct UnreadFaviconTests {
  private func fixture(_ name: String) throws -> Data {
    let url = try #require(Bundle.module.url(forResource: name, withExtension: "png", subdirectory: "UnreadFixtures"))
    return try Data(contentsOf: url)
  }

  @Test(arguments: ["red-top-right", "blue-bottom-left", "orange-top-left", "green-bottom-right", "dot-with-center"])
  func cornerDots(_ name: String) throws { #expect(UnreadFaviconDetector.hasDot(in: try fixture(name))) }

  @Test(arguments: ["plain", "gray-dot", "large-disc", "center-dot", "gmail-chevron", "slack-cross", "tiny-pixel", "gmail-brand", "slack-brand"])
  func plainFavicons(_ name: String) throws { #expect(!UnreadFaviconDetector.hasDot(in: try fixture(name))) }

  @Test func aStableURLWithDifferentPixelsDoesNotReuseTheOldResult() async throws {
    let analyzer = UnreadFaviconAnalyzer()
    let red = try #require(CGImageSourceCreateWithData(try fixture("red-top-right") as CFData, nil))
    let plain = try #require(CGImageSourceCreateWithData(try fixture("plain") as CFData, nil))
    let redImage = UnreadFaviconImage(image: try #require(CGImageSourceCreateImageAtIndex(red, 0, nil)))
    let plainImage = UnreadFaviconImage(image: try #require(CGImageSourceCreateImageAtIndex(plain, 0, nil)))
    #expect(await analyzer.hasDot(source: "https://fixture.test/favicon.ico", image: redImage))
    #expect(!(await analyzer.hasDot(source: "https://fixture.test/favicon.ico", image: plainImage)))
    #expect(await analyzer.hasDot(source: "https://fixture.test/favicon.ico", image: redImage))
    let diagnostics = await analyzer.diagnostics()
    #expect(diagnostics["requests"] == 3)
    #expect(diagnostics["classifications"] == 2)
    #expect(diagnostics["cacheHits"] == 1)
    #expect(diagnostics["cacheEntries"] == 2)
    #expect(diagnostics["mainThreadAnalyses"] == 0)
    print("Unread favicon diagnostics: \(diagnostics)")
  }

  @Test func invalidAndOversizedData() {
    #expect(!UnreadFaviconDetector.hasDot(in: Data("not a PNG".utf8)))
    #expect(!UnreadFaviconDetector.hasDot(in: Data(repeating: 0, count: 262_145)))
  }
}

@Suite struct UnreadSignalTests {
  @Test func priorityAndExplicitClear() {
    #expect(UnreadSignal.resolve(api: .count(8), title: 3, favicon: true) == .count(8))
    #expect(UnreadSignal.resolve(api: .dot, title: 3, favicon: true) == .dot)
    #expect(UnreadSignal.resolve(api: .clear, title: 3, favicon: true) == nil)
    #expect(UnreadSignal.resolve(api: .unset, title: 3, favicon: true) == .count(3))
    #expect(UnreadSignal.resolve(api: .unset, title: nil, favicon: true) == .dot)
    #expect(UnreadSignal.resolve(api: .unset, title: nil, favicon: false) == nil)
  }

  @Test func apiDecoding() {
    #expect(UnreadAPIValue.decode(["kind": "count", "count": "18446744073709551615"]) == .count(100))
    #expect(UnreadAPIValue.decode(["kind": "count", "count": "0"]) == .clear)
    #expect(UnreadAPIValue.decode(["kind": "count", "count": "-1"]) == nil)
    #expect(UnreadAPIValue.decode(["kind": "count", "count": "1.5"]) == nil)
    #expect(UnreadAPIValue.decode(["kind": "unset"]) == .unset)
  }

  @MainActor @Test func staleFaviconResultsCannotCrossDocumentsOrRequests() {
    let feed = UnreadBadgeFeed()
    feed.receive(key: "a", document: "one", kind: "reset", payload: [:])
    let first = feed.reserveFavicon(key: "a", document: "one")
    let second = feed.reserveFavicon(key: "a", document: "one")
    feed.finishFavicon(key: "a", document: "one", ticket: first, hasDot: true)
    #expect(feed.status(key: "a", title: "Inbox") == nil)
    feed.finishFavicon(key: "a", document: "one", ticket: second, hasDot: true)
    #expect(feed.status(key: "a", title: "Inbox") == .dot)
    feed.receive(key: "a", document: "two", kind: "reset", payload: [:])
    feed.finishFavicon(key: "a", document: "one", ticket: second, hasDot: true)
    #expect(feed.status(key: "a", title: "Inbox") == nil)
    #expect(!feed.accepts(key: "a", document: "one"))
    #expect(feed.accepts(key: "a", document: "two"))
    feed.receive(key: "a", document: "one", kind: "badge", payload: ["kind": "count", "count": "9"])
    #expect(feed.status(key: "a", title: "Inbox") == nil)
  }

  @MainActor @Test func lifecycleAndClear() {
    let feed = UnreadBadgeFeed()
    feed.receive(key: "a", document: "one", kind: "reset", payload: [:])
    feed.receive(key: "a", document: "one", kind: "badge", payload: ["kind": "clear"])
    #expect(feed.status(key: "a", title: "(3) Inbox") == nil)
    feed.receive(key: "a", document: "two", kind: "reset", payload: [:])
    #expect(feed.status(key: "a", title: "(3) Inbox") == .count(3))
    feed.receive(key: "a", document: "two", kind: "closed", payload: [:])
    #expect(feed.status(key: "a", title: "Inbox") == nil)
  }
}
