import AppKit
import Synchronization

public struct HostedContent {
  public let view: NSView
  public let onUnmount: (() -> Void)?
  public let takesFocus: Bool
  public let onState: ((String) -> Void)?

  public init(view: NSView, onUnmount: (() -> Void)? = nil, takesFocus: Bool = true, onState: ((String) -> Void)? = nil) {
    self.view = view
    self.onUnmount = onUnmount
    self.takesFocus = takesFocus
    self.onState = onState
  }
}

@MainActor
public enum HostedViews {
  public typealias Make = (_ windowId: String) -> HostedContent?

  private static var makers: [String: (String, String) -> HostedContent?] = [:]
  nonisolated private static let registered = Mutex<Set<String>>([])

  public static func register(_ kind: String, _ make: @escaping Make) {
    register(kind) { windowId, _ in make(windowId) }
  }

  public static func register(_ kind: String, _ make: @escaping (String, String) -> HostedContent?) {
    makers[kind] = make
    registered.withLock { _ = $0.insert(kind) }
  }

  public static func unregister(_ kind: String) {
    makers[kind] = nil
    registered.withLock { _ = $0.remove(kind) }
  }

  static func make(_ kind: String, windowId: String, state: String = "") -> HostedContent? {
    makers[kind]?(windowId, state)
  }

  nonisolated static var kinds: [String] { registered.withLock { $0.sorted() } }

  nonisolated public static func declare(_ kind: String) {
    registered.withLock { _ = $0.insert(kind) }
  }

  public static var emit: (([String: Any]) -> Void)?

  public static func send(_ kind: String, windowId: String, _ name: String, _ payload: [String: Any]) {
    emit?(["kind": kind, "windowId": windowId, "name": name, "payload": payload])
  }
}

@MainActor
final class HostedMount {
  let content: HostedContent
  private weak var window: NSWindow?
  private weak var savedResponder: NSResponder?
  private let savedSelection: NSRange?
  private var ended = false

  init(content: HostedContent, in host: NSView, window: NSWindow) {
    self.content = content
    self.window = window
    let responder = content.takesFocus ? window.firstResponder : nil
    if let editor = responder as? NSTextView, editor.isFieldEditor, let field = editor.delegate as? NSResponder {
      savedResponder = field
      savedSelection = editor.selectedRange()
    } else {
      savedResponder = responder
      savedSelection = nil
    }
    content.view.frame = host.bounds
    content.view.autoresizingMask = [.width, .height]
    host.addSubview(content.view)
    if content.takesFocus { window.makeFirstResponder(content.view) }
  }

  func end() {
    guard !ended else { return }
    ended = true
    guard content.takesFocus else {
      content.view.removeFromSuperview()
      content.onUnmount?()
      return
    }
    let hadFocus = window.map { focus(in: $0) } ?? false
    content.view.removeFromSuperview()
    content.onUnmount?()
    guard hadFocus, let window, let responder = savedResponder, restorable(responder, in: window) else { return }
    guard window.makeFirstResponder(responder) else { return }
    if let savedSelection, let editor = (responder as? NSTextField)?.currentEditor() as? NSTextView,
      NSMaxRange(savedSelection) <= (editor.string as NSString).length
    {
      editor.setSelectedRange(savedSelection)
    }
  }

  private func focus(in window: NSWindow) -> Bool {
    guard let responder = window.firstResponder as? NSView else { return window.firstResponder === window }
    if let editor = responder as? NSTextView, editor.isFieldEditor, let field = editor.delegate as? NSView {
      return field === content.view || field.isDescendant(of: content.view)
    }
    return responder === content.view || responder.isDescendant(of: content.view)
  }

  private func restorable(_ responder: NSResponder, in window: NSWindow) -> Bool {
    if responder === window { return true }
    guard let view = responder as? NSView else { return false }
    return view.window === window && !view.isHiddenOrHasHiddenAncestor && view.acceptsFirstResponder
  }
}
