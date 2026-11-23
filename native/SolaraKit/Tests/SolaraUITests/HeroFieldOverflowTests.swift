import AppKit
import Testing
@testable import SolaraUI

struct HeroFieldOverflowTests {
  private static let short = "https://url-focus.test/dashboard"
  private static let long = "https://url-focus.test/" + String(repeating: "segment/", count: 14) + "end?query=" + String(repeating: "x", count: 40)

  @MainActor private func editingField(_ text: String, clipInsets: NSEdgeInsets? = nil) throws -> (NSWindow, NSTextField, NSTextView, NSClipView) {
    NSApplication.shared.setActivationPolicy(.prohibited)
    let window = NSWindow(contentRect: CGRect(x: 0, y: 0, width: 600, height: 100), styleMask: [.titled], backing: .buffered, defer: false)
    window.isReleasedWhenClosed = false
    let field = NSTextField(frame: CGRect(x: 20, y: 30, width: 300, height: 24))
    field.isBezeled = false
    field.isBordered = false
    field.drawsBackground = false
    field.focusRingType = .none
    field.usesSingleLineMode = true
    field.cell?.wraps = false
    field.cell?.isScrollable = true
    field.lineBreakMode = .byClipping
    field.font = .systemFont(ofSize: 17)
    field.stringValue = text
    window.contentView?.addSubview(field)
    window.makeFirstResponder(field)
    let editor = try #require(field.currentEditor() as? NSTextView)
    let clip = try #require(editor.superview as? NSClipView)
    if let clipInsets {
      clip.automaticallyAdjustsContentInsets = false
      clip.contentInsets = clipInsets
    }
    editor.selectedRange = NSRange(location: 0, length: (text as NSString).length)
    HeroFieldCoordinator.scrollToStart(clip)
    return (window, field, editor, clip)
  }

  @MainActor private func textLeft(_ field: NSTextField, _ editor: NSTextView) throws -> CGFloat {
    let layout = try #require(editor.layoutManager)
    let container = try #require(editor.textContainer)
    let glyph = layout.boundingRect(forGlyphRange: NSRange(location: 0, length: 1), in: container)
    return field.convert(NSPoint(x: glyph.minX + editor.textContainerOrigin.x, y: 0), from: editor).x
  }

  @MainActor private func restingLeft(_ field: NSTextField, _ editor: NSTextView) throws -> CGFloat {
    let cell = try #require(field.cell)
    let container = try #require(editor.textContainer)
    return cell.drawingRect(forBounds: field.bounds).minX + container.lineFragmentPadding
  }

  @Test @MainActor func measuringTheInsetKeepsTheFieldEditorOnTextKit2AndItsSelectionInRange() throws {
    for text in [Self.short, Self.long] {
      let (window, _, editor, clip) = try editingField(text)
      defer { window.close() }
      #expect(editor.textLayoutManager != nil, "scrollToStart must not switch the field editor to TextKit 1")
      editor.string = "ab"
      editor.selectedRange = NSRange(location: 0, length: 2)
      HeroFieldCoordinator.scrollToStart(clip)
      #expect(editor.textLayoutManager != nil)
      window.contentView?.layoutSubtreeIfNeeded()
      #expect(NSMaxRange(editor.selectedRange) <= (editor.string as NSString).length)
    }
  }

  @Test @MainActor func theTextKit2InsetMatchesTheTextKit1Inset() throws {
    for size in [13, 17] as [CGFloat] {
      for left in [0, 2.5] as [CGFloat] {
        let (window2, _, editor2, clip2) = try editingField(Self.long, clipInsets: NSEdgeInsets(top: 0, left: left, bottom: 0, right: 0))
        defer { window2.close() }
        editor2.font = .systemFont(ofSize: size)
        let container2 = try #require(editor2.textContainer)
        let glyph2 = try #require(HeroFieldCoordinator.firstGlyphLeft(editor2, in: container2))
        let inset2 = HeroFieldCoordinator.overflowTextInset(editor2, in: clip2)
        #expect(editor2.textLayoutManager != nil)
        let (window1, _, editor1, clip1) = try editingField(Self.long, clipInsets: NSEdgeInsets(top: 0, left: left, bottom: 0, right: 0))
        defer { window1.close() }
        editor1.font = .systemFont(ofSize: size)
        _ = editor1.layoutManager
        #expect(editor1.textLayoutManager == nil, "the control editor runs on TextKit 1")
        let container1 = try #require(editor1.textContainer)
        let glyph1 = try #require(HeroFieldCoordinator.firstGlyphLeft(editor1, in: container1))
        let inset1 = HeroFieldCoordinator.overflowTextInset(editor1, in: clip1)
        let scale = window2.backingScaleFactor
        #expect(abs(glyph2 - glyph1) <= 0.01, "first glyph at \(size) pt, clip left \(left), scale \(scale): TextKit 2 \(glyph2), TextKit 1 \(glyph1)")
        #expect(inset2 == inset1, "inset at \(size) pt, clip left \(left), scale \(scale): TextKit 2 \(inset2), TextKit 1 \(inset1)")
      }
    }
  }

  @Test @MainActor func aShortURLNeedsNoInset() throws {
    let (window, field, editor, _) = try editingField(Self.short)
    defer { window.close() }
    #expect(editor.textContainerInset.width == 0)
    #expect(abs(try textLeft(field, editor) - restingLeft(field, editor)) <= 0.5)
  }

  @Test @MainActor func anOverflowingURLStartsWhereItRests() throws {
    let (window, field, editor, clip) = try editingField(Self.long)
    defer { window.close() }
    #expect(editor.frame.width > clip.bounds.width)
    #expect(abs(try textLeft(field, editor) - restingLeft(field, editor)) <= 0.5)
  }

  @Test @MainActor func theInsetFollowsTheClipViewsOwnInsets() throws {
    for left in [0, 2.5, 4] as [CGFloat] {
      let (window, field, editor, clip) = try editingField(Self.long, clipInsets: NSEdgeInsets(top: 2, left: left, bottom: 4, right: 1.5))
      defer { window.close() }
      #expect(editor.frame.width > clip.bounds.width)
      #expect(abs(try textLeft(field, editor) - restingLeft(field, editor)) <= 0.5, "clip left inset \(left)")
    }
  }
}
