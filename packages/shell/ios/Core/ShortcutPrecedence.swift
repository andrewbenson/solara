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
    "selectTab", "selectLastTab", "nextProfile", "previousProfile", "switchProfile",
  ])
  public static let sharedWithWebsiteCommands: Set<String> = [
    "toggleSidebar", "findInPage", "findNext", "findPrevious", "useSelectionForFind", "jumpToSelection", "focusCommandBar",
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
