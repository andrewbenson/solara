import Darwin
import Foundation
import GRDB
import SolaraDurability
import SolaraModel
@testable import SolaraPersistence
import SolaraStore
import Synchronization
import Testing

final class SyncRecorder: Sendable {
  struct State {
    var events: [String] = []
    var failFull = false
    var failKind: String?
    var failFallback = false
  }

  let state = Mutex(State())

  var hooks: DurableSyncHooks {
    DurableSyncHooks(
      fcntl: { fd, command in
        #expect(command == F_FULLFSYNC)
        let kind = Self.path(fd).hasSuffix("-wal") ? "wal" : "db"
        let fail = self.state.withLock { state in
          state.events.append("full:\(kind)")
          return state.failFull && (state.failKind == nil || state.failKind == kind)
        }
        if fail { errno = EIO; return -1 }
        return Darwin.fcntl(fd, command)
      },
      fsync: { fd in
        let fail = self.state.withLock { state in
          state.events.append("fsync")
          return state.failFallback
        }
        if fail { errno = ENOSPC; return -1 }
        return Darwin.fsync(fd)
      })
  }

  static func path(_ fd: Int32) -> String {
    var buffer = [CChar](repeating: 0, count: Int(MAXPATHLEN))
    let result = buffer.withUnsafeMutableBufferPointer { Darwin.fcntl(fd, F_GETPATH, $0.baseAddress!) }
    return result == 0 ? buffer.withUnsafeBufferPointer { String(cString: $0.baseAddress!) } : "unknown"
  }

  func reset() { state.withLock { $0.events = [] } }
  var events: [String] { state.withLock { $0.events } }
}

@Suite struct DurableSyncTests {
  @Test func durableCommitFlushesWALBeforeCheckpointedDatabaseAndRoundTrips() throws {
    let folder = try scratchFolder()
    defer { try? FileManager.default.removeItem(at: folder.url) }
    let recorder = SyncRecorder()
    let database = try SolaraDatabase(url: folder.database, sync: recorder.hooks)
    try database.pool.writeWithoutTransaction { db in try db.execute(sql: "PRAGMA wal_autocheckpoint = 0") }
    recorder.reset()
    try database.write(durable: true) { db in try Rows.setMeta(db, "durable-test", "saved") }
    let events = recorder.events
    let firstDB = try #require(events.firstIndex(of: "full:db"))
    #expect(firstDB > 0)
    #expect(events[..<firstDB].allSatisfy { $0 == "full:wal" })
    #expect(events.last == "full:db")
    #expect(!events.contains("fsync"))
    try database.close()
    let reopened = try SolaraDatabase(url: folder.database)
    defer { try? reopened.close() }
    #expect(try reopened.meta("durable-test") == "saved")
    #expect(try reopened.pool.read { try String.fetchAll($0, sql: "PRAGMA integrity_check") } == ["ok"])
  }

  @Test func routineCommitsAndCheckpointsNeverRequestFullFlushes() throws {
    let folder = try scratchFolder()
    defer { try? FileManager.default.removeItem(at: folder.url) }
    let recorder = SyncRecorder()
    let database = try SolaraDatabase(url: folder.database, sync: recorder.hooks)
    defer { try? database.close() }
    recorder.reset()
    for index in 0..<10 {
      try database.write(durable: false) { db in try Rows.setMeta(db, "routine", String(index)) }
    }
    try database.pool.writeWithoutTransaction { db in
      try db.execute(sql: "PRAGMA wal_checkpoint(FULL)")
      #expect(try Int.fetchOne(db, sql: "PRAGMA synchronous") == 1)
      #expect(try Int.fetchOne(db, sql: "PRAGMA fullfsync") == 1)
      #expect(try Int.fetchOne(db, sql: "PRAGMA checkpoint_fullfsync") == 1)
    }
    try database.pool.read { db in
      let full = try Int.fetchOne(db, sql: "PRAGMA fullfsync")
      let checkpoint = try Int.fetchOne(db, sql: "PRAGMA checkpoint_fullfsync")
      #expect(full == 1)
      #expect(checkpoint == 1)
    }
    #expect(recorder.events.isEmpty)
    #expect(try database.meta("routine") == "9")
  }

