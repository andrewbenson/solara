import AppKit
import CoreText

public struct IconCatalogEntry: Equatable, Sendable {
  public let icon: String
  public let words: String
}

public struct IconCatalogSection: Equatable, Sendable {
  public let name: String
  public let symbol: String
  public let entries: [IconCatalogEntry]
}

public struct IconCatalog: Sendable {
  public let unicode: String
  public let cldr: String
  public let emoji: [IconCatalogSection]
  public let symbols: [IconCatalogSection]

  public static let shared = IconCatalog(json: iconCatalogJSON)

  init(json: String, drawsEmoji: (String) -> Bool = IconCatalog.drawnAsOneGlyph, hasSymbol: (String) -> Bool = IconCatalog.systemHasSymbol) {
    struct Document: Decodable {
      struct Section: Decodable {
        let name: String
        let symbol: String?
        let items: [[String]]
      }
      let unicode: String
      let cldr: String?
      let emoji: [Section]
      let symbols: [Section]
    }
    guard let document = try? JSONDecoder().decode(Document.self, from: Data(json.utf8)) else {
      unicode = ""
      cldr = ""
      emoji = []
      symbols = []
      return
    }
    func entries(_ items: [[String]], keep: (String) -> Bool) -> [IconCatalogEntry] {
      items.compactMap { item in
        guard let icon = item.first, keep(icon) else { return nil }
        return IconCatalogEntry(icon: icon, words: item.count > 1 ? item[1] : "")
      }
    }
    unicode = document.unicode
    cldr = document.cldr ?? ""
    emoji = document.emoji.map { IconCatalogSection(name: $0.name, symbol: $0.symbol ?? "", entries: entries($0.items, keep: drawsEmoji)) }
      .filter { !$0.entries.isEmpty }
    symbols = document.symbols.map { section in
      IconCatalogSection(name: section.name, symbol: section.symbol ?? "", entries: entries(section.items, keep: hasSymbol).map {
        IconCatalogEntry(icon: SidebarIconPickerMetrics.symbolPrefix + $0.icon, words: $0.words)
      })
    }.filter { !$0.entries.isEmpty }
  }

  public func sections(_ tab: SidebarIconPickerTab) -> [IconCatalogSection] {
    tab == .emoji ? emoji : symbols
  }

  public func search(_ tab: SidebarIconPickerTab, _ query: String) -> [String] {
    let terms = query.lowercased().split(whereSeparator: \.isWhitespace).map(String.init)
    let all = sections(tab).flatMap(\.entries)
    guard !terms.isEmpty else { return all.map(\.icon) }
    let phrase = terms.joined(separator: " ")
    var tiers: [[String]] = [[], [], [], []]
    for entry in all {
      let words = entry.words.split(separator: "|").map { $0.trimmingCharacters(in: .whitespaces) }
      let tokens = words.flatMap { $0.split(separator: " ").map(String.init) }
      guard terms.allSatisfy({ term in words.contains { $0.contains(term) } || entry.icon == term }) else { continue }
      let tier = words.first == phrase ? 0 : words.contains(phrase) ? 1 : terms.allSatisfy({ term in tokens.contains { $0.hasPrefix(term) } }) ? 2 : 3
      tiers[tier].append(entry.icon)
    }
    return tiers.flatMap { $0 }
  }

  static func drawnAsOneGlyph(_ emoji: String) -> Bool {
    let font = CTFontCreateWithName("AppleColorEmoji" as CFString, 18, nil)
    let line = CTLineCreateWithAttributedString(NSAttributedString(string: emoji, attributes: [.font: font]))
    guard CTLineGetGlyphCount(line) == 1, let runs = CTLineGetGlyphRuns(line) as? [CTRun], let run = runs.first else { return false }
    let attributes = CTRunGetAttributes(run) as NSDictionary
    guard let value = attributes[kCTFontAttributeName], CFGetTypeID(value as CFTypeRef) == CTFontGetTypeID() else { return false }
    return CTFontCopyPostScriptName(value as! CTFont) as String == "AppleColorEmoji"
  }

  static func systemHasSymbol(_ name: String) -> Bool {
    NSImage(systemSymbolName: name, accessibilityDescription: nil) != nil
  }
}
