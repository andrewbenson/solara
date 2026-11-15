import AppKit

@MainActor
public final class SplitSlots {
  public static let shared = SplitSlots()
  public static let changed = Notification.Name("SolaraSplitSlotsChanged")

  private var owners: [String: WeakSplitOwner] = [:]
  private var panes: [String: [String: CGRect]] = [:]

  public func panes(_ windowId: String) -> [String: CGRect] { panes[windowId] ?? [:] }

  func publish(_ windowId: String, _ next: [String: CGRect], owner: AnyObject? = nil) {
    if let owner { owners[windowId] = WeakSplitOwner(owner) }
    guard panes[windowId] != next else { return }
    panes[windowId] = next.isEmpty ? nil : next
    NotificationCenter.default.post(name: Self.changed, object: self, userInfo: ["windowId": windowId])
  }
  func remove(_ windowId: String, owner: AnyObject) {
    guard owners[windowId]?.value === owner else { return }
    owners[windowId] = nil
    publish(windowId, [:])
  }
}

@MainActor
private final class WeakSplitOwner {
  weak var value: AnyObject?
  init(_ value: AnyObject) { self.value = value }
}
