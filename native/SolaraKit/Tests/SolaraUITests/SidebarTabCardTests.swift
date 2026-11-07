import AppKit
import Testing

@testable import SolaraUI

@MainActor
@Suite struct SidebarTabCardTests {
  private func state(title: String = "Example", host: String? = "example.com", sleeping: Bool = false, buttons: Int = 3) throws -> SidebarTabCardState {
    let actions = ["pin", "bookmark", "split", "pip", "back"].prefix(buttons).map { ["action": $0, "icon": "pin", "label": $0] }
    let value: [String: Any] = [
      "tabId": "a", "title": title, "host": host as Any? ?? NSNull(), "sleeping": sleeping, "buttons": actions,
      "anchor": [8, 100, 184, 34], "sidebarWidth": 200, "windowHeight": 800,
      "look": ["fill": "#262626", "border": "#404040", "primary": "rgba(255,255,255,0.86)", "secondary": "rgba(255,255,255,0.585)",
               "tertiary": "#FFFFFF59", "hover": "rgba(255,255,255,0.1)", "pressed": "rgba(255,255,255,0.18)", "shadowOpacity": 0.5],
    ]
    return try #require(SidebarTabCardState.decode(value))
  }

  @Test func aOneLineCardIsRNsHeight() throws {
    let card = SidebarTabCardView()
    card.set(try state())
    #expect(card.frame.size == NSSize(width: 200, height: 0.5 + 16.5 + 16 + 16 + 10 + 28 + 6 + 0.5))
  }

  @Test func aLongTitleWrapsToTwoLinesAndNoFurther() throws {
    let card = SidebarTabCardView()
    card.set(try state(title: String(repeating: "A very long page title ", count: 8), host: nil))
    #expect(abs(card.frame.height - (0.5 + 16.5 + 32 + 10 + 28 + 6 + 0.5)) < 0.001)
  }

  @Test func buttonsShareTheWidthAtRNsPitch() throws {
    let card = SidebarTabCardView()
    card.set(try state(buttons: 5))
    card.layoutSubtreeIfNeeded()
    let buttons = card.subviews.compactMap { $0 as? SidebarIconButton }
    #expect(buttons.count == 5)
    let pitch = min(49, 196.0 / 5)
    #expect(abs((buttons[1].frame.minX - buttons[0].frame.minX) - pitch) < 0.001)
    #expect(abs(buttons[0].frame.minX - ((200 - pitch * 5) / 2 + (pitch - 28) / 2)) < 0.001)
    #expect(buttons.map(\.frame.minY).allSatisfy { $0 == 0.5 + 16.5 + 32 + 10 })
  }

  @Test func theCardSitsAtTheSidebarEdgeCentredOnTheRowAndClamped() {
    let row = CGRect(x: 8, y: 100, width: 192, height: 34)
    #expect(SidebarTabCardMetrics.origin(anchor: row, sidebarWidth: 200, cardHeight: 92, windowHeight: 800) == CGPoint(x: 200.5, y: 117 - 46))
    let tile = CGRect(x: 8, y: 10, width: 40, height: 40)
    #expect(SidebarTabCardMetrics.origin(anchor: tile, sidebarWidth: 200, cardHeight: 92, windowHeight: 800) == CGPoint(x: 200.5, y: 8))
    let low = CGRect(x: 8, y: 780, width: 192, height: 34)
    #expect(SidebarTabCardMetrics.origin(anchor: low, sidebarWidth: 200, cardHeight: 92, windowHeight: 800).y == 700)
  }

  @Test func pressingAButtonReportsItsAction() throws {
    let card = SidebarTabCardView()
    var pressed: [String] = []
    card.onAction = { pressed.append($0) }
    card.set(try state(buttons: 2))
    let buttons = card.subviews.compactMap { $0 as? SidebarIconButton }
    buttons[1].onPress?()
    #expect(pressed == ["bookmark"])
    #expect(buttons[1].accessibilityLabel() == "bookmark")
  }

