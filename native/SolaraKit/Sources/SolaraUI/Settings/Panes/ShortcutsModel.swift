import AppKit
import Foundation
import SolaraModel

public enum ShortcutModifier: String, CaseIterable, Hashable, Sendable {
  case control
  case option
  case shift
  case command
  case function

  var glyph: String {
    switch self {
    case .control: "⌃"
    case .option: "⌥"
    case .shift: "⇧"
    case .command: "⌘"
    case .function: "🌐"
    }
  }

  static func ordered(_ names: some Sequence<ShortcutModifier>) -> [ShortcutModifier] {
    let set = Set(names)
    return allCases.filter { set.contains($0) }
  }
}

public struct KeyShortcut: Hashable, Sendable {
  public var key: String
  public var modifiers: [ShortcutModifier]

  public init(key: String, modifiers: [ShortcutModifier]) {
    self.key = key
    self.modifiers = modifiers
  }

  public static let empty = KeyShortcut(key: "", modifiers: [])

  static let keyGlyphs: [String: String] = [
    "\t": "⇥",
    "\r": "↩",
    "\u{3}": "⌤",
    "\u{8}": "⌫",
    "\u{7f}": "⌫",
    "\u{F728}": "⌦",
    "\u{1b}": "⎋",
    " ": "Space",
    "\u{F700}": "↑",
    "\u{F701}": "↓",
    "\u{F702}": "←",
    "\u{F703}": "→",
    "\u{F729}": "↖",
    "\u{F72B}": "↘",
    "\u{F72C}": "⇞",
    "\u{F72D}": "⇟",
  ]
  static let firstFunctionKey: UInt32 = 0xF704
  static let lastFunctionKey: UInt32 = 0xF717

  public var formatted: String {
    guard let scalar = key.unicodeScalars.first else { return "" }
    let name: String
    if let glyph = Self.keyGlyphs[key] {
      name = glyph
    } else if (Self.firstFunctionKey...Self.lastFunctionKey).contains(scalar.value) {
      name = "F\(scalar.value - Self.firstFunctionKey + 1)"
    } else {
      name = key.uppercased()
    }
    return ShortcutModifier.ordered(modifiers).map(\.glyph).joined() + name
  }

  public var comboKey: String {
    let shifted: [ShortcutModifier] = key != key.lowercased() ? [.shift] : []
    return ShortcutModifier.ordered(modifiers + shifted).map(\.rawValue).joined(separator: "+") + "|" + key.lowercased()
  }

  public func same(as other: KeyShortcut) -> Bool { comboKey == other.comboKey }

  public init(stored: [String]) {
    let first = stored.first ?? ""
    let names = stored.dropFirst().compactMap(ShortcutModifier.init(rawValue:))
    let shifted = first.count == 1 && first != first.lowercased()
    key = shifted ? first.lowercased() : first
    modifiers = ShortcutModifier.ordered(shifted ? names + [.shift] : names)
  }

  public var stored: [String] { [key] + ShortcutModifier.ordered(modifiers).map(\.rawValue) }
}

public enum ShortcutPrecedence: String, CaseIterable, Hashable, Sendable {
  case solara
  case website
  case both

  func title(app: String) -> String {
    switch self {
    case .solara: "Prefer \(app.isEmpty ? "Solara" : app)"
    case .website: "Prefer Website"
    case .both: "Use Both"
    }
  }

  func help(app: String) -> String {
    let name = app.isEmpty ? "Solara" : app
    switch self {
    case .solara: return "\(name) acts on this shortcut before the website sees it."
    case .website: return "The website gets this shortcut first; \(name) acts only when the website doesn't use it."
    case .both: return "The website gets the first press; press twice quickly for \(name)."
    }
  }

  static func fixedHelp(app: String) -> String {
    "\(app.isEmpty ? "Solara" : app) always acts on this shortcut first, as Chrome does."
  }
}

public struct MenuShortcutItem: Hashable, Sendable, Identifiable {
  public let id: String
  public let title: String
  public let path: [String]
  public let defaultShortcut: KeyShortcut
  public let remappable: Bool
  public let aliases: [[String]]
  public let defaultPrecedence: ShortcutPrecedence?
  public let precedenceFixed: Bool

  public init(
    id: String, title: String, path: [String], defaultShortcut: KeyShortcut, remappable: Bool, aliases: [[String]] = [],
    defaultPrecedence: ShortcutPrecedence? = nil, precedenceFixed: Bool = false
  ) {
    self.id = id
    self.title = title
    self.path = path
    self.defaultShortcut = defaultShortcut
    self.remappable = remappable
    self.aliases = aliases
    self.defaultPrecedence = defaultPrecedence
    self.precedenceFixed = precedenceFixed
  }

  var menu: String { path.first ?? "" }
}

public typealias ShortcutOverrides = [String: [String]]
public typealias ShortcutPrecedences = [String: ShortcutPrecedence]

struct ShortcutSource {
  let id: String
  let keys: [KeyShortcut]
  let fixed: Bool

  init(_ item: MenuShortcutItem) {
    id = item.id
    keys = [item.defaultShortcut] + item.aliases.map(KeyShortcut.init(stored:))
    fixed = !item.remappable
  }

