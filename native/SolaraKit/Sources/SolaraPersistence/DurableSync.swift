import Darwin
import Foundation
import GRDB
import OSLog
import SolaraDurability

struct DurableSyncHooks: Sendable {
  var registration: @Sendable () -> Int32 = { sd_register() }
  var fcntl: @Sendable (Int32, Int32) -> Int32 = { Darwin.fcntl($0, $1) }
  var fsync: @Sendable (Int32) -> Int32 = { Darwin.fsync($0) }
}

struct DurabilityFailure: Error, CustomStringConvertible {
  let fullSyncError: Int32
  let fallbackError: Int32

  var description: String {
    "save is not fully durable: F_FULLFSYNC errno \(fullSyncError), fsync errno \(fallbackError)"
  }
}

final class DurableSync: Sendable {
  static let logger = Logger(subsystem: "network.benson.solara", category: "persistence")
  private static let unavailableLogged: Void = {
    logger.error("durable SQLite VFS is unavailable; routine persistence remains enabled")
  }()
  let hooks: DurableSyncHooks
  let registered: Bool

  init(hooks: DurableSyncHooks = DurableSyncHooks()) {
    self.hooks = hooks
    registered = hooks.registration() == SQLITE_OK
  }

  var available: Bool { registered && hooks.registration() == SQLITE_OK }

  func path(_ url: URL, existing: Bool = false) -> String {
    if registered {
      return url.absoluteString + "?vfs=solara-durable" + (existing ? "&mode=rw" : "")
    }
    return url.absoluteString + (existing ? "?mode=rw" : "")
  }

  func unavailable() -> DatabaseError {
    _ = Self.unavailableLogged
    return DatabaseError(resultCode: .SQLITE_IOERR, message: "durable SQLite VFS is unavailable; routine write cannot confirm durability")
  }

  func run(_ db: Database, _ body: () throws -> Void) throws {
    var scope = SDScope()
    scope.context = Unmanaged.passUnretained(self).toOpaque()
    scope.full_sync = { fd, command, context in
      Unmanaged<DurableSync>.fromOpaque(context!).takeUnretainedValue().hooks.fcntl(fd, command)
    }
    scope.fallback_sync = { fd, context in
      Unmanaged<DurableSync>.fromOpaque(context!).takeUnretainedValue().hooks.fsync(fd)
    }
    try withUnsafeMutablePointer(to: &scope) { scope in
      guard sd_begin(db.sqliteConnection, scope) == SQLITE_OK else {
        throw unavailable()
      }
      defer { sd_end(scope) }
      do {
        try body()
        guard sd_finish(scope) == SQLITE_OK else {
          throw DatabaseError(resultCode: .SQLITE_IOERR, message: "durable SQLite sync failed")
        }
      } catch {
        if scope.pointee.failed_errno != 0 {
          let failure = DurabilityFailure(fullSyncError: scope.pointee.failed_errno, fallbackError: scope.pointee.fallback_errno)
          Self.logger.error("\(failure.description, privacy: .public)")
          throw failure
        }
        throw error
      }
    }
  }
}
