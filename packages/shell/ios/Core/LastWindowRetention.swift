import Foundation

public struct LastWindowRetention {
  public private(set) var id: String?

  public init() {}

  public mutating func retain(
    _ candidate: String, browserIds: Set<String>, privateIds: Set<String>, smallIds: Set<String>, closingIds: Set<String> = [], terminating: Bool
  ) -> Bool {
    guard !terminating, !closingIds.contains(candidate), browserIds.contains(candidate), !privateIds.contains(candidate), !smallIds.contains(candidate) else { return false }
    if id == candidate { return true }
    guard browserIds.subtracting(privateIds).subtracting(smallIds).subtracting(closingIds) == [candidate], id == nil else { return false }
    id = candidate
    return true
  }

  public mutating func reveal(_ candidate: String) -> Bool {
    guard id == candidate else { return false }
    id = nil
    return true
  }

  public func shouldCreateWindow(hasVisibleBrowser: Bool, terminating: Bool) -> Bool {
    id == nil && !hasVisibleBrowser && !terminating
  }

  public func shouldReopen(hasVisibleBrowser: Bool, terminating: Bool, background: Bool) -> Bool {
    id != nil && !hasVisibleBrowser && !terminating && !background
  }
}
