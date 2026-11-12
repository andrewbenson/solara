public enum TabNumberShortcut {
  public static func formatted(key: String, modifiers: [String]) -> String? {
    guard let scalar = key.unicodeScalars.first else { return nil }
    let glyphs: [String: String] = [
      "\t": "⇥", "\r": "↩", "\u{3}": "⌤", "\u{8}": "⌫", "\u{7f}": "⌫", "\u{F728}": "⌦",
      "\u{1b}": "⎋", " ": "Space", "\u{F700}": "↑", "\u{F701}": "↓", "\u{F702}": "←", "\u{F703}": "→",
      "\u{F729}": "↖", "\u{F72B}": "↘", "\u{F72C}": "⇞", "\u{F72D}": "⇟",
    ]
    let name: String
    if let glyph = glyphs[key] {
      name = glyph
    } else if (0xF704...0xF717).contains(scalar.value) {
      name = "F\(scalar.value - 0xF704 + 1)"
    } else {
      name = key.uppercased()
    }
    let order = [("control", "⌃"), ("option", "⌥"), ("shift", "⇧"), ("command", "⌘"), ("function", "🌐")]
    return order.filter { modifiers.contains($0.0) }.map(\.1).joined() + name
  }
}
