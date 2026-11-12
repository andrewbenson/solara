import Foundation

public enum WindowCloseDisposition: Equatable {
  case userRequest
  case deferUntilSaved
  case physicalTeardown
}

public struct WindowTerminationLifecycle {
  public private(set) var awaitingReply = false
  public private(set) var approved = false

  public init() {}

  public var isTerminating: Bool { awaitingReply || approved }
  public var publishesWindowTeardown: Bool { !approved }
  public var userCloseDisposition: WindowCloseDisposition {
    if approved { return .physicalTeardown }
    return awaitingReply ? .deferUntilSaved : .userRequest
  }

  public mutating func begin() {
    awaitingReply = true
  }

  public mutating func approve() {
    awaitingReply = false
    approved = true
  }

  public mutating func cancel() {
    awaitingReply = false
    approved = false
  }
}
