import CoreGraphics

public struct WindowAnchorBatch: Equatable, Sendable {
  public let snapshot: WindowLayoutSnapshot
  public let anchors: [String: CGRect]
  public var windowId: String { snapshot.input.windowId }
  public var windowGeneration: UInt64 { snapshot.input.windowGeneration }
  public var storeRevision: Int { snapshot.input.storeRevision }
  public var generation: UInt64 { snapshot.generation }

  public init(snapshot: WindowLayoutSnapshot, anchors: [String: CGRect] = [:]) {
    self.snapshot = snapshot
    self.anchors = snapshot.anchors.merging(anchors) { _, native in native }
  }
}

@MainActor
public final class WindowAnchors {
  public let windowId: String
  public let windowGeneration: UInt64
  public private(set) var current: WindowAnchorBatch?
  private var stopped = false

  public init(windowId: String, windowGeneration: UInt64) {
    self.windowId = windowId
    self.windowGeneration = windowGeneration
  }

  @discardableResult
  public func publish(_ batch: WindowAnchorBatch) -> Bool {
    guard !stopped, batch.windowId == windowId, batch.windowGeneration == windowGeneration else { return false }
    if let current, batch.storeRevision < current.storeRevision || batch.generation <= current.generation { return false }
    current = batch
    return true
  }

  @discardableResult
  public func restamp(_ input: WindowLayoutInput) -> Bool {
    guard !stopped, let current, input.windowId == windowId, input.windowGeneration == windowGeneration,
      input.storeRevision > current.storeRevision, input.hasSameLayout(as: current.snapshot.input) else { return false }
    self.current = WindowAnchorBatch(snapshot: .of(input, generation: current.generation), anchors: current.anchors)
    return true
  }

  public func stop() {
    stopped = true
    current = nil
  }
}
