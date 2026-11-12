import AppKit

public struct LastWindowPresentation {
  public let collection: NSWindow.CollectionBehavior
  public let excluded: Bool

  public init(collection: NSWindow.CollectionBehavior, excluded: Bool) {
    self.collection = collection
    self.excluded = excluded
  }

  public var retainedCollection: NSWindow.CollectionBehavior {
    collection.subtracting([.managed, .participatesInCycle]).union([.transient, .ignoresCycle])
  }

  public var retainedExcluded: Bool { true }
}
