import Foundation

public struct FocusKeyHold: Sendable {
  public static let cap: TimeInterval = 0.15
  public static let capacity = 64
  public static let lateBeginWindow: TimeInterval = 1

  public enum KeyDown: Equatable, Sendable { case pass, hold, release }

  public let command: String
  public let pressedAt: TimeInterval
  private let dispatchedAt: TimeInterval
  public private(set) var held = 0

  public init(command: String, pressedAt: TimeInterval, dispatchedAt: TimeInterval? = nil) {
    self.command = command
    self.pressedAt = pressedAt
    self.dispatchedAt = dispatchedAt ?? pressedAt
  }

  public static func opens(focusMoving: Bool, pageFocused: Bool, markedText: Bool, gateOpen: Bool, holding: Bool, isRepeat: Bool) -> Bool {
    focusMoving && pageFocused && !markedText && !gateOpen && !holding && !isRepeat
  }

  public func expired(at now: TimeInterval) -> Bool { now - dispatchedAt >= Self.cap }

  public mutating func keyDown(command: Bool, at now: TimeInterval) -> KeyDown {
    if expired(at: now) || held >= Self.capacity { return .release }
    if command && held == 0 { return .pass }
    held += 1
    return .hold
  }

  public func milliseconds(at now: TimeInterval) -> Int { max(0, Int(((now - pressedAt) * 1000).rounded())) }

  public static func beganLate(pressedAt: TimeInterval, released: Int, at now: TimeInterval) -> Bool {
    released > 0 && now >= pressedAt && now - pressedAt < lateBeginWindow
  }
}
