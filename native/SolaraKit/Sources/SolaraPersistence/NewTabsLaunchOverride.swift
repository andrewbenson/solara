import Foundation
import SolaraModel
import SolaraStore

public enum NewTabsLaunchOverride {
  static let markerName = ".new-tabs-top-0.4.1"

  enum Failure: Error {
    case persistence(FlushResult)
  }

  @discardableResult
  public static func apply(store: Store, writer: PersistenceWriter?, folder: URL, safeMode: Bool) throws -> Bool {
    guard !safeMode, let writer else { return false }
    return try apply(store: store, folder: folder, flush: { writer.flush(timeout: 5) })
  }

  @discardableResult
  static func apply(
    store: Store, folder: URL, flush: () -> FlushResult,
    writeMarker: (URL) throws -> Void = { try Data("1".utf8).write(to: $0, options: .atomic) }
  ) throws -> Bool {
    let marker = folder.appending(path: markerName)
    if FileManager.default.fileExists(atPath: marker.path) { return false }
    try store.dispatch(Command("updateSettings", [["newTabPosition": "top", "newTabButtonPosition": "top"]]), origin: .native)
    let saved = flush()
    guard saved == .saved else { throw Failure.persistence(saved) }
    try writeMarker(marker)
    return true
  }
}
