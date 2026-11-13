import AppKit

@MainActor
public enum FrameUpdates {
  public static let passLimit = 8
  private static var pending: [ObjectIdentifier: @MainActor () -> Void] = [:]
  private static var order: [ObjectIdentifier] = []
  private static var observer: CFRunLoopObserver?
  private static var flushPosted = false

  public static func schedule(_ owner: AnyObject, _ render: @escaping @MainActor () -> Void) {
    let key = ObjectIdentifier(owner)
    if pending.updateValue(render, forKey: key) == nil { order.append(key) }
    installObserver()
  }

  public static func flush() {
    var passes = 0
    while !order.isEmpty, passes < passLimit {
      passes += 1
      let keys = order
      let renders = pending
      order = []
      pending = [:]
      for key in keys { renders[key]?() }
    }
    if !order.isEmpty { postFlush() }
  }

  public nonisolated static func readOnMain<T: Sendable>(_ read: @MainActor () throws -> T) rethrows -> T {
    try MainActor.assumeIsolated {
      flush()
      return try read()
    }
  }

  private static func postFlush() {
    guard !flushPosted else { return }
    flushPosted = true
    #if DEBUG
      FileHandle.standardError.write(Data("FrameUpdates: renders still scheduling after \(passLimit) passes; continuing next turn\n".utf8))
    #endif
    let main = CFRunLoopGetMain()
    CFRunLoopPerformBlock(main, CFRunLoopMode.commonModes.rawValue) {
      MainActor.assumeIsolated {
        flushPosted = false
        flush()
      }
    }
    CFRunLoopWakeUp(main)
  }

  private static func installObserver() {
    guard observer == nil else { return }
    let activities = CFRunLoopActivity.beforeWaiting.rawValue | CFRunLoopActivity.exit.rawValue
    let created = CFRunLoopObserverCreateWithHandler(nil, activities, true, 1_000_000) { _, _ in
      MainActor.assumeIsolated { flush() }
    }
    CFRunLoopAddObserver(CFRunLoopGetMain(), created, .commonModes)
    observer = created
  }
}
