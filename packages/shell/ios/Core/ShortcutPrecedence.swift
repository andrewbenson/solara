import Foundation

public enum ShortcutPrecedence: String, CaseIterable, Sendable {
  case solara
  case website
  case both

  public static let alwaysSolaraCommands: Set<String> = [
    "newTab", "reopenClosedTab", "closeTab", "newWindow", "newIncognitoWindow", "tabSwitcher", "nextTab", "previousTab",
  ]
  public static let alwaysSolaraStandardShortcuts: Set<String> = ["std:closeWindow:", "std:quit:"]
  public static let solaraFirstCommands: Set<String> = alwaysSolaraCommands.union([
    "selectTab", "selectLastTab", "nextProfile", "previousProfile", "switchProfile", "focusCommandBar",
  ])
  public static let sharedWithWebsiteCommands: Set<String> = [
    "toggleSidebar", "findInPage", "findNext", "findPrevious", "useSelectionForFind", "jumpToSelection",
    "togglePinnedRow",
  ]

  public static func isFixed(shortcutId: String, command: String?) -> Bool {
    guard let command else { return alwaysSolaraStandardShortcuts.contains(shortcutId) }
    return alwaysSolaraCommands.contains(command)
  }

  public static func standard(shortcutId: String, command: String?) -> ShortcutPrecedence {
    guard let command else { return alwaysSolaraStandardShortcuts.contains(shortcutId) ? .solara : .website }
    if solaraFirstCommands.contains(command) { return .solara }
    if sharedWithWebsiteCommands.contains(command) { return .both }
    return .website
  }

  public static func resolve(shortcutId: String, command: String?, chosen: [String: String]) -> ShortcutPrecedence {
    if isFixed(shortcutId: shortcutId, command: command) { return .solara }
    return chosen[shortcutId].flatMap(ShortcutPrecedence.init(rawValue:)) ?? standard(shortcutId: shortcutId, command: command)
  }
}

public enum BackTabShortcut {
  public struct Modifiers: OptionSet, Sendable, Hashable {
    public let rawValue: Int
    public init(rawValue: Int) { self.rawValue = rawValue }
    public static let control = Modifiers(rawValue: 1)
    public static let option = Modifiers(rawValue: 2)
    public static let command = Modifiers(rawValue: 4)
    public static let shift = Modifiers(rawValue: 8)
  }

  public struct Binding: Sendable, Equatable {
    public let key: String
    public let modifiers: Modifiers
    public let enabled: Bool
    public init(key: String, modifiers: Modifiers, enabled: Bool) {
      self.key = key
      self.modifiers = modifiers
      self.enabled = enabled
    }
  }

  public struct Context: Sendable, Equatable {
    public var browserKeyWindow: Bool
    public var attachedSheet: Bool
    public var modal: Bool
    public var markedText: Bool
    public init(browserKeyWindow: Bool, attachedSheet: Bool, modal: Bool, markedText: Bool) {
      self.browserKeyWindow = browserKeyWindow
      self.attachedSheet = attachedSheet
      self.modal = modal
      self.markedText = markedText
    }
  }

  public static func binding(for modifiers: Modifiers, in context: Context, among bindings: [Binding]) -> Int? {
    guard context.browserKeyWindow, !context.attachedSheet, !context.modal, !context.markedText else { return nil }
    guard !modifiers.isDisjoint(with: [.control, .option, .command]) else { return nil }
    return bindings.firstIndex { $0.key == "\t" && $0.modifiers == modifiers && $0.enabled }
  }
}
