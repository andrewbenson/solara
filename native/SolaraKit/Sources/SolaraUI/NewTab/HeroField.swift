import AppKit
import SwiftUI

final class HeroTextField: NSTextField {
  weak var model: HeroBarModel?
  var onSelectionChange: () -> Void = {}
  private weak var observedEditor: NSTextView?
  nonisolated(unsafe) private var selectionObserver: NSObjectProtocol?
  var selectionColor: NSColor = .selectedTextBackgroundColor { didSet { styleEditor() } }

  override func becomeFirstResponder() -> Bool {
    let became = super.becomeFirstResponder()
    if became {
      styleEditor()
      observeEditor()
      model?.didFocus()
    }
    return became
  }

  override func performKeyEquivalent(with event: NSEvent) -> Bool {
    guard currentEditor() != nil, window?.firstResponder === currentEditor(), let model else { return super.performKeyEquivalent(with: event) }
    let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
    if event.keyCode == 36 || event.keyCode == 76, flags.contains(.command) || flags.contains(.control) {
      return model.key(HeroKey(.enter, shift: flags.contains(.shift), alt: flags.contains(.option), meta: flags.contains(.command), ctrl: flags.contains(.control)))
    }
    return super.performKeyEquivalent(with: event)
  }

  deinit {
    if let selectionObserver { NotificationCenter.default.removeObserver(selectionObserver) }
  }

  func observeEditor() {
    guard let editor = currentEditor() as? NSTextView, editor !== observedEditor || selectionObserver == nil else { return }
    if let selectionObserver { NotificationCenter.default.removeObserver(selectionObserver) }
    observedEditor = editor
    selectionObserver = NotificationCenter.default.addObserver(forName: NSTextView.didChangeSelectionNotification, object: editor, queue: nil) { [weak self, weak editor] _ in
      MainActor.assumeIsolated {
        guard let self, editor?.delegate === self else { return }
        self.onSelectionChange()
      }
    }
  }

  func styleEditor() {
    guard let editor = currentEditor() as? NSTextView else { return }
    editor.selectedTextAttributes = [.backgroundColor: selectionColor]
    editor.insertionPointColor = textColor ?? .labelColor
  }
}

@MainActor
final class HeroFieldCoordinator: NSObject, NSTextFieldDelegate, HeroFieldControl {
  var model: HeroBarModel
  weak var field: HeroTextField?
  private var applying = false
  private var before: TextSelection?

  init(model: HeroBarModel) {
    self.model = model
  }

  var fieldValue: String { field?.currentEditor()?.string ?? field?.stringValue ?? model.value }

  var fieldSelection: TextSelection {
    guard let editor = field?.currentEditor() else { return model.selection }
    let r = editor.selectedRange
    return TextSelection(start: r.location, end: r.location + r.length)
  }

  func show(value: String, selection: TextSelection) {
    guard let field else { return }
    applying = true
    defer { applying = false }
    if let editor = field.currentEditor() as? NSTextView {
      if editor.string != value { editor.string = value }
    } else if field.stringValue != value {
      field.stringValue = value
    }
    if let editor = field.currentEditor() {
      let length = (value as NSString).length
      let start = min(selection.start, length)
      let end = min(max(selection.end, start), length)
      let range = NSRange(location: start, length: end - start)
      if editor.selectedRange != range { editor.selectedRange = range }
      if start == 0, end == length, length > 0, let clip = editor.superview as? NSClipView {
        HeroFieldCoordinator.scrollToStart(clip)
        watchEditorFrame(editor)
      }
    }
  }

  static let commandKeys: [Selector: Set<UInt16>] = [
    #selector(NSResponder.cancelOperation(_:)): [53], #selector(NSResponder.moveDown(_:)): [125], #selector(NSResponder.moveUp(_:)): [126],
    #selector(NSResponder.scrollPageUp(_:)): [116], #selector(NSResponder.pageUp(_:)): [116], #selector(NSResponder.scrollPageDown(_:)): [121],
    #selector(NSResponder.pageDown(_:)): [121], #selector(NSResponder.insertTab(_:)): [48], #selector(NSResponder.insertBacktab(_:)): [48],
    #selector(NSResponder.deleteBackward(_:)): [51], #selector(NSResponder.deleteForward(_:)): [117], #selector(NSResponder.insertNewline(_:)): [36, 76],
    #selector(NSResponder.insertNewlineIgnoringFieldEditor(_:)): [36, 76], #selector(NSResponder.insertLineBreak(_:)): [36, 76],
  ]

