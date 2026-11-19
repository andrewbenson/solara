import AppKit

public enum DragCarryTarget: Equatable, Sendable {
  case tab(String)
  case profile(String)
}

public struct DragCarrySpring: Sendable {
  public private(set) var target: DragCarryTarget?
  private var sequence: Int?
  private var activated = false

  public init() {}

  @discardableResult
  public mutating func update(_ target: DragCarryTarget?, sequence: Int) -> Bool {
    guard self.target != target || self.sequence != sequence else { return false }
    self.target = target
    self.sequence = sequence
    activated = false
    return true
  }

  public mutating func activate(_ target: DragCarryTarget?, sequence: Int) -> DragCarryTarget? {
    guard !activated, self.sequence == sequence, let target, self.target == target else { return nil }
    activated = true
    return target
  }

  public mutating func cancel() {
    target = nil
    sequence = nil
    activated = false
  }

  @MainActor
  public static func accepts(_ board: NSPasteboard) -> Bool {
    board.availableType(from: [.fileURL, .URL, .string, .tiff, .png]) != nil
  }
}