  @Test(arguments: [SQLITE_NOTFOUND, SQLITE_ERROR]) func unavailableShimKeepsRoutineStorageAndRejectsDurableAcknowledgements(registration: Int32) throws {
    let folder = try scratchFolder()
    defer { try? FileManager.default.removeItem(at: folder.url) }
    let database = try SolaraDatabase(url: folder.database, sync: DurableSyncHooks(registration: { registration }))
    try database.write(durable: false) { db in
      try Rows.writeSettings(db, ["appearance": "dark"])
      try Rows.setMeta(db, "routine-fallback", "saved")
    }
    #expect(try database.load().settings?["appearance"] == "dark")
    let launch = try open(folder)
    let store = store(for: launch)
    let writer = PersistenceWriter(store: store, database: database, folder: folder, persisted: launch.persisted)
    defer { writer.freeze() }
    guard case .failed(let message) = writer.flush(timeout: 5) else {
      Issue.record("unavailable durable sync was acknowledged")
      return
    }
    #expect(message.contains("unavailable"))
    #expect(writer.errors.contains { $0.contains("unavailable") })
    try store.dispatch(Command("updateSettings", [["appearance": "light"]]))
    writer.queue.sync {}
    #expect(try database.load().settings?["appearance"] == "light")
    guard case .failed = writer.flush(timeout: 5) else {
      Issue.record("unavailable durable sync was acknowledged after a routine change")
      return
    }
    writer.freeze()
    try database.close()
    let reopened = try SolaraDatabase(url: folder.database, sync: DurableSyncHooks(registration: { registration }))
    defer { try? reopened.close() }
    #expect(try reopened.meta("routine-fallback") == "saved")
    #expect(try reopened.load().settings?["appearance"] == "light")
    #expect(try reopened.pool.read { try String.fetchAll($0, sql: "PRAGMA integrity_check") } == ["ok"])
    let existing = try SolaraDatabase(existing: folder.database, sync: DurableSyncHooks(registration: { registration }))
    defer { try? existing.close() }
    #expect(try existing.load().settings?["appearance"] == "light")
    try existing.write(durable: false) { db in try Rows.setMeta(db, "existing-fallback", "saved") }
    #expect(try reopened.meta("existing-fallback") == "saved")
  }

