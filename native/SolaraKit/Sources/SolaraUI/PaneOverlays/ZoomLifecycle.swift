import Foundation

public enum ZoomLifecycle {
  public static func step(_ value: Double) -> Int? {
    guard value.isFinite else { return nil }
    return value == 0 ? 0 : value < 0 ? -1 : 1
  }

  public static func accepts(page: String, currentPage: String?, eligible: Bool) -> Bool {
    eligible && page == currentPage
  }
}

public struct PanePopoverLifecycle: Sendable {
  public private(set) var values: [String: String] = [:]
  private var revisions: [String: UInt64] = [:]
  private var sequence: UInt64 = 0

  public init() {}

  public func revision(_ tabId: String) -> UInt64 { revisions[tabId] ?? 0 }

  public mutating func set(_ value: String?, tabId: String) {
    sequence &+= 1
    revisions[tabId] = sequence
    values[tabId] = value
  }

  public mutating func dismissZoom(_ tabId: String, revision: UInt64) -> Bool {
    guard values[tabId] == "zoom", self.revision(tabId) == revision else { return false }
    set(nil, tabId: tabId)
    return true
  }

  public mutating func retainTabs(_ ids: Set<String>) {
    values = values.filter { ids.contains($0.key) }
    revisions = revisions.filter { ids.contains($0.key) }
  }
}
