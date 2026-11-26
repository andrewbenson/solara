import Foundation

public struct SelectionLifecycle: Sendable {
  private var enabled = false
  private var page: String?
  private var pending: String?
  private var presented: String?
  private var due: TimeInterval = 0

  public init() {}

  public mutating func update(enabled: Bool) {
    self.enabled = enabled
    if !enabled { page = nil; pending = nil; presented = nil }
  }

  public mutating func receive(text: String?, page: String, now: TimeInterval) {
    guard enabled else { return }
    if self.page != page { presented = nil }
    self.page = page
    pending = text
    due = now + 0.15
    if text == nil { presented = nil }
  }

  public mutating func shown(page: String, now: TimeInterval) -> String? {
    guard enabled, page == self.page else { return nil }
    if now >= due { presented = pending }
    return presented
  }

  public static func query(_ text: String) -> String {
    text.replacingOccurrences(of: #"[\u0009-\u000D\u0020\u00A0\u1680\u2000-\u200A\u2028\u2029\u202F\u205F\u3000\uFEFF]+"#, with: " ", options: .regularExpression).trimmingCharacters(in: CharacterSet(charactersIn: " "))
  }

  public static func disposition(meta: Bool, shift: Bool, alt: Bool, middle: Bool) -> String {
    if meta || middle { return shift ? "foreground" : "background" }
    if alt { return "split" }
    if shift { return "window" }
    return "foreground"
  }
}