  @Test func memoryUsesBinaryMegabytesAndGigabytes() {
    #expect(SidebarTabMemory.text(152 * 1024 * 1024) == "Memory usage: 152 MB")
    #expect(SidebarTabMemory.text(799 * 1024 * 1024) == "Memory usage: 799 MB")
    #expect(SidebarTabMemory.text(800 * 1024 * 1024) == "Memory usage: 800 MB")
    #expect(SidebarTabMemory.text(801 * 1024 * 1024) == "High memory usage · 801 MB")
    #expect(!SidebarTabMemory.isHigh(SidebarTabMemory.highBytes))
    #expect(SidebarTabMemory.isHigh(801 * 1024 * 1024))
    #expect(SidebarTabMemory.text(1.2 * 1024 * 1024 * 1024) == "High memory usage · 1.2 GB")
    #expect(SidebarTabMemory.text(2 * 1024 * 1024 * 1024) == "High memory usage · 2 GB")
    #expect(SidebarTabMemory.text(nil) == "Memory usage: —")
  }

  @Test func absentMemoryAddsNoHeight() throws {
    let card = SidebarTabCardView()
    card.set(try state())
    let height = card.frame.height
    card.setMemory(.absent)
    #expect(card.memoryShown == nil)
    #expect(card.frame.height == height)
    card.setMemory(.unknown)
    card.setMemory(.absent)
    #expect(card.memoryShown == nil)
    #expect(card.frame.height == height)
  }

  @Test func unknownAndMeasuredMemoryReserveOneLineUnderTheHost() throws {
    let card = SidebarTabCardView()
    card.set(try state())
    let without = card.frame.height
    card.setMemory(.unknown)
    let unknownHeight = card.frame.height
    #expect(card.memoryShown == "Memory usage: —")
    card.layoutSubtreeIfNeeded()
    let label = try #require(card.subviews.compactMap { $0 as? NSTextField }.first { $0.stringValue == "Memory usage: —" })
    #expect(label.font == NSFont.systemFont(ofSize: 11.5))
    #expect(label.textColor == CSSColor(card.state!.look.tertiary)?.ns)
    #expect(abs(label.frame.minY - (0.5 + 16.5 + 16 + 16 + 2)) < 0.001)
    #expect(abs(unknownHeight - without - (label.frame.height + 2)) < 0.001)
    let buttons = card.subviews.compactMap { $0 as? SidebarIconButton }
    #expect(buttons.allSatisfy { abs($0.frame.minY - (label.frame.maxY + SidebarTabCardMetrics.actionsGap)) < 0.001 })
    card.setMemory(.bytes(152 * 1024 * 1024))
    #expect(card.memoryShown == "Memory usage: 152 MB")
    #expect(card.frame.height == unknownHeight)
    card.setMemory(.bytes(SidebarTabMemory.highBytes))
    #expect(card.memoryShown == "Memory usage: 800 MB")
    #expect(card.frame.height == unknownHeight)
    #expect(label.font == NSFont.systemFont(ofSize: 11.5))
    #expect(label.textColor == CSSColor(card.state!.look.tertiary)?.ns)
    card.setMemory(.bytes(801 * 1024 * 1024))
    #expect(card.memoryShown == "High memory usage · 801 MB")
    #expect(card.frame.height == unknownHeight)
    #expect(label.font == NSFont.systemFont(ofSize: 11.5, weight: .medium))
    #expect(label.textColor == CSSColor(card.state!.look.primary)?.ns)
  }

  @Test func sleepingAlwaysHidesMemory() throws {
    let card = SidebarTabCardView()
    card.set(try state())
    card.setMemory(.bytes(152 * 1024 * 1024))
    card.set(try state(sleeping: true))
    let height = card.frame.height
    #expect(card.memoryShown == nil)
    for row in [SidebarTabMemoryRow.unknown, .bytes(SidebarTabMemory.highBytes)] {
      card.setMemory(row)
      #expect(card.memoryShown == nil)
      #expect(card.frame.height == height)
    }
  }

  @Test func anotherTabResetsMemoryButSameTabUpdatesKeepIt() throws {
    let card = SidebarTabCardView()
    card.set(try state())
    let height = card.frame.height
    card.setMemory(.bytes(152 * 1024 * 1024))
    card.set(try state(title: "Updated"))
    #expect(card.memoryShown == "Memory usage: 152 MB")
    var next = try state()
    next.tabId = "b"
    card.set(next)
    #expect(card.memoryShown == nil)
    #expect(card.frame.height == height)
  }

