import Foundation

public enum FocusGateRules {
  public static let lifetime: TimeInterval = 0.4
  public static let capacity = 64
  public static let typedAfterCloseWindow: TimeInterval = 1
  public static let editKeys: Set<String> = ["x", "c", "v", "a"]

  public static let deferredFocusMarkerSubtype: Int16 = 0x5346

  public enum Deferral: Equatable, Sendable {
    case notGated
    case settle
    case hold(at: TimeInterval)
    case holdNow
    case dropWithoutOrigin
  }

  public enum EventKind: Equatable, Sendable { case commandKeyDown, mouseButton, focusMarker(subtype: Int16), other }

  public enum UnhandledKey: Equatable, Sendable { case untagged, acknowledge, refuse }

  public static func live(now: TimeInterval, deadline: TimeInterval) -> Bool { now < deadline }

  public static func pressedBeforeBarCommitted(pressedAt: TimeInterval?, barCommittedAt: TimeInterval?) -> Bool {
    guard let pressedAt, let barCommittedAt else { return false }
    return pressedAt < barCommittedAt
  }

  public static func deferral(pressedAt: TimeInterval?, gateLive: Bool, hasGeneration: Bool, heldEmpty: Bool) -> Deferral {
    guard gateLive else { return .notGated }
    guard hasGeneration else { return .settle }
    if let pressedAt { return .hold(at: pressedAt) }
    return heldEmpty ? .holdNow : .dropWithoutOrigin
  }

  public static func origin(of kind: EventKind, at timestamp: TimeInterval) -> TimeInterval? {
    switch kind {
    case .commandKeyDown, .mouseButton: return timestamp
    case .focusMarker(let subtype): return subtype == deferredFocusMarkerSubtype ? timestamp : nil
    case .other: return nil
    }
  }

  public static func dropsLateAcknowledgement(acknowledgedAt: TimeInterval?, gateClosedAt: TimeInterval?, typedAfterAt: TimeInterval?) -> Bool {
    guard let acknowledgedAt, let gateClosedAt, let typedAfterAt else { return false }
    return acknowledgedAt < gateClosedAt && typedAfterAt > acknowledgedAt
  }

  public static func notesTyping(now: TimeInterval, gateClosedAt: TimeInterval?) -> Bool {
    guard let gateClosedAt else { return false }
    return now - gateClosedAt < typedAfterCloseWindow
  }

  public static func insertionIndex(of at: TimeInterval, among held: [TimeInterval]) -> Int {
    held.lastIndex { $0 <= at }.map { $0 + 1 } ?? 0
  }

  public static func isEditKey(command: Bool, control: Bool, key: String?) -> Bool {
    command && !control && editKeys.contains(key?.lowercased() ?? "")
  }

  public static func unhandledKey(tag: [Int]?, current: [Int], windowIsKey: Bool) -> UnhandledKey {
    guard let tag, tag.count == 2 else { return .untagged }
    return tag == current && windowIsKey ? .acknowledge : .refuse
  }

  public static func keepsAfterBegin(heldAt: TimeInterval, commandPressedAt: TimeInterval?) -> Bool {
    guard let commandPressedAt else { return false }
    return heldAt >= commandPressedAt
  }
}
