import AppKit
import SolaraModel
import SolaraStore
import Testing

@testable import SolaraUI

@MainActor
@Suite struct SidebarCleanUpUpsellTests {
  private func state() throws -> BrowserState {
    let ids = (1...12).map { "t\($0)" }
    var tabs: [String: Any] = [:]
    for id in ids { tabs[id] = ["id": id, "windowId": "w", "profileId": "p", "url": "https://\(id).example/", "title": id] }
    let root: [String: Any] = [
      "profileOrder": ["p"], "windowOrder": ["w"], "tabs": tabs,
      "windows": ["w": ["id": "w", "profileId": "p", "tabIds": ids, "activeTabIds": ["p": "t1"]]],
    ]
    let text = try #require(String(data: try JSONSerialization.data(withJSONObject: root), encoding: .utf8))
    return try BrowserState(stateJSON: try JSONValue.parse(text).object ?? [:])
  }

  private func mounted(_ host: SidebarHostState, suggestions: Bool = true, virtualizes: Bool = false, width: CGFloat = 260) throws -> (NSWindow, SidebarView) {
    let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: width, height: 900), styleMask: [.borderless], backing: .buffered, defer: false)
    let sidebar = SidebarView(windowId: "w", virtualizesRows: virtualizes)
    sidebar.frame = NSRect(x: 0, y: 0, width: width, height: 900)
    window.contentView = sidebar
    var current = try state()
    current.settings["suggestTabCleanUp"] = .bool(suggestions)
    sidebar.update(state: current, host: host)
    sidebar.layoutSubtreeIfNeeded()
    return (window, sidebar)
  }

  private func buttons(in view: NSView) -> [UpsellButton] {
    view.subviews.flatMap { ($0 as? UpsellButton).map { [$0] } ?? [] + buttons(in: $0) }
  }

  @Test func theSuggestionSitsUnderTheListAndItsButtonsAnswer() throws {
    var host = SidebarHostState(profileId: "p")
    host.upsell = 12
    host.product = "Solara"
    let (window, sidebar) = try mounted(host)
    _ = window
    let card = try #require(sidebar.views["upsell"])
    let newTab = try #require(sidebar.views["newTab"])
    let last = try #require(sidebar.views["t:t12"])
    #expect(card.frame.minY == max(newTab.frame.maxY, last.frame.maxY) + 10)
    #expect(card.frame.width == last.frame.width)
    let fields = card.subviews.flatMap(\.subviews).compactMap { $0 as? NSTextField }.map(\.stringValue)
    #expect(fields.contains("12 tabs haven’t been touched in a while"))
    let pressed = buttons(in: card)
    #expect(pressed.count == 4)
    #expect(pressed.allSatisfy { ($0.frame.height == 24 || $0.frame.height == 20) && $0.frame.maxY <= card.bounds.height - 10 + 0.5 })
    var got: [String] = []
    sidebar.onAction = { if case .cleanUp(let choice) = $0 { got.append(choice.rawValue) } }
    for button in pressed { _ = button.accessibilityPerformPress() }
    #expect(got == ["once", "daily", "dismiss", "dontAskAgain"])
  }

  @Test func titleMessageAndButtonsReadFromTopToBottom() throws {
    var host = SidebarHostState(profileId: "p")
    host.upsell = 12
    let (window, sidebar) = try mounted(host)
    _ = window
    let card = try #require(sidebar.views["upsell"])
    let fields = card.subviews.flatMap(\.subviews).compactMap { $0 as? NSTextField }
    let title = try #require(fields.first { $0.stringValue.hasPrefix("12 tabs") })
    let message = try #require(fields.first { $0.stringValue == CleanUpUpsellView.bodyText(product: "Solara") })
    let titleFrame = title.convert(title.bounds, to: sidebar)
    let messageFrame = message.convert(message.bounds, to: sidebar)
    let pressed = buttons(in: card)
    let frames = pressed.map { $0.convert($0.bounds, to: sidebar) }
    try #require(frames.count == 4)
    #expect(titleFrame.maxY <= messageFrame.minY)
    #expect(messageFrame.maxY < frames[0].minY)
    #expect(frames[0].maxY < frames[1].minY)
    #expect(frames[1].maxY < frames[2].minY)
    #expect(frames[2].minY == frames[3].minY)
    #expect(frames[2].maxX < frames[3].minX)
  }

  @Test func quietChoicesFitTheMinimumSidebarWidth() throws {
    var host = SidebarHostState(profileId: "p")
    host.upsell = 12
    let (window, sidebar) = try mounted(host, width: CGFloat(SidebarChromeMetrics.minWidth))
    _ = window
    let card = try #require(sidebar.views["upsell"])
    for button in buttons(in: card).suffix(2) {
      #expect(button.bounds.width >= button.titleWidth)
      #expect(button.frame.maxX <= card.bounds.width - CleanUpUpsellView.padding)
    }
  }

  @Test func disablingSuggestionsHidesACountFromTheHost() throws {
    var host = SidebarHostState(profileId: "p")
    host.upsell = 12
    let (window, sidebar) = try mounted(host, suggestions: false)
    _ = window
    #expect(sidebar.views["upsell"] == nil)
  }

  @Test func theVirtualChoiceAnswersDontAskAgain() throws {
    var host = SidebarHostState(profileId: "p")
    host.upsell = 12
    let (window, sidebar) = try mounted(host, virtualizes: true)
    _ = window
    var choice: SidebarCleanUpChoice?
    sidebar.onAction = { if case .cleanUp(let value) = $0 { choice = value } }
    #expect(sidebar.logicalLabel("upsell|dontAskAgain") == "Don't Ask Again")
    #expect(sidebar.performLogicalAction("upsell|dontAskAgain", action: "press"))
    #expect(choice == .dontAskAgain)
  }

  @Test func noSuggestionWithoutACount() throws {
    let (window, sidebar) = try mounted(SidebarHostState(profileId: "p"))
    _ = window
    #expect(sidebar.views["upsell"] == nil)
  }

  @Test func otherProfilesPagesNeverShowIt() {
    var host = SidebarHostState(profileId: "p")
    host.upsell = 12
    let other = SidebarPageLook(profileId: "q", dark: true, theme: [:], border: [], glow: host.glow, tidy: false, incognito: false)
    #expect(host.page(other).upsell == nil)
  }
}