  @Test func aMissingQueryHidesMemoryAndDoesNotAnswer() {
    let cache = TabMemoryCache()
    var asked = 0
    var answered = 0
    #expect(cache.row("a", sleeping: false) == .absent)
    cache.ask("a") { _ in answered += 1 }
    cache.query = { _, reply in
      asked += 1
      reply([:])
    }
    cache.query = nil
    cache.ask("a") { _ in answered += 1 }
    #expect(asked == 0)
    #expect(answered == 0)
  }

  @Test func aReplyCachesItsReadingAndSleepingHidesIt() {
    let cache = TabMemoryCache()
    let reading = TabMemoryReading(bytes: 152 * 1024 * 1024, source: "test", at: Date())
    cache.query = { _, reply in reply(["a": reading]) }
    #expect(cache.row("a", sleeping: false) == .unknown)
    var answered: [String] = []
    cache.ask("a") { answered.append($0) }
    #expect(answered == ["a"])
    #expect(cache.row("a", sleeping: false) == .bytes(reading.bytes))
    #expect(cache.row("a", sleeping: true) == .absent)
    cache.query = nil
    #expect(cache.row("a", sleeping: false) == .absent)
  }

  @Test func concurrentAsksShareOneReplyAndAnswerEachWaiter() throws {
    let cache = TabMemoryCache()
    var asked: [[String]] = []
    var reply: (@MainActor ([String: TabMemoryReading]) -> Void)?
    cache.query = { ids, answer in
      asked.append(ids)
      reply = answer
    }
    var answered: [String] = []
    cache.ask("a") { answered.append("first:" + $0) }
    cache.ask("a") { answered.append("second:" + $0) }
    #expect(asked == [["a"]])
    #expect(answered.isEmpty)
    let answer = try #require(reply)
    let reading = TabMemoryReading(bytes: 152 * 1024 * 1024, source: "test", at: Date())
    answer(["a": reading])
    #expect(cache.row("a", sleeping: false) == .bytes(reading.bytes))
    #expect(answered == ["first:a", "second:a"])
  }

  @Test func anEmptyReplyRemovesTheCachedReading() {
    let cache = TabMemoryCache()
    let reading = TabMemoryReading(bytes: 152 * 1024 * 1024, source: "test", at: Date())
    cache.query = { _, reply in reply(["a": reading]) }
    cache.ask("a") { _ in }
    #expect(cache.row("a", sleeping: false) == .bytes(reading.bytes))
    cache.query = { _, reply in reply([:]) }
    var answered: [String] = []
    cache.ask("a") { answered.append($0) }
    #expect(cache.row("a", sleeping: false) == .unknown)
    #expect(answered == ["a"])
  }

  @Test func forgettingRemovesOnlyTheNamedTabsReading() {
    let cache = TabMemoryCache()
    let reading = TabMemoryReading(bytes: 152 * 1024 * 1024, source: "test", at: Date())
    cache.query = { ids, reply in reply(Dictionary(uniqueKeysWithValues: ids.map { ($0, reading) })) }
    cache.ask("a") { _ in }
    cache.ask("b") { _ in }
    cache.forget("a")
    #expect(cache.row("a", sleeping: false) == .unknown)
    #expect(cache.row("b", sleeping: false) == .bytes(reading.bytes))
  }

  @Test func anAnswerCanAskAgainAfterASynchronousReply() {
    let cache = TabMemoryCache()
    var asked = 0
    var answered: [String] = []
    cache.query = { _, reply in
      asked += 1
      reply([:])
    }
    cache.ask("a") { id in
      answered.append(id)
      cache.ask(id) { answered.append($0) }
    }
    #expect(asked == 2)
    #expect(answered == ["a", "a"])
  }

  @Test func clearingIgnoresRepliesFromAnEarlierQuery() throws {
    let cache = TabMemoryCache()
    let reading = TabMemoryReading(bytes: 152 * 1024 * 1024, source: "test", at: Date())
    var replies: [@MainActor ([String: TabMemoryReading]) -> Void] = []
    cache.query = { _, reply in replies.append(reply) }
    var answered: [String] = []
    cache.ask("a") { answered.append("old:" + $0) }
    cache.clear()
    cache.ask("a") { answered.append("new:" + $0) }
    #expect(replies.count == 2)
    let old = try #require(replies.first)
    old(["a": reading])
    #expect(cache.row("a", sleeping: false) == .unknown)
    #expect(answered.isEmpty)
    let current = try #require(replies.last)
    current([:])
    #expect(cache.row("a", sleeping: false) == .unknown)
    #expect(answered == ["new:a"])
  }
}
