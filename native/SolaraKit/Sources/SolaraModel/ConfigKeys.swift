import Foundation

public struct ConfigKeyFailure: Error, Sendable, Equatable {
  public let message: String
}

public enum ConfigKeys {
  static let modifierOrder = ["control", "option", "shift", "command", "function"]

  static let modifierNames: [String: String] = [
    "cmd": "command", "command": "command", "⌘": "command", "super": "command", "meta": "command",
    "ctrl": "control", "control": "control", "⌃": "control",
    "alt": "option", "opt": "option", "option": "option", "⌥": "option",
    "shift": "shift", "⇧": "shift",
    "fn": "function", "function": "function", "🌐": "function",
  ]

  static let glyphModifiers: [Character: String] = ["⌘": "command", "⌃": "control", "⌥": "option", "⇧": "shift"]

  static let namedKeys: [String: String] = [
    "tab": "\t", "⇥": "\t",
    "return": "\r", "enter": "\r", "↩": "\r",
    "space": " ",
    "delete": "\u{7f}", "backspace": "\u{7f}", "⌫": "\u{7f}",
    "forwarddelete": "\u{F728}", "⌦": "\u{F728}",
    "escape": "\u{1b}", "esc": "\u{1b}", "⎋": "\u{1b}",
    "up": "\u{F700}", "↑": "\u{F700}",
    "down": "\u{F701}", "↓": "\u{F701}",
    "left": "\u{F702}", "←": "\u{F702}",
    "right": "\u{F703}", "→": "\u{F703}",
    "home": "\u{F729}", "↖": "\u{F729}",
    "end": "\u{F72B}", "↘": "\u{F72B}",
    "pageup": "\u{F72C}", "⇞": "\u{F72C}",
    "pagedown": "\u{F72D}", "⇟": "\u{F72D}",
    "plus": "+", "minus": "-",
  ]

  static let firstFunctionKey: UInt32 = 0xF704

  public static func parse(_ value: JSONValue) -> Result<[String], ConfigKeyFailure> {
    if value.isNull { return .success([""]) }
    if let items = value.array {
      guard let first = items.first?.string, items.allSatisfy({ $0.string != nil }) else {
        return .failure(ConfigKeyFailure(message: "expected keys like \"cmd+shift+t\" or \"⇧⌘T\", or \"\" for no shortcut"))
      }
      let mods = items.dropFirst().compactMap(\.string)
      for mod in mods where !modifierOrder.contains(mod) {
        return .failure(ConfigKeyFailure(message: "\"\(mod)\" isn't a modifier; use command, control, option, shift or function"))
      }
      return checked(key: first, modifiers: Set(mods))
    }
    guard let text = value.string else {
      return .failure(ConfigKeyFailure(message: "expected keys like \"cmd+shift+t\" or \"⇧⌘T\", or \"\" for no shortcut"))
    }
    return parse(text)
  }

  public static func parse(_ raw: String) -> Result<[String], ConfigKeyFailure> {
    let text = raw.trimmingCharacters(in: .whitespaces)
    if text.isEmpty || text.lowercased() == "none" { return .success([""]) }
    var modifiers = Set<String>()
    var rest = Substring(text)
    while let first = rest.first, let name = glyphModifiers[first], rest.count > 1 {
      modifiers.insert(name)
      rest = rest.dropFirst()
    }
    let parts = splitPlus(String(rest))
    guard let last = parts.last, !last.isEmpty else {
      return .failure(ConfigKeyFailure(message: "\"\(raw)\" has no key after its modifiers"))
    }
    for part in parts.dropLast() {
      guard let name = modifierNames[part.lowercased()] else {
        return .failure(ConfigKeyFailure(message: "\"\(part)\" isn't a modifier; use cmd, ctrl, alt (option), shift or fn"))
      }
      modifiers.insert(name)
    }
    guard let key = keyCharacter(last) else {
      return .failure(ConfigKeyFailure(message: "\"\(last)\" isn't a key; use a single character, F1–F20, or a name like tab, return, space, left"))
    }
    return checked(key: key, modifiers: modifiers)
  }

  static func splitPlus(_ text: String) -> [String] {
    if text == "+" { return ["+"] }
    var parts: [String] = []
    var current = ""
    for char in text {
      if char == "+" && !current.isEmpty {
        parts.append(current)
        current = ""
      } else {
        current.append(char)
      }
    }
    parts.append(current)
    return parts.map { $0.trimmingCharacters(in: .whitespaces) }
  }

  static func keyCharacter(_ name: String) -> String? {
    let lower = name.lowercased()
    if let named = namedKeys[lower] ?? namedKeys[name] { return named }
    if lower.hasPrefix("f"), let number = UInt32(lower.dropFirst()), (1...20).contains(number) {
      return String(UnicodeScalar(firstFunctionKey + number - 1)!)
    }
    guard name.count == 1 else { return nil }
    return lower
  }

  static func checked(key: String, modifiers: Set<String>) -> Result<[String], ConfigKeyFailure> {
    if key.isEmpty { return .success([""]) }
    let functionKey = key.unicodeScalars.first.map { (0xF704...0xF726).contains($0.value) } ?? false
    guard modifiers.contains("command") || modifiers.contains("control") || functionKey else {
      return .failure(ConfigKeyFailure(message: "a shortcut needs cmd or ctrl, unless it's a function key like F5"))
    }
    return .success([key] + modifierOrder.filter(modifiers.contains))
  }
}
