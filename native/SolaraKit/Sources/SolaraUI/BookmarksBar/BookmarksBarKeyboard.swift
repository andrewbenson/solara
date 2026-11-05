import AppKit

enum BookmarksBarKeyboard {
  enum Kind {
    case link, folder, overflow, other, importButton
  }

  enum Action: Equatable {
    case previous, next, first, last
    case press(NSEvent.ModifierFlags)
    case menu, contextMenu, page, unhandled
  }

  static func action(key: String, modifiers: NSEvent.ModifierFlags, kind: Kind) -> Action {
    let modifiers = modifiers.intersection([.shift, .control, .option, .command, .help])
    if key == "Return", modifiers == .command, kind == .link { return .press(.command) }
    if key == "F10", modifiers == .shift { return .contextMenu }
    guard modifiers.isEmpty else { return .unhandled }
    switch key {
    case "Left": return .previous
    case "Right": return .next
    case "Home": return .first
    case "End": return .last
    case "Return", "Space": return .press([])
    case "Down": return kind == .folder || kind == .overflow || kind == .other ? .menu : .unhandled
    case "ContextMenu": return .contextMenu
    case "Escape": return .page
    default: return .unhandled
    }
  }

  static func destination(for action: Action, focusedId: String, controlIds: [String]) -> String? {
    guard let index = controlIds.firstIndex(of: focusedId) else { return nil }
    switch action {
    case .previous: return controlIds[max(0, index - 1)]
    case .next: return controlIds[min(controlIds.count - 1, index + 1)]
    case .first: return controlIds.first
    case .last: return controlIds.last
    case .page: return nil
    default: return focusedId
    }
  }

  static func repairedFocus(focusedId: String?, previousIds: [String], controlIds: [String]) -> String? {
    guard let focusedId else { return nil }
    if controlIds.contains(focusedId) { return focusedId }
    guard let index = previousIds.firstIndex(of: focusedId), !controlIds.isEmpty else { return nil }
    return controlIds[min(index, controlIds.count - 1)]
  }

  static func acceptsFocus(fullKeyboardAccess: Bool, visible: Bool) -> Bool {
    fullKeyboardAccess && visible
  }
}
