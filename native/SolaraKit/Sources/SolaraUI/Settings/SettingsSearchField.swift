import AppKit
import SwiftUI

struct SettingsSearchField: NSViewRepresentable {
  @Binding var text: String
  let focusRequest: Int
  let onSubmit: () -> Void
  let onArrow: (Int) -> Void

  func makeCoordinator() -> Coordinator { Coordinator(self) }

  func makeNSView(context: Context) -> NSSearchField {
    let field = NSSearchField()
    field.placeholderString = "Search"
    field.delegate = context.coordinator
    field.sendsSearchStringImmediately = true
    field.focusRingType = .none
    field.setAccessibilityIdentifier("settings.search")
    return field
  }

  func updateNSView(_ field: NSSearchField, context: Context) {
    context.coordinator.parent = self
    FieldText.set(field, text)
    if focusRequest != context.coordinator.lastFocusRequest {
      context.coordinator.lastFocusRequest = focusRequest
      DispatchQueue.main.async {
        field.window?.makeFirstResponder(field)
        field.currentEditor()?.selectAll(nil)
      }
    }
  }

  @MainActor
  final class Coordinator: NSObject, NSSearchFieldDelegate {
    var parent: SettingsSearchField
    var lastFocusRequest: Int

    init(_ parent: SettingsSearchField) {
      self.parent = parent
      lastFocusRequest = parent.focusRequest
    }

    func controlTextDidChange(_ notification: Notification) {
      guard let field = notification.object as? NSSearchField, field.stringValue != parent.text else { return }
      parent.text = field.stringValue
    }

    func control(_ control: NSControl, textView: NSTextView, doCommandBy selector: Selector) -> Bool {
      switch selector {
      case #selector(NSResponder.moveDown(_:)):
        parent.onArrow(1)
        return true
      case #selector(NSResponder.moveUp(_:)):
        parent.onArrow(-1)
        return true
      case #selector(NSResponder.insertNewline(_:)):
        parent.onSubmit()
        return true
      case #selector(NSResponder.cancelOperation(_:)):
        parent.text = ""
        if let field = control as? NSSearchField { FieldText.set(field, "") }
        return true
      default:
        return false
      }
    }
  }
}
