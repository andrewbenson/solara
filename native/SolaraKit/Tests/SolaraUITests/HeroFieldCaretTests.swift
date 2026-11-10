import AppKit
import SolaraModel
import Testing
@testable import SolaraUI

struct HeroFieldCaretTests {
  @Test(arguments: [BarVariant.panel, .sidebar], ["dashboard", String(repeating: "segment/", count: 14) + "end?query=" + String(repeating: "x", count: 40)])
  @MainActor func typingInsideAnAddressKeepsTheCaretAfterTheInsertedCharacter(_ variant: BarVariant, _ path: String) throws {
    NSApplication.shared.setActivationPolicy(.prohibited)
    let text = "https://url-focus.test/" + path
    let expected = "https://url-Xfocus.test/" + path
    let model = HeroBarModel(
      windowId: "caret-window", tabId: "caret-tab", profileId: "caret-profile", incognito: false,
      settings: { Settings(values: [:]) }, sources: NewTabSources(), variant: variant, initialText: text, currentUrl: text)
    let coordinator = HeroFieldCoordinator(model: model)
    let window = NSWindow(contentRect: CGRect(x: 0, y: 0, width: 600, height: 100), styleMask: [.titled], backing: .buffered, defer: false)
    window.isReleasedWhenClosed = false
    defer { withExtendedLifetime(coordinator) { window.close() } }
    let field = HeroTextField(frame: CGRect(x: 20, y: 30, width: 300, height: 24))
    field.model = model
    field.isBezeled = false
    field.isBordered = false
    field.drawsBackground = false
    field.focusRingType = .none
    field.usesSingleLineMode = true
    field.cell?.wraps = false
    field.cell?.isScrollable = true
    field.lineBreakMode = .byClipping
    field.font = .systemFont(ofSize: 14)
    field.delegate = coordinator
    coordinator.field = field
    field.onSelectionChange = { [weak coordinator] in coordinator?.selectionDidChange() }
    model.field = coordinator
    field.stringValue = model.value
    window.contentView?.addSubview(field)
    model.focusOnce()
    let editor = try #require(field.currentEditor() as? NSTextView)
    #expect(editor.delegate === field)
    editor.selectedRange = NSRange(location: 12, length: 0)

    editor.insertText("X", replacementRange: editor.selectedRange)

    #expect(model.typed == expected)
    #expect(editor.string == expected)
    #expect(editor.selectedRange == NSRange(location: 13, length: 0))
    #expect(model.selection == .caret(13))
  }
}
