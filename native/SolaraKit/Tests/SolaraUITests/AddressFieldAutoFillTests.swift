import AppKit
import SolaraModel
import Testing
@testable import SolaraUI

@MainActor
@Suite(.serialized) struct AddressFieldAutoFillTests {
  @Test func addressFieldsDeclareURLContent() {
    for field in [HeroTextField(), DeveloperUrlField(), SplitEmptyField()] as [NSTextField] {
      #expect(field.contentType == .URL)
    }
  }

  @Test func urlContentPreservesTheSharedEditorsTextSettings() throws {
    NSApplication.shared.setActivationPolicy(.prohibited)
    let window = makeWindow()
    defer { window.close() }
    let baseline = NSTextField(frame: NSRect(x: 20, y: 20, width: 300, height: 24))
    let fields = [HeroTextField(), DeveloperUrlField(), SplitEmptyField()] as [NSTextField]
    let hero = try #require(fields.first)
    #expect(hero.isAutomaticTextCompletionEnabled == baseline.isAutomaticTextCompletionEnabled)
    #expect(!fields[1].isAutomaticTextCompletionEnabled)
    for field in [baseline] + fields {
      configure(field)
      window.contentView?.addSubview(field)
    }
    #expect(window.makeFirstResponder(baseline))
    let editor = try #require(baseline.currentEditor() as? NSTextView)
    let originalSettings = editorSettings(editor)
    defer {
      editor.isContinuousSpellCheckingEnabled = originalSettings[0]
      editor.isAutomaticSpellingCorrectionEnabled = originalSettings[1]
      editor.isAutomaticTextCompletionEnabled = originalSettings[2]
    }
    for enabled in [false, true] {
      baseline.isAutomaticTextCompletionEnabled = enabled
      for address in fields {
        address.isAutomaticTextCompletionEnabled = enabled
        #expect(window.makeFirstResponder(baseline))
        #expect(editor.contentType == nil)
        editor.isContinuousSpellCheckingEnabled = enabled
        editor.isAutomaticSpellingCorrectionEnabled = enabled
        editor.isAutomaticTextCompletionEnabled = enabled
        #expect(window.makeFirstResponder(address))
        #expect(address.currentEditor() === editor)
        #expect(editor.contentType == .URL)
        #expect(editorSettings(editor) == [enabled, enabled, enabled])
        #expect(window.makeFirstResponder(baseline))
        #expect(baseline.currentEditor() === editor)
        #expect(editor.contentType == nil)
        #expect(editorSettings(editor) == [enabled, enabled, enabled])
      }
    }
  }

  @Test(arguments: [BarVariant.hero, .panel, .sidebar])
  func heroEditorPreservesMarkedText(_ variant: BarVariant) throws {
    NSApplication.shared.setActivationPolicy(.prohibited)
    let model = HeroBarModel(windowId: "autofill-window", tabId: "autofill-tab", profileId: "autofill-profile", incognito: false, settings: { Settings(values: [:]) }, sources: NewTabSources(), variant: variant)
    let coordinator = HeroFieldCoordinator(model: model)
    let window = makeWindow()
    defer { withExtendedLifetime(coordinator) { window.close() } }
    let field = HeroTextField(frame: NSRect(x: 20, y: 30, width: 300, height: 24))
    field.model = model
    field.delegate = coordinator
    configure(field)
    coordinator.field = field
    model.field = coordinator
    window.contentView?.addSubview(field)
    model.focusOnce()
    let editor = try #require(field.currentEditor() as? NSTextView)
    #expect(editor.contentType == .URL)
    let settings = editorSettings(editor)
    editor.setMarkedText("に", selectedRange: NSRange(location: 1, length: 0), replacementRange: NSRange(location: NSNotFound, length: 0))
    #expect(editor.hasMarkedText())
    #expect(editor.string == "に")
    #expect(!coordinator.control(field, textView: editor, doCommandBy: #selector(NSResponder.insertNewline(_:))))
    #expect(!coordinator.control(field, textView: editor, doCommandBy: #selector(NSResponder.cancelOperation(_:))))
    editor.insertText("日本", replacementRange: editor.markedRange())
    #expect(!editor.hasMarkedText())
    #expect(editor.string == "日本")
    #expect(model.typed == "日本")
    #expect(editor.contentType == .URL)
    #expect(editor.selectedRange == NSRange(location: 2, length: 0))
    #expect(editorSettings(editor) == settings)
  }

  @Test func otherAddressEditorsPreserveMarkedText() throws {
    NSApplication.shared.setActivationPolicy(.prohibited)
    for field in [DeveloperUrlField(), SplitEmptyField()] as [NSTextField] {
      let window = makeWindow()
      defer { window.close() }
      configure(field)
      window.contentView?.addSubview(field)
      #expect(window.makeFirstResponder(field))
      let editor = try #require(field.currentEditor() as? NSTextView)
      #expect(editor.contentType == .URL)
      let settings = editorSettings(editor)
      editor.setMarkedText("に", selectedRange: NSRange(location: 1, length: 0), replacementRange: NSRange(location: NSNotFound, length: 0))
      #expect(editor.hasMarkedText())
      if let developer = field as? DeveloperUrlField {
        #expect(!developer.control(field, textView: editor, doCommandBy: #selector(NSResponder.insertNewline(_:))))
        #expect(!developer.control(field, textView: editor, doCommandBy: #selector(NSResponder.cancelOperation(_:))))
        #expect(!developer.finished)
      }
      editor.insertText("日本", replacementRange: editor.markedRange())
      #expect(!editor.hasMarkedText())
      #expect(editor.string == "日本")
      #expect(field.stringValue == "日本")
      #expect(editor.contentType == .URL)
      #expect(editor.selectedRange == NSRange(location: 2, length: 0))
      #expect(editorSettings(editor) == settings)
    }
  }

  private func makeWindow() -> NSWindow {
    let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 500, height: 140), styleMask: [.titled], backing: .buffered, defer: false)
    window.isReleasedWhenClosed = false
    return window
  }

  private func configure(_ field: NSTextField) {
    field.frame = NSRect(x: 20, y: 30, width: 300, height: 24)
    field.usesSingleLineMode = true
    field.isBezeled = false
    field.isBordered = false
    field.cell?.isScrollable = true
  }

  private func editorSettings(_ editor: NSTextView) -> [Bool] {
    [editor.isContinuousSpellCheckingEnabled, editor.isAutomaticSpellingCorrectionEnabled, editor.isAutomaticTextCompletionEnabled]
  }
}
