import AppKit

enum FieldText {
  static func set(_ field: NSTextField, _ value: String) {
    guard let editor = field.currentEditor() as? NSTextView else {
      if field.stringValue != value { field.stringValue = value }
      return
    }
    replace(editor, with: value)
  }

  static func replace(_ editor: NSTextView, with value: String) {
    guard editor.string != value else { return clamp(editor) }
    let whole = NSRange(location: 0, length: (editor.string as NSString).length)
    editor.setSelectedRange(NSRange(location: 0, length: 0))
    let undo = editor.undoManager
    undo?.disableUndoRegistration()
    defer { undo?.enableUndoRegistration() }
    if editor.shouldChangeText(in: whole, replacementString: value) {
      editor.replaceCharacters(in: whole, with: value)
      editor.didChangeText()
    } else {
      editor.string = value
    }
    clamp(editor)
  }

  static func clamp(_ editor: NSTextView) {
    let length = (editor.string as NSString).length
    let ranges = editor.selectedRanges.map(\.rangeValue)
    let clamped = ranges.map { range -> NSRange in
      let start = min(range.location, length)
      return NSRange(location: start, length: min(range.length, length - start))
    }
    if clamped != ranges { editor.selectedRanges = clamped.map { NSValue(range: $0) } }
  }
}
