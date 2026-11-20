import AppKit

public extension NSTextContentType {
  static let solaraPlainText = NSTextContentType(rawValue: "network.benson.solara.text")
}

public extension NSTextField {
  static func solaraPromptField(value: String = "", placeholder: String? = nil) -> NSTextField {
    let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 260, height: 24))
    field.stringValue = value
    field.placeholderString = placeholder
    field.contentType = .solaraPlainText
    return field
  }
}