  static func flags(for selector: Selector) -> NSEvent.ModifierFlags {
    if let event = NSApp.currentEvent, event.type == .keyDown, commandKeys[selector]?.contains(event.keyCode) ?? true {
      return event.modifierFlags.intersection(.deviceIndependentFlagsMask)
    }
    return NSEvent.modifierFlags.intersection(.deviceIndependentFlagsMask)
  }
  private weak var watchedEditor: NSView?

  private func watchEditorFrame(_ editor: NSText) {
    guard watchedEditor !== editor else { return }
    if let old = watchedEditor { NotificationCenter.default.removeObserver(self, name: NSView.frameDidChangeNotification, object: old) }
    watchedEditor = editor
    editor.postsFrameChangedNotifications = true
    NotificationCenter.default.addObserver(self, selector: #selector(editorFrameChanged(_:)), name: NSView.frameDidChangeNotification, object: editor)
  }

  @objc private func editorFrameChanged(_ note: Notification) {
    guard let editor = note.object as? NSTextView, let clip = editor.superview as? NSClipView else { return }
    let length = (editor.string as NSString).length
    if length > 0, editor.selectedRange == NSRange(location: 0, length: length) { return HeroFieldCoordinator.scrollToStart(clip) }
    let inset = NSSize(width: editor.frame.width > clip.bounds.width ? HeroFieldCoordinator.overflowTextInset(editor, in: clip) : 0, height: editor.textContainerInset.height)
    if editor.textContainerInset != inset { editor.textContainerInset = inset }
  }

  static func overflowTextInset(_ editor: NSTextView, in clip: NSClipView) -> CGFloat {
    guard let field = enclosingField(of: clip), let cell = field.cell, let layout = editor.layoutManager, let container = editor.textContainer,
      layout.numberOfGlyphs > 0 else { return 0 }
    let restingLeft = cell.drawingRect(forBounds: field.bounds).minX + container.lineFragmentPadding
    let glyphLeft = layout.boundingRect(forGlyphRange: NSRange(location: 0, length: 1), in: container).minX + editor.textContainerOrigin.x - editor.textContainerInset.width
    let leftmost = clip.constrainBoundsRect(NSRect(origin: NSPoint(x: -10_000, y: clip.bounds.origin.y), size: clip.bounds.size)).origin.x
    let editingLeft = field.convert(NSPoint(x: glyphLeft, y: 0), from: editor).x + clip.bounds.origin.x - leftmost
    return max(0, (restingLeft - editingLeft) * 2).rounded() / 2
  }

  private static func enclosingField(of view: NSView) -> NSTextField? {
    var candidate = view.superview
    while let current = candidate {
      if let field = current as? NSTextField { return field }
      candidate = current.superview
    }
    return nil
  }

  static func scrollToStart(_ clip: NSClipView) {
    if let editor = clip.documentView as? NSTextView {
      let overflows = editor.frame.width > clip.bounds.width
      let inset = NSSize(width: overflows ? overflowTextInset(editor, in: clip) : 0, height: editor.textContainerInset.height)
      if editor.textContainerInset != inset { editor.textContainerInset = inset }
    }
    let leftmost = clip.constrainBoundsRect(NSRect(origin: NSPoint(x: -10_000, y: clip.bounds.origin.y), size: clip.bounds.size)).origin.x
    if clip.bounds.origin.x != leftmost { clip.scroll(to: NSPoint(x: leftmost, y: clip.bounds.origin.y)) }
  }

  func releaseFocus() {
    guard let field, let window = field.window else { return }
    NotificationCenter.default.post(name: Notification.Name("SolaraBarCommitted"), object: window)
    let responder = window.firstResponder as? NSView
    if holdsFocus || (responder.map { $0 === field || $0.isDescendant(of: field) } ?? false) { window.makeFirstResponder(nil) }
  }

  func focusField() {
    guard let field, let window = field.window else { return }
    if field.currentEditor() == nil || window.firstResponder !== field.currentEditor() {
      applying = true
      window.makeFirstResponder(field)
      applying = false
    }
  }

  func textView(_ textView: NSTextView, shouldChangeTextIn affectedCharRange: NSRange, replacementString: String?) -> Bool {
    let r = textView.selectedRange
    before = TextSelection(start: r.location, end: r.location + r.length)
    return true
  }

  func controlTextDidChange(_ obj: Notification) {
    guard !applying, let field else { return }
    field.observeEditor()
    let after = fieldSelection
    let edit = before.map { EditContext(before: $0, after: after) }
    before = nil
    model.textChanged(field.stringValue, edit: edit)
  }

  func selectionDidChange() {
    guard !applying, field?.currentEditor() != nil else { return }
    model.selectionChanged(fieldSelection)
  }

  func controlTextDidEndEditing(_ obj: Notification) {
    let endedModel = model
    let endedSession = endedModel.editingSession
    DispatchQueue.main.async { [weak self] in
      guard let self, !self.holdsFocus else { return }
      endedModel.didBlur(session: endedSession)
    }
  }

  var hasFocus: Bool { holdsFocus }

  var holdsFocus: Bool {
    guard let field, let responder = field.window?.firstResponder else { return false }
    if responder === field { return true }
    guard let editor = responder as? NSTextView, editor.isFieldEditor else { return false }
    return editor.delegate as AnyObject? === field
  }

  func control(_ control: NSControl, textView: NSTextView, doCommandBy selector: Selector) -> Bool {
    if textView.hasMarkedText() { return false }
    if selector == #selector(NSResponder.deleteBackward(_:)) && !textView.string.isEmpty { return false }
    let flags = HeroFieldCoordinator.flags(for: selector)
    func key(_ name: HeroKey.Name) -> HeroKey {
      HeroKey(name, shift: flags.contains(.shift), alt: flags.contains(.option), meta: flags.contains(.command), ctrl: flags.contains(.control))
    }
    switch selector {
    case #selector(NSResponder.cancelOperation(_:)): return model.key(key(.escape))
    case #selector(NSResponder.moveDown(_:)): return model.key(key(.arrowDown))
    case #selector(NSResponder.moveUp(_:)): return model.key(key(.arrowUp))
    case #selector(NSResponder.scrollPageUp(_:)), #selector(NSResponder.pageUp(_:)): return model.key(key(.pageUp))
    case #selector(NSResponder.scrollPageDown(_:)), #selector(NSResponder.pageDown(_:)): return model.key(key(.pageDown))
    case #selector(NSResponder.insertTab(_:)): return model.key(key(.tab))
    case #selector(NSResponder.insertBacktab(_:)): return model.key(HeroKey(.tab, shift: true, alt: flags.contains(.option), meta: flags.contains(.command), ctrl: flags.contains(.control)))
    case #selector(NSResponder.deleteBackward(_:)): return model.key(key(.backspace))
    case #selector(NSResponder.deleteForward(_:)): return model.key(key(.delete))
    case #selector(NSResponder.insertNewline(_:)), #selector(NSResponder.insertNewlineIgnoringFieldEditor(_:)), #selector(NSResponder.insertLineBreak(_:)):
      return model.key(key(.enter))
    default: return false
    }
  }

  func textView(_ view: NSTextView, menu: NSMenu, for event: NSEvent, at charIndex: Int) -> NSMenu? {
    model.selectionChanged(fieldSelection)
    model.contextMenu()
    return nil
  }
}

struct HeroFieldView: NSViewRepresentable {
  let model: HeroBarModel
  let theme: NewTabTheme
  var fontSize: CGFloat = 17

