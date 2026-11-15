import AppKit

@MainActor
struct SidebarRetirementPicture {
  let view: NSImageView
  let item: SidebarItem
}

final class SidebarLogicalElement: NSAccessibilityElement {
  private let readLabel: @MainActor @Sendable () -> String?
  private let readFrame: @MainActor @Sendable () -> CGRect
  private let perform: @MainActor @Sendable (String) -> Bool

  @MainActor
  init(owner: SidebarView, key: String) {
    readLabel = { [weak owner] in owner?.logicalLabel(key) }
    readFrame = { [weak owner] in owner?.logicalAccessibilityFrame(key) ?? .zero }
    perform = { [weak owner] action in owner?.performLogicalAction(key, action: action) ?? false }
    super.init()
    setAccessibilityParent(owner)
    setAccessibilityElement(true)
    setAccessibilityRole(.button)
  }

  override func accessibilityLabel() -> String? { MainActor.assumeIsolated(readLabel) }
  override func accessibilityFrame() -> NSRect { MainActor.assumeIsolated(readFrame) }
  override func accessibilityPerformPress() -> Bool {
    let action = perform
    return MainActor.assumeIsolated { action("press") }
  }
  override func accessibilityPerformShowMenu() -> Bool {
    let action = perform
    return MainActor.assumeIsolated { action("menu") }
  }
  override func setAccessibilityFocused(_ focused: Bool) {
    let action = perform
    MainActor.assumeIsolated { if focused { _ = action("focus") } }
  }
}
