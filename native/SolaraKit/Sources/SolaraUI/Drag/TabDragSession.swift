import AppKit

public enum TabDropAim: Equatable, Sendable {
  case split(tabId: String, side: SplitSide)
  case insert(beforeId: String?)
  case page
  case newWindow
  case bookmarks
}

public enum TabDropPriority: Int, Comparable, Sendable {
  case bookmarks = -1
  case split = 0
  case insert = 1
  case page = 2

  public static func < (a: TabDropPriority, b: TabDropPriority) -> Bool { a.rawValue < b.rawValue }
}

@MainActor
public protocol TabDropZone: AnyObject {
  func aim(_ session: TabDragSession, at windowPoint: CGPoint) -> TabDropAim?
  func clear()
  func drop(_ session: TabDragSession, _ aim: TabDropAim) -> Bool
}

@MainActor
public final class TabDragSession {
  public static private(set) var current: TabDragSession?

  public let tabIds: [String]
  public let sourceWindow: String
  public private(set) var pointer: CGPoint = .zero
  public private(set) var overWindow: String?
  public private(set) var outside = false
  public var lifted: Bool?
  public var sourceClosing: (() -> Void)?
  public var reaim: (() -> Void)?
  public private(set) var aim: TabDropAim?
  public private(set) var endedAim: TabDropAim?

  private struct Asked {
    weak var zone: TabDropZone?
  }

  private struct Registered {
    weak var zone: TabDropZone?
    let windowId: String
    let priority: TabDropPriority
  }

  private static var zones: [Registered] = []
  private weak var aimed: TabDropZone?
  private var asked: [ObjectIdentifier: Asked] = [:]
  private var closeObserver: NSObjectProtocol?
  private var belowSource: Set<ObjectIdentifier>?

  init(tabIds: [String], sourceWindow: String) {
    self.tabIds = tabIds
    self.sourceWindow = sourceWindow
  }

  public static func register(_ zone: TabDropZone, windowId: String, priority: TabDropPriority) {
    zones.removeAll { $0.zone == nil || $0.zone === zone }
    zones.append(Registered(zone: zone, windowId: windowId, priority: priority))
  }

  public static func unregister(_ zone: TabDropZone) {
    zones.removeAll { $0.zone == nil || $0.zone === zone }
  }

  public static func hasZone(in windowId: String, _ priority: TabDropPriority) -> Bool {
    zones.contains { $0.windowId == windowId && $0.priority == priority && $0.zone != nil }
  }

  @discardableResult
  public static func begin(tabIds: [String], from windowId: String) -> TabDragSession {
    current?.cancel()
    let session = TabDragSession(tabIds: tabIds, sourceWindow: windowId)
    current = session
    session.watchSource()
    return session
  }

  public func away(for windowId: String) -> Bool { overWindow != windowId }

  public func move(screenPoint: CGPoint) {
    guard Self.current === self else { return }
    pointer = screenPoint
    if belowSource == nil { belowSource = coveringStart(screenPoint) }
    let window = window(at: screenPoint)
    overWindow = window.map { $0.0 }
    outside = overWindow != sourceWindow
    var next: (zone: TabDropZone, aim: TabDropAim)?
    if let (windowId, nsWindow) = window {
      let local = Self.windowPoint(screenPoint, in: nsWindow)
      let candidates = Self.zones.filter { $0.windowId == windowId && $0.zone != nil }.sorted { $0.priority < $1.priority }
      for entry in candidates {
        guard let zone = entry.zone else { continue }
        asked[ObjectIdentifier(zone)] = Asked(zone: zone)
        guard let found = zone.aim(self, at: local) else { continue }
        next = (zone, found)
        break
      }
    }
    if let aimed, aimed !== next?.zone { aimed.clear() }
    aimed = next?.zone
    aim = next?.aim ?? (window == nil ? .newWindow : nil)
  }

  public func end() -> Bool {
    guard Self.current === self else { return false }
    move(screenPoint: pointer)
    endedAim = aim
    Self.current = nil
    defer { clearAll() }
    guard let aim else { return false }
    if let aimed { return aimed.drop(self, aim) }
    return false
  }

  public func cancel() {
    guard Self.current === self else { return }
    Self.current = nil
    clearAll()
  }

  private func watchSource() {
    guard let window = Self.windowOf(sourceWindow) else { return }
    closeObserver = NotificationCenter.default.addObserver(forName: NSWindow.willCloseNotification, object: window, queue: .main) { [weak self] _ in
      MainActor.assumeIsolated {
        guard let self, Self.current === self else { return }
        self.sourceClosing?()
        self.cancel()
      }
    }
  }

  private func clearAll() {
    if let closeObserver { NotificationCenter.default.removeObserver(closeObserver) }
    closeObserver = nil
    aimed?.clear()
    for zone in asked.values.compactMap(\.zone) where zone !== aimed { zone.clear() }
    asked = [:]
    aimed = nil
    aim = nil
  }

  public static var windowIdOf: (NSWindow) -> String? = { _ in nil }
  public static var windowOf: (String) -> NSWindow? = { _ in nil }

  public func point(in windowId: String) -> CGPoint? {
    Self.windowOf(windowId).map { Self.windowPoint(pointer, in: $0) }
  }

  private func window(at screenPoint: CGPoint) -> (String, NSWindow)? {
    for nsWindow in NSApp.orderedWindows where nsWindow.isVisible && nsWindow.frame.contains(screenPoint) {
      if belowSource?.contains(ObjectIdentifier(nsWindow)) == true { continue }
      if let id = Self.windowIdOf(nsWindow) { return (id, nsWindow) }
    }
    return nil
  }

  private func coveringStart(_ screenPoint: CGPoint) -> Set<ObjectIdentifier> {
    guard let source = Self.windowOf(sourceWindow), source.frame.contains(screenPoint) else { return [] }
    var covering: Set<ObjectIdentifier> = []
    for nsWindow in NSApp.orderedWindows {
      if nsWindow === source { return covering }
      if nsWindow.isVisible && nsWindow.frame.contains(screenPoint) { covering.insert(ObjectIdentifier(nsWindow)) }
    }
    return covering
  }

  private static func windowPoint(_ screenPoint: CGPoint, in window: NSWindow) -> CGPoint {
    let p = window.convertPoint(fromScreen: screenPoint)
    let height = window.contentView?.bounds.height ?? window.frame.height
    return CGPoint(x: p.x, y: height - p.y)
  }
}