  @Test func unavailableShimDoesNotCreateMissingExistingDatabase() throws {
    let folder = try scratchFolder()
    defer { try? FileManager.default.removeItem(at: folder.url) }
    #expect(throws: DatabaseError.self) {
      try SolaraDatabase(existing: folder.database, sync: DurableSyncHooks(registration: { SQLITE_NOTFOUND }))
    }
    #expect(!FileManager.default.fileExists(atPath: folder.database.path))
  }

  @Test func unchangedAlreadyCheckpointedSaveStillFlushesTheDatabase() throws {
    let folder = try scratchFolder()
    defer { try? FileManager.default.removeItem(at: folder.url) }
    let recorder = SyncRecorder()
    let database = try SolaraDatabase(url: folder.database, sync: recorder.hooks)
    defer { try? database.close() }
    try database.pool.writeWithoutTransaction { db in try db.execute(sql: "PRAGMA wal_checkpoint(FULL)") }
    recorder.reset()
    try database.write(durable: true) { _ in }
    #expect(recorder.events.contains("full:db"))
    #expect(try database.pool.read { try String.fetchAll($0, sql: "PRAGMA integrity_check") } == ["ok"])
  }

  @Test(arguments: [false, true]) func fullFlushFailureFallsBackAndNeverReturnsSuccess(fallbackFails: Bool) throws {
    let folder = try scratchFolder()
    defer { try? FileManager.default.removeItem(at: folder.url) }
    let recorder = SyncRecorder()
    let database = try SolaraDatabase(url: folder.database, sync: recorder.hooks)
    defer { try? database.close() }
    recorder.state.withLock { $0.failFull = true; $0.failFallback = fallbackFails }
    recorder.reset()
    #expect(throws: (any Error).self) {
      try database.write(durable: true) { db in try Rows.setMeta(db, "failure", "value") }
    }
    #expect(recorder.events.contains("fsync"))
    #expect(!recorder.events.contains("full:db"))
    let synchronous = try database.pool.writeWithoutTransaction { try Int.fetchOne($0, sql: "PRAGMA synchronous") }
    #expect(synchronous == 1)
    recorder.state.withLock { $0.failFull = false; $0.failFallback = false }
    try database.write(durable: true) { db in try Rows.setMeta(db, "recovered", "yes") }
    #expect(try database.meta("recovered") == "yes")
    #expect(try database.pool.read { try String.fetchAll($0, sql: "PRAGMA integrity_check") } == ["ok"])
  }

  @Test func checkpointFullFlushFailureIsReportedAfterTheWALFlush() throws {
    let folder = try scratchFolder()
    defer { try? FileManager.default.removeItem(at: folder.url) }
    let recorder = SyncRecorder()
    let database = try SolaraDatabase(url: folder.database, sync: recorder.hooks)
    defer { try? database.close() }
    recorder.state.withLock { $0.failFull = true; $0.failKind = "db" }
    recorder.reset()
    #expect(throws: DurabilityFailure.self) {
      try database.write(durable: true) { db in try Rows.setMeta(db, "checkpoint-failure", "saved-in-wal") }
    }
    #expect(recorder.events.first == "full:wal")
    #expect(recorder.events.suffix(2) == ["full:db", "fsync"])
    recorder.state.withLock { $0.failFull = false }
    try database.write(durable: true) { _ in }
    #expect(try database.meta("checkpoint-failure") == "saved-in-wal")
    #expect(try database.pool.read { try String.fetchAll($0, sql: "PRAGMA integrity_check") } == ["ok"])
  }

  @Test func fullFlushFailureReachesWriterResultAndErrorLog() throws {
    let folder = try scratchFolder()
    defer { try? FileManager.default.removeItem(at: folder.url) }
    let launch = try open(folder)
    let recorder = SyncRecorder()
    let database = try SolaraDatabase(url: folder.database, sync: recorder.hooks)
    let writer = PersistenceWriter(store: store(for: launch), database: database, folder: folder, persisted: launch.persisted)
    defer { writer.freeze() }
    recorder.state.withLock { $0.failFull = true }
    guard case .failed(let message) = writer.flush(timeout: 5) else { Issue.record("failed full flush was acknowledged"); return }
    #expect(message.contains("fully durable"))
    #expect(writer.errors.contains { $0.contains("fully durable") })
    recorder.state.withLock { $0.failFull = false }
    #expect(writer.flush(timeout: 5) == .saved)
  }

  @Test func poolReadersAndWALReusePreserveDurabilityOrdering() throws {
    let folder = try scratchFolder()
    defer { try? FileManager.default.removeItem(at: folder.url) }
    let recorder = SyncRecorder()
    let database = try SolaraDatabase(url: folder.database, sync: recorder.hooks)
    defer { try? database.close() }
    for index in 0..<8 {
      DispatchQueue.concurrentPerform(iterations: 4) { _ in
        do { _ = try database.meta("pooled") } catch { Issue.record(error) }
      }
      recorder.reset()
      try database.write(durable: true) { db in try Rows.setMeta(db, "pooled", String(index)) }
      #expect(recorder.events.first == "full:wal")
      #expect(recorder.events.last == "full:db")
      try database.pool.writeWithoutTransaction { db in try db.execute(sql: "PRAGMA wal_checkpoint(TRUNCATE)") }
      (database.pool as? DatabasePool)?.releaseMemory()
    }
    #expect(try database.meta("pooled") == "7")
    #expect(try database.pool.read { try String.fetchAll($0, sql: "PRAGMA integrity_check") } == ["ok"])
  }

  @Test func concurrentAndBackToBackRequestsShareActualFullFlushes() throws {
    let folder = try scratchFolder()
    defer { try? FileManager.default.removeItem(at: folder.url) }
    let launch = try open(folder)
    let recorder = SyncRecorder()
    let database = try SolaraDatabase(url: folder.database, sync: recorder.hooks)
    let store = store(for: launch)
    let writer = PersistenceWriter(store: store, database: database, folder: folder, persisted: launch.persisted)
    defer { writer.freeze() }
    let blocked = DispatchSemaphore(value: 0)
    let release = DispatchSemaphore(value: 0)
    writer.queue.async { blocked.signal(); _ = release.wait(timeout: .now() + 5) }
    try #require(blocked.wait(timeout: .now() + 5) == .success)
    let done = DispatchGroup()
    let results = Mutex<[FlushResult]>([])
    recorder.reset()
    DispatchQueue.concurrentPerform(iterations: 24) { _ in
      done.enter()
      writer.enqueueDurableFlush { result in results.withLock { $0.append(result) }; done.leave() }
    }
    release.signal()
    try #require(done.wait(timeout: .now() + 5) == .success)
    #expect(results.withLock { $0 == Array(repeating: .saved, count: 24) })
    let count = recorder.events.count
    #expect(count > 0 && count < 24)
    #expect(writer.flush(timeout: 5) == .saved)
    #expect(recorder.events.count == count)
    try store.dispatch(Command("updateSettings", [["appearance": "dark"]]))
    writer.queue.sync {}
    let afterCommand = recorder.events.count
    #expect(afterCommand > count)
    #expect(writer.flush(timeout: 5) == .saved)
    #expect(recorder.events.count == afterCommand)
    #expect(try database.load().settings?["appearance"] == "dark")
  }

  @Test func checkpointBlockedByReaderFailsThenRecovers() throws {
    let folder = try scratchFolder()
    defer { try? FileManager.default.removeItem(at: folder.url) }
    let recorder = SyncRecorder()
    let database = try SolaraDatabase(url: folder.database, sync: recorder.hooks)
    defer { try? database.close() }
    try database.pool.writeWithoutTransaction { db in try db.execute(sql: "PRAGMA busy_timeout = 20") }
    let ready = DispatchSemaphore(value: 0)
    let release = DispatchSemaphore(value: 0)
    let done = DispatchGroup()
    done.enter()
    Thread.detachNewThread {
      do {
        try database.pool.read { db in
          _ = try String.fetchOne(db, sql: "SELECT value FROM meta LIMIT 1")
          ready.signal()
          _ = release.wait(timeout: .now() + 5)
        }
      } catch { Issue.record(error); ready.signal() }
      done.leave()
    }
    try #require(ready.wait(timeout: .now() + 5) == .success)
    defer { release.signal(); _ = done.wait(timeout: .now() + 5) }
    #expect(throws: (any Error).self) {
      try database.write(durable: true) { db in try Rows.setMeta(db, "reader", "blocked") }
    }
    release.signal()
    try #require(done.wait(timeout: .now() + 5) == .success)
    try database.write(durable: true) { _ in }
    #expect(try database.meta("reader") == "blocked")
  }
}
