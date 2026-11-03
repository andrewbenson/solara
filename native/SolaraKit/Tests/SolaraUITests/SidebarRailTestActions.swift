import AppKit

@MainActor
func sendSidebarRailButtonAction(_ button: NSButton?) -> Bool {
  guard let button, let action = button.action, let target = button.target else { return false }
  return button.sendAction(action, to: target)
}
