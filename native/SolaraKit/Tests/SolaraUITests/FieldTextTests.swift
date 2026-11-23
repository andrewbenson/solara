import AppKit
import SolaraModel
import Testing
@testable import SolaraUI

@MainActor
struct FieldTextTests {
  static let long = String(repeating: "solara field text ", count: 12)

  func editingField(_ text: String = long) throws -> (NSWindow, NSTextField, NSTextView) {
    NSApplication.shared.setActivationPolicy(.prohibited)
    let window = NSWindow(contentRect: CGRect(x: 0, y: 0, width: 600, height: 100), styleMask: [.titled], backing: .buffered, defer: false)
    window.isReleasedWhenClosed = false
    let field = NSTextField(frame: CGRect(x: 20, y: 30, width: 400, height: 24))
    window.contentView?.addSubview(field)
    field.stringValue = text
    #expect(window.makeFirstResponder(field))
    let editor = try #require(field.currentEditor() as? NSTextView)
    return (window, field, editor)
  }

  func selectionFits(_ editor: NSTextView) -> Bool {
    let length = (editor.string as NSString).length
    return editor.selectedRanges.map(\.rangeValue).allSatisfy { NSMaxRange($0) <= length }
  }

  @Test(arguments: [NSRange(location: 216, length: 0), NSRange(location: 200, length: 16), NSRange(location: 0, length: 216)])
  func aShorterTextWhileEditingLeavesTheSelectionInsideIt(_ selection: NSRange) throws {
    let (window, field, editor) = try editingField()
    defer { window.close() }
    editor.setSelectedRange(selection)
    FieldText.set(field, "ab")
    #expect(editor.string == "ab")
    #expect(field.currentEditor() === editor)
    #expect(selectionFits(editor))
    editor.layoutSubtreeIfNeeded()
    #expect(selectionFits(editor))
  }

  @Test func clearingWhileEditingKeepsTheFieldEditingWithAnEmptySelection() throws {
    let (window, field, editor) = try editingField()
    defer { window.close() }
    editor.setSelectedRange(NSRange(location: (Self.long as NSString).length, length: 0))
    FieldText.set(field, "")
    #expect(field.stringValue == "")
    #expect(window.firstResponder === editor)
    #expect(editor.selectedRange == NSRange(location: 0, length: 0))
  }

  @Test func aProgrammaticWriteIsNotUndoable() throws {
    let (window, field, editor) = try editingField("typed")
    defer { window.close() }
    let before = editor.undoManager?.canUndo ?? false
    FieldText.set(field, "replaced")
    #expect((editor.undoManager?.canUndo ?? false) == before)
  }

  @Test func withMarkedTextTheSelectionStillFits() throws {
    let (window, field, editor) = try editingField()
    defer { window.close() }
    let end = (Self.long as NSString).length
    editor.setSelectedRange(NSRange(location: end, length: 0))
    editor.setMarkedText("\u{3042}\u{3044}", selectedRange: NSRange(location: 2, length: 0), replacementRange: NSRange(location: end, length: 0))
    FieldText.set(field, "ab")
    #expect(editor.string == "ab")
    #expect(selectionFits(editor))
  }

  @Test func aFieldThatIsNotEditingTakesTheValueDirectly() {
    let field = NSTextField(frame: .zero)
    field.stringValue = Self.long
    FieldText.set(field, "ab")
    #expect(field.stringValue == "ab")
  }

  @Test(arguments: [BarVariant.panel, .sidebar])
  func theHeroTakesALongThenAShortModelValueWhileEditing(_ variant: BarVariant) throws {
    NSApplication.shared.setActivationPolicy(.prohibited)
    let model = HeroBarModel(
      windowId: "field-text-window", tabId: "field-text-tab", profileId: "field-text-profile", incognito: false,
      settings: { Settings(values: [:]) }, sources: NewTabSources(), variant: variant, initialText: "", currentUrl: "")
    let coordinator = HeroFieldCoordinator(model: model)
    let window = NSWindow(contentRect: CGRect(x: 0, y: 0, width: 600, height: 100), styleMask: [.titled], backing: .buffered, defer: false)
    window.isReleasedWhenClosed = false
    defer { withExtendedLifetime(coordinator) { window.close() } }
    let field = HeroTextField(frame: CGRect(x: 20, y: 30, width: 300, height: 24))
    field.model = model
    field.usesSingleLineMode = true
    field.cell?.isScrollable = true
    field.delegate = coordinator
    coordinator.field = field
    field.onSelectionChange = { [weak coordinator] in coordinator?.selectionDidChange() }
    model.field = coordinator
    window.contentView?.addSubview(field)
    model.focusOnce()
    let editor = try #require(field.currentEditor() as? NSTextView)
    let end = (Self.long as NSString).length
    coordinator.show(value: Self.long, selection: TextSelection(start: end, end: end))
    #expect(editor.selectedRange == NSRange(location: end, length: 0))
    coordinator.show(value: "ab", selection: TextSelection(start: end, end: end))
    #expect(editor.string == "ab")
    #expect(selectionFits(editor))
    #expect(editor.selectedRange == NSRange(location: 2, length: 0))
    field.removeFromSuperview()
    coordinator.show(value: "a", selection: TextSelection(start: 2, end: 2))
    window.contentView?.addSubview(field)
    window.contentView?.layoutSubtreeIfNeeded()
    #expect(selectionFits(editor))
  }
}
