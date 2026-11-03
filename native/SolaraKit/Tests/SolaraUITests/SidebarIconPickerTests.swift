import AppKit
import Testing
@testable import SolaraUI

@MainActor
@Suite struct SidebarIconPickerTests {
  static let catalogJSON = #"""
    {"unicode":"18.0","emoji":[
      {"name":"Smileys & Emotion","symbol":"face.smiling","items":[["😀","grinning face | happy | smile"],["😂","face with tears of joy | laugh"],["🥲","smiling face with tear | happy | sad"]]},
      {"name":"Travel & Places","symbol":"car","items":[["🚀","rocket | launch | space"],["🚗","automobile | car"],["🏠","house | home"],["🗺️","world map | map | travel"],["✈️","airplane | travel"],["🚲","bicycle | bike"]]},
      {"name":"Objects","symbol":"lightbulb","items":[["💡","light bulb | idea"],["📦","package | box"],["🔑","key | lock"]]}
    ],"symbols":[
      {"name":"Favorites","items":[["star","favorite star"],["heart","love like heart"],["bookmark","bookmark save"]]},
      {"name":"Shapes","items":[["star.fill","star filled"],["circle.fill","circle dot"]]}
    ]}
    """#

  func catalog() -> IconCatalog { IconCatalog(json: Self.catalogJSON, drawsEmoji: { _ in true }, hasSymbol: { _ in true }) }

  func recents() -> IconPickerRecents {
    let defaults = UserDefaults(suiteName: "icon-picker-tests-\(UUID().uuidString)")!
    return IconPickerRecents(defaults: defaults)
  }

  func state(kind: String = "tab", current: String? = nil) -> SidebarIconPickerState {
    SidebarIconPickerState(
      id: "t3", kind: kind, current: current, anchor: [6, 181, 178, 34], sidebarWidth: 240, dark: true, shadowOpacity: 0.5,
      theme: ["panel": "#262425", "pickerCellHover": "rgba(255,255,255,0.25)"])
  }

  func picker(_ recents: IconPickerRecents? = nil) -> SidebarIconPickerView {
    let view = SidebarIconPickerView()
    view.catalog = catalog()
    view.recents = recents ?? self.recents()
    return view
  }

  @Test func theGridFitsSevenColumnsBecauseTheBorderAndPaddingLeave239Points() {
    #expect(SidebarIconPickerMetrics.inner == 239)
    #expect(SidebarIconPickerMetrics.columns == 7)
  }

  @Test func itSitsBesideTheAnchorRowAndStaysInsideTheWindowEdge() {
    #expect(SidebarIconPickerMetrics.origin(anchor: CGRect(x: 6, y: 181, width: 178, height: 34), sidebarWidth: 240) == CGPoint(x: 190, y: 173))
    #expect(SidebarIconPickerMetrics.origin(anchor: CGRect(x: 6, y: 4, width: 300, height: 34), sidebarWidth: 240) == CGPoint(x: 246, y: 8))
    #expect(SidebarIconPickerMetrics.origin(anchor: nil, sidebarWidth: 240) == CGPoint(x: 246, y: 52))
  }

  @Test func theBundledCatalogDecodesEveryUnicodeGroupAndTheSymbolSets() {
    let shared = IconCatalog(json: iconCatalogJSON, drawsEmoji: { _ in true }, hasSymbol: { _ in true })
    #expect(shared.unicode == "18.0")
    #expect(shared.cldr == "49.0.0")
    #expect(shared.emoji.map(\.name) == ["Smileys & Emotion", "People & Body", "Animals & Nature", "Food & Drink", "Travel & Places", "Activities", "Objects", "Symbols", "Flags"])
    #expect(shared.emoji.map(\.entries.count) == [172, 378, 161, 132, 221, 85, 268, 224, 270])
    #expect(shared.symbols.map(\.name) == ["Favorites", "Work", "Money", "Tech", "Media", "Places", "Nature", "Activities", "Shapes"])
    #expect(shared.symbols.map(\.entries.count) == [12, 30, 11, 31, 20, 22, 19, 14, 18])
    #expect(shared.symbols.flatMap(\.entries).allSatisfy { $0.icon.hasPrefix("symbol:") })
    #expect(shared.search(.emoji, "rocket").first == "🚀")
  }

  @Test func theSystemDrawsTheCatalogsEmojiAndSymbols() {
    let shared = IconCatalog.shared
    let all = IconCatalog(json: iconCatalogJSON, drawsEmoji: { _ in true }, hasSymbol: { _ in true })
    #expect(shared.emoji.flatMap(\.entries).count > 1700)
    #expect(shared.emoji.flatMap(\.entries).count <= all.emoji.flatMap(\.entries).count)
    #expect(shared.symbols.flatMap(\.entries).count == all.symbols.flatMap(\.entries).count)
    #expect(!IconCatalog.drawnAsOneGlyph("🫩🫩"))
    #expect(IconCatalog.drawnAsOneGlyph("🧑‍💻"))
  }

  @Test func searchMatchesNamesAndKeywordsAcrossSectionsWithWordStartsFirst() {
    let c = catalog()
    #expect(c.search(.emoji, " Rocket ") == ["🚀"])
    #expect(c.search(.emoji, "happy") == ["😀", "🥲"])
    #expect(c.search(.emoji, "travel") == ["🗺️", "✈️"])
    #expect(c.search(.emoji, "car") == ["🚗"])
    #expect(c.search(.emoji, "bike") == ["🚲"])
    #expect(c.search(.emoji, "house") == ["🏠"])
    #expect(c.search(.emoji, "map") == ["🗺️"])
    #expect(c.search(.emoji, "world map") == ["🗺️"])
    #expect(c.search(.symbols, "star") == ["symbol:star", "symbol:star.fill"])
    #expect(c.search(.emoji, "").count == 12)
  }

  @Test func itOpensOnTheSectionHoldingTheCurrentIconAndShowsOneSectionAtATime() {
    let view = picker()
    view.set(state(current: "🚗"))
    #expect(view.tab == .emoji)
    #expect(view.section == "Travel & Places")
    #expect(view.items == ["🚀", "🚗", "🏠", "🗺️", "✈️", "🚲"])
    view.show(section: "Objects")
    #expect(view.items == ["💡", "📦", "🔑"])
  }

  @Test func aSymbolIconOpensOnTheIconsTab() {
    let view = picker()
    view.set(state(current: "symbol:star.fill"))
    #expect(view.tab == .symbols)
    #expect(view.section == "Shapes")
    #expect(view.items.first == "symbol:star.fill")
  }

  @Test func searchRanksTheNamedEmojiThenAKeywordThenAWordStartThenTheRest() {
    let json = #"{"unicode":"18.0","emoji":[{"name":"A","items":[["🛸","flying saucer | ufo | rockets"],["🧑‍🚀","astronaut | rocket | space"],["🎆","fireworks | skyrocket"],["🚀","rocket | launch"]]}],"symbols":[]}"#
    let c = IconCatalog(json: json, drawsEmoji: { _ in true }, hasSymbol: { _ in true })
    #expect(c.search(.emoji, "rocket") == ["🚀", "🧑‍🚀", "🛸", "🎆"])
  }

  @Test func typingSearchesEverySectionAndPickingASectionClearsTheSearch() {
    let view = picker()
    view.set(state())
    view.devInput("type:travel")
    #expect(view.items == ["🗺️", "✈️"])
    view.show(section: "Objects")
    #expect(view.query == "")
    #expect(view.items == ["💡", "📦", "🔑"])
  }

  @Test func theHeightIsFixedAndAddsTheFooterWhenThereIsSomethingToReset() {
    let view = picker()
    view.set(state())
    #expect(view.panelHeight == 263)
    view.set(state(kind: "group"))
    #expect(view.panelHeight == 297)
    view.show(section: "Objects")
    #expect(view.panelHeight == 297)
  }

  @Test func returnChoosesTheFirstMatchAndEscapeCloses() {
    let view = picker()
    var events: [SidebarIconPickerView.Event] = []
    view.onEvent = { events.append($0) }
    view.set(state())
    let editor = NSTextView()
    _ = view.control(NSTextField(), textView: editor, doCommandBy: #selector(NSResponder.insertNewline(_:)))
    _ = view.control(NSTextField(), textView: editor, doCommandBy: #selector(NSResponder.cancelOperation(_:)))
    #expect(events == [.choose("😀"), .close])
  }

  @Test func arrowKeysMoveTheHighlightAndReturnChoosesIt() {
    let view = picker()
    var events: [SidebarIconPickerView.Event] = []
    view.onEvent = { events.append($0) }
    view.set(state(current: "🚀"))
    let editor = NSTextView()
    for key in [#selector(NSResponder.moveDown(_:)), #selector(NSResponder.moveRight(_:)), #selector(NSResponder.moveRight(_:)), #selector(NSResponder.moveDown(_:))] {
      _ = view.control(NSTextField(), textView: editor, doCommandBy: key)
    }
    #expect(view.describe()["hovered"] as? String == "🚲")
    _ = view.control(NSTextField(), textView: editor, doCommandBy: #selector(NSResponder.moveLeft(_:)))
    _ = view.control(NSTextField(), textView: editor, doCommandBy: #selector(NSResponder.insertNewline(_:)))
    #expect(events == [.choose("✈️")])
  }

  @Test func aChoiceBecomesARecentThatOpensFirstNextTime() {
    let shared = recents()
    let view = picker(shared)
    view.onEvent = { _ in }
    view.set(state())
    view.devInput("type:key")
    _ = view.control(NSTextField(), textView: NSTextView(), doCommandBy: #selector(NSResponder.insertNewline(_:)))
    #expect(shared.list(.emoji) == ["🔑"])
    #expect(shared.list(.symbols).isEmpty)
    let next = picker(shared)
    next.set(state(kind: "group"))
    #expect(next.sectionNames.first == "Recent")
    #expect(next.section == "Recent")
    #expect(next.items == ["🔑"])
  }

  @Test func recentsKeepTheNewestFirstWithoutDuplicatesAndCapAtThreeRows() {
    let shared = recents()
    for index in 0..<30 { shared.note("e\(index)") }
    shared.note("e5")
    shared.note("symbol:star")
    #expect(shared.list(.emoji).count == SidebarIconPickerMetrics.recentLimit)
    #expect(shared.list(.emoji).first == "e5")
    #expect(shared.list(.emoji).filter { $0 == "e5" }.count == 1)
    #expect(shared.list(.symbols) == ["symbol:star"])
  }

  @Test func aProfileOffersUseInitialInsteadOfReset() {
    let view = picker()
    view.set(state(kind: "profile", current: "🚀"))
    #expect(view.describe()["footer"] as? [String] == ["Use Initial"])
  }

  @Test func embeddedItSizesToThePanelAndIgnoresClicksOutsideIt() {
    let view = picker()
    view.embedded = true
    view.set(state())
    #expect(view.intrinsicContentSize == NSSize(width: SidebarIconPickerMetrics.width, height: view.panelHeight))
    view.frame = NSRect(x: 0, y: 0, width: 400, height: 400)
    view.layoutSubtreeIfNeeded()
    #expect(view.panel.frame.origin == .zero)
    #expect(view.hitTest(NSPoint(x: 350, y: 350)) == nil)
  }
}
