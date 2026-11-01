import Foundation
import Synchronization
import os

public enum SolaraSignposts {
  public enum Point: String, Sendable, CaseIterable {
    case selectionShown = "selection shown"
    case suggestionsShown = "suggestions shown"
    case coreReady = "core ready"
    case newTabPainted = "New Tab painted"
  }

  public enum Counter: String, Sendable, CaseIterable {
    case storeCommit = "store commit"
    case caCommit = "CA commit"
    case layoutPass = "layout pass"
    case viewUpdate = "view update"
  }

  public typealias Observer = @convention(c) (UnsafePointer<CChar>, Int, Double) -> Void

  public static let subsystem = "network.benson.solara.perf"
  static let points = OSSignposter(subsystem: subsystem, category: .pointsOfInterest)
  static let counts = OSSignposter(subsystem: subsystem, category: "counts")
  static let observer = Mutex<Observer?>(nil)
  static let counters = Mutex<[Counter: Int]>([:])

  public static func setObserver(_ fn: Observer?) {
    observer.withLock { $0 = fn }
  }

  public static func emit(_ point: Point, window: Int = 0) {
    points.emitEvent("point", "\(point.rawValue, privacy: .public) window \(window)")
    notify(point.rawValue, window)
  }

  public static func count(_ counter: Counter, by n: Int = 1) {
    counts.emitEvent("count", "\(counter.rawValue, privacy: .public) \(n)")
    counters.withLock { $0[counter, default: 0] += n }
  }

  public static func read() -> [Counter: Int] { counters.withLock { $0 } }

  public static func reset() { counters.withLock { $0.removeAll() } }

  static func notify(_ name: String, _ window: Int) {
    guard let fn = observer.withLock({ $0 }) else { return }
    let at = Date().timeIntervalSince1970 * 1000
    name.withCString { fn($0, window, at) }
  }
}

@_cdecl("SolaraSignpostsSetObserver")
public func solaraSignpostsSetObserver(_ fn: SolaraSignposts.Observer?) {
  SolaraSignposts.setObserver(fn)
}

@_cdecl("SolaraSignpostsEmit")
public func solaraSignpostsEmit(_ name: UnsafePointer<CChar>, _ window: Int) -> Bool {
  guard let point = SolaraSignposts.Point(rawValue: String(cString: name)) else { return false }
  SolaraSignposts.emit(point, window: window)
  return true
}

@_cdecl("SolaraSignpostsCount")
public func solaraSignpostsCount(_ name: UnsafePointer<CChar>, _ n: Int) -> Bool {
  guard let counter = SolaraSignposts.Counter(rawValue: String(cString: name)) else { return false }
  SolaraSignposts.count(counter, by: n)
  return true
}

@_cdecl("SolaraSignpostsCounter")
public func solaraSignpostsCounter(_ name: UnsafePointer<CChar>) -> Int {
  guard let counter = SolaraSignposts.Counter(rawValue: String(cString: name)) else { return -1 }
  return SolaraSignposts.read()[counter] ?? 0
}