  func makeCoordinator() -> HeroFieldCoordinator { HeroFieldCoordinator(model: model) }

  func makeNSView(context: Context) -> HeroTextField {
    let field = HeroTextField()
    field.model = model
    field.isBezeled = false
    field.isBordered = false
    field.drawsBackground = false
    field.focusRingType = .none
    field.usesSingleLineMode = true
    field.cell?.wraps = false
    field.cell?.isScrollable = true
    field.lineBreakMode = .byClipping
    field.font = .systemFont(ofSize: fontSize)
    field.delegate = context.coordinator
    field.setContentHuggingPriority(.defaultLow, for: .horizontal)
    field.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
    context.coordinator.field = field
    field.onSelectionChange = { [weak coordinator = context.coordinator] in coordinator?.selectionDidChange() }
    model.field = context.coordinator
    field.stringValue = model.value
    style(field)
    return field
  }

  func updateNSView(_ field: HeroTextField, context: Context) {
    if context.coordinator.model !== model {
      context.coordinator.model = model
      field.model = model
      model.field = context.coordinator
    }
    style(field)
  }

  func sizeThatFits(_ proposal: ProposedViewSize, nsView field: HeroTextField, context: Context) -> CGSize? {
    proposal.width.map { CGSize(width: $0, height: field.intrinsicContentSize.height) }
  }

  private func style(_ field: HeroTextField) {
    if field.font?.pointSize != fontSize { field.font = .systemFont(ofSize: fontSize) }
    field.textColor = theme.textPrimary.ns
    field.selectionColor = theme.selection.ns
    let placeholder = model.placeholder
    if field.placeholderAttributedString?.string != placeholder || field.placeholderAttributedString?.attribute(.foregroundColor, at: 0, effectiveRange: nil) as? NSColor != theme.placeholder.ns {
      field.placeholderAttributedString = NSAttributedString(string: placeholder, attributes: [.foregroundColor: theme.placeholder.ns, .font: NSFont.systemFont(ofSize: fontSize)])
    }
  }
}