  init(id: String, keys: [KeyShortcut], fixed: Bool = false) {
    self.id = id
    self.keys = keys
    self.fixed = fixed
  }
}

struct ResolvedShortcuts {
  let bindings: [String: [KeyShortcut]]
  let holders: [String: [String]]

  init(_ sources: [ShortcutSource], overrides: ShortcutOverrides) {
    let rebindable = Set(sources.filter { !$0.fixed }.map(\.id))
    var taken = Set<String>()
    for (id, stored) in overrides where rebindable.contains(id) && !(stored.first ?? "").isEmpty {
      taken.insert(KeyShortcut(stored: stored).comboKey)
    }
    var bindings: [String: [KeyShortcut]] = [:]
    var holders: [String: [String]] = [:]
    for source in sources {
      let stored = source.fixed ? nil : overrides[source.id]
      let candidates = stored.map { [KeyShortcut(stored: $0)] } ?? source.keys.filter { source.fixed || !taken.contains($0.comboKey) }
      var seen: [String] = []
      var keys: [KeyShortcut] = []
      for candidate in candidates where !candidate.key.isEmpty && !seen.contains(candidate.comboKey) {
        seen.append(candidate.comboKey)
        keys.append(candidate)
      }
      bindings[source.id] = keys
      for combo in seen { holders[combo, default: []].append(source.id) }
    }
    self.bindings = bindings
    self.holders = holders
  }

  func effective(_ id: String) -> KeyShortcut { bindings[id]?.first ?? .empty }

  func holders(of shortcut: KeyShortcut) -> [String] { holders[shortcut.comboKey] ?? [] }

  func conflicts(of id: String) -> [String] {
    var result: [String] = []
    for key in bindings[id] ?? [] {
      for other in holders[key.comboKey] ?? [] where other != id && !result.contains(other) {
        result.append(other)
      }
    }
    return result
  }
}

enum ShortcutQuery {
  static func matches(_ query: String, _ fields: String...) -> Bool {
    let words = query.lowercased().split(whereSeparator: \.isWhitespace)
    guard !words.isEmpty else { return true }
    let hay = fields.joined(separator: " ").lowercased()
    return words.allSatisfy { hay.contains($0) }
  }
}

enum ShortcutKeyOutcome: Equatable, Sendable {
  case cancel
  case cancelAndPass
  case reject
  case ignore
  case record(KeyShortcut)
}

enum ShortcutKeyReader {
  static let escapeKeyCode: UInt16 = 53
  static let recordableFunctionKeys: ClosedRange<UInt32> = 0xF704...0xF726

  static func outcome(keyCode: UInt16, flags: NSEvent.ModifierFlags, characters: String?) -> ShortcutKeyOutcome {
    let flags = flags.intersection([.command, .option, .control, .shift, .function])
    if keyCode == escapeKeyCode, flags.subtracting(.function).isEmpty { return .cancel }
    let key = (characters ?? "").lowercased()
    guard let scalar = key.unicodeScalars.first else { return .ignore }
    let functionKey = recordableFunctionKeys.contains(scalar.value)
    guard flags.contains(.command) || flags.contains(.control) || functionKey else { return .reject }
    var modifiers: [ShortcutModifier] = []
    if flags.contains(.control) { modifiers.append(.control) }
    if flags.contains(.option) { modifiers.append(.option) }
    if flags.contains(.shift) { modifiers.append(.shift) }
    if flags.contains(.command) { modifiers.append(.command) }
    if flags.contains(.function), scalar.value < 0xF700 { modifiers.append(.function) }
    return .record(KeyShortcut(key: key, modifiers: modifiers))
  }

  static func outcome(_ event: NSEvent) -> ShortcutKeyOutcome {
    guard event.type == .keyDown else { return .cancelAndPass }
    return outcome(keyCode: event.keyCode, flags: event.modifierFlags, characters: event.characters(byApplyingModifiers: []) ?? event.charactersIgnoringModifiers)
  }
}

@MainActor
public protocol ShortcutRecording: AnyObject {
  func record() async -> KeyShortcut?
  func cancel()
}

@MainActor
public final class ShortcutKeyRecorder: ShortcutRecording {
  private var monitor: Any?
  private var pending: CheckedContinuation<KeyShortcut?, Never>?

  public init() {}

  public func record() async -> KeyShortcut? {
    finish(nil)
    return await withCheckedContinuation { continuation in
      pending = continuation
      monitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown, .leftMouseDown, .rightMouseDown]) { [weak self] event in
        let outcome = ShortcutKeyReader.outcome(event)
        let passes = MainActor.assumeIsolated { self?.apply(outcome) ?? true }
        return passes ? event : nil
      }
    }
  }

  public func cancel() { finish(nil) }

  private func apply(_ outcome: ShortcutKeyOutcome) -> Bool {
    switch outcome {
    case .cancelAndPass:
      finish(nil)
      return true
    case .cancel:
      finish(nil)
      return false
    case .reject:
      NSSound.beep()
      return false
    case .ignore:
      return false
    case .record(let shortcut):
      finish(shortcut)
      return false
    }
  }

  private func finish(_ result: KeyShortcut?) {
    if let monitor { NSEvent.removeMonitor(monitor) }
    monitor = nil
    let continuation = pending
    pending = nil
    continuation?.resume(returning: result)
  }
}
