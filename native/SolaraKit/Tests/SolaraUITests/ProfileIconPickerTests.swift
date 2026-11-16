import AppKit
import Testing
@testable import SolaraUI

@MainActor
@Suite struct ProfileIconPickerTests {
  func catalog() -> ProfileIconCatalog {
    ProfileIconCatalog(emoji: IconCatalog(json: SidebarIconPickerTests.catalogJSON, drawsEmoji: { _ in true }, hasSymbol: { _ in true }), hasSymbol: { _ in true })
  }

  func picker(current: String? = nil) -> ProfileIconPickerView {
    let view = ProfileIconPickerView()
    view.catalog = catalog()
    view.frame.size = view.intrinsicContentSize
    view.configure(profileId: "work", current: current, dark: false, tint: .systemPurple)
    return view
  }

  @Test func theCuratedIconsUseTheExistingSymbolEncodingAndFitFourRows() {
    let icons = catalog().entries(tab: .symbols, query: "", category: nil)
    #expect(icons.count == 32)
    #expect(Set(icons.map(\.icon)).count == 32)
    #expect(icons.allSatisfy { $0.icon.hasPrefix("symbol:") })
    #expect(ProfileIconPickerMetrics.columns == 8)
    #expect(ProfileIconPickerMetrics.cellHeight == 34)
    #expect(ProfileIconPickerMetrics.width == 342)
    #expect(ProfileIconPickerMetrics.inner == 318)
  }

  @Test func iconSearchMatchesNamesAndEmojiSearchFindsResultsAcrossCategories() {
    let c = catalog()
    #expect(c.entries(tab: .symbols, query: " STAR ", category: nil).map(\.icon) == ["symbol:star.fill"])
    #expect(c.entries(tab: .symbols, query: "briefcase", category: nil).map(\.icon) == ["symbol:briefcase.fill"])
    #expect(c.entries(tab: .emoji, query: " rocket ", category: "Objects").map(\.icon) == ["🚀"])
    #expect(c.entries(tab: .emoji, query: "unfindable", category: nil).isEmpty)
  }

  @Test func aDotOrSymbolOpensIconAndEmojiOpensItsOwnCategory() {
    #expect(picker().tab == .symbols)
    #expect(picker(current: "symbol:heart.fill").tab == .symbols)
    let view = picker(current: "🚀")
    #expect(view.tab == .emoji)
    #expect(view.category == "Travel & Places")
    #expect(view.current == "🚀")
  }

  @Test func reopeningTheSameProfileUsesItsLatestIconKind() {
    let view = picker(current: "symbol:star.fill")
    view.configure(profileId: "work", current: "🚀", dark: false, tint: .systemPurple, reset: true)
    #expect(view.tab == .emoji)
    #expect(view.category == "Travel & Places")
  }

  @Test func categoriesClearSearchAndShowTheirOwnGrid() {
    let view = picker(current: "🚀")
    view.setQuery("key")
    #expect(view.items.map(\.icon) == ["🔑"])
    view.show(category: "Objects")
    #expect(view.query.isEmpty)
    #expect(view.items.map(\.icon) == ["💡", "📦", "🔑"])
    view.select(.symbols)
    view.setQuery("star")
    #expect(view.items.map(\.icon) == ["symbol:star.fill"])
  }

  @Test func choosingAndClearingApplyImmediatelyAndKeepThePickerOpen() {
    let view = picker()
    var events: [SidebarIconPickerView.Event] = []
    view.onEvent = { events.append($0) }
    view.choose("symbol:star.fill")
    #expect(view.current == "symbol:star.fill")
    view.choose("🍌")
    #expect(view.current == "🍌")
    view.choose(nil)
    #expect(view.current == nil)
    #expect(events == [.choose("symbol:star.fill"), .choose("🍌"), .choose(nil)])
    view.cancelOperation(nil)
    #expect(events.last == .close)
  }

  @Test func searchReturnChoosesItsFirstResultAndEscapeCloses() {
    let view = picker(current: "🚀")
    var events: [SidebarIconPickerView.Event] = []
    view.onEvent = { events.append($0) }
    view.setQuery("key")
    #expect(view.control(NSSearchField(), textView: NSTextView(), doCommandBy: #selector(NSResponder.insertNewline(_:))))
    #expect(events == [.choose("🔑")])
    #expect(view.control(NSSearchField(), textView: NSTextView(), doCommandBy: #selector(NSResponder.cancelOperation(_:))))
    #expect(events.last == .close)
  }

  @Test func accessibleCellsHaveSpokenNamesAndSelectionAndClearHasAnActionName() {
    let view = picker(current: "symbol:star.fill")
    view.layoutSubtreeIfNeeded()
    let scroll = view.subviews.compactMap { $0 as? NSScrollView }.first
    let buttons = scroll?.documentView?.subviews.compactMap { $0 as? NSButton } ?? []
    let star = buttons.first { $0.accessibilityLabel() == "Star" }
    #expect(star != nil)
    #expect(star?.state == .on)
    #expect(view.subviews.contains { $0.accessibilityLabel() == "Use the dot" })
    #expect(view.subviews.contains { $0.accessibilityLabel() == "Search icons" })
  }

  @Test func darkAndEveryTintKeepTheCatalogAndCurrentSelection() {
    let view = picker(current: "symbol:heart.fill")
    for color in ProfileColorValue.allCases {
      view.configure(profileId: "work", current: "symbol:heart.fill", dark: true, tint: CSSColor(color.swatch)!.ns)
      #expect(view.appearance?.name == .darkAqua)
      #expect(view.current == "symbol:heart.fill")
      #expect(view.items.count == 32)
    }
  }
}
