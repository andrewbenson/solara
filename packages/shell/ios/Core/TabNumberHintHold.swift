import Foundation

public struct TabNumberHintHold: Sendable {
  public static let delay: TimeInterval = 1
  public private(set) var generation: UInt64 = 0
  public private(set) var deadline: TimeInterval?
  public private(set) var visible = false
  private var commandDown = false
  private var blocked = false

  public init() {}

  public mutating func modifiers(command: Bool, alone: Bool, now: TimeInterval) {
    if !command {
      generation &+= 1
      deadline = nil
      visible = false
      commandDown = false
      blocked = false
      return
    }
    let began = !commandDown
    commandDown = true
    guard alone else { return interrupt() }
    guard began, !blocked else { return }
    generation &+= 1
    deadline = now + Self.delay
  }

  public mutating func interrupt() {
    generation &+= 1
    deadline = nil
    visible = false
    if commandDown { blocked = true }
  }

  @discardableResult
  public mutating func expire(generation expected: UInt64, now: TimeInterval) -> Bool {
    guard generation == expected, let deadline, now >= deadline, commandDown, !blocked else { return false }
    self.deadline = nil
    visible = true
    return true
  }
}
