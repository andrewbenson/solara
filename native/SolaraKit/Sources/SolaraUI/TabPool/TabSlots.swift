import AppKit

@MainActor
public final class TabSlots {
  public static let shared = TabSlots()
  public static let changed = Notification.Name("SolaraTabSlotsChanged")

  private var containers: [TabSlotKey: NSView] = [:]

  private var batchDepth = 0
  private var pendingWindows: Set<String> = []

  public init() {}

  public func performBatch(_ install: () -> Void) {
    batchDepth += 1
    install()
    batchDepth -= 1
    guard batchDepth == 0 else { return }
    let windows = pendingWindows.sorted()
    pendingWindows = []
    for windowId in windows {
      NotificationCenter.default.post(name: Self.changed, object: self, userInfo: ["windowId": windowId])
    }
  }

  public func set(_ key: TabSlotKey, container: NSView) {
    guard containers[key] !== container else { return }
    containers[key] = container
    post(key)
  }

  public func remove(_ key: TabSlotKey, container: NSView) {
    guard containers[key] === container else { return }
    containers[key] = nil
    post(key)
  }

  public func container(for key: TabSlotKey) -> NSView? { containers[key] }

  public var keys: Set<TabSlotKey> { Set(containers.keys) }

  public func keys(in windowId: String) -> Set<TabSlotKey> { Set(containers.keys.filter { $0.windowId == windowId }) }

  private func post(_ key: TabSlotKey) {
    if batchDepth > 0 { pendingWindows.insert(key.windowId); return }
    NotificationCenter.default.post(name: Self.changed, object: self, userInfo: ["windowId": key.windowId])
  }
}
