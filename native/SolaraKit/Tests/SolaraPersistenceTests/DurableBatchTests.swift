import Foundation
import GRDB
import SolaraModel
@testable import SolaraPersistence
import SolaraStore
import Synchronization
import Testing

@Suite struct DurableBatchTests {
  @Test func queuedDurableRequestsShareOneCheckpoint() throws {
    let folder = try scratchFolder()
    defer { try? FileManager.default.removeItem(at: folder.url) }
    let launch = try open(folder)
    let store = store(for: launch)
    let writer = PersistenceWriter(store: store, database: launch.database, folder: folder, persisted: launch.persisted)
    defer { writer.freeze() }
    let checkpoints = Mutex(0)
    try launch.database.pool.writeWithoutTransaction { db in
      db.trace { event in
        if event.description.contains("wal_checkpoint(FULL)") { checkpoints.withLock { $0 += 1 } }
      }
    }
    defer { try? launch.database.pool.writeWithoutTransaction { $0.trace(nil) } }
    let blocked = DispatchSemaphore(value: 0)
    let release = DispatchSemaphore(value: 0)
    writer.queue.async {
      blocked.signal()
      _ = release.wait(timeout: .now() + 5)
    }
    try #require(blocked.wait(timeout: .now() + 5) == .success)
    let done = DispatchSemaphore(value: 0)
    let results = Mutex<[FlushResult]>([])
    DispatchQueue.concurrentPerform(iterations: 24) { _ in
      writer.enqueueDurableFlush { result in
        results.withLock { $0.append(result) }
        done.signal()
      }
    }
    release.signal()
    for _ in 0..<24 { try #require(done.wait(timeout: .now() + 5) == .success) }
    #expect(results.withLock { $0 == Array(repeating: .saved, count: 24) })
    #expect(checkpoints.withLock { $0 } == 1)
    #expect(writer.flush(timeout: 5) == .saved)
    #expect(checkpoints.withLock { $0 } == 1)
  }

  @Test func oneFailedBatchReportsItsFailureToEveryWaiter() throws {
    let folder = try scratchFolder()
    defer { try? FileManager.default.removeItem(at: folder.url) }
    let launch = try open(folder)
    let store = store(for: launch)
    try store.dispatch(Command("updateSettings", [["appearance": "dark"]]))
    try launch.database.pool.write { db in
      try db.execute(sql: "CREATE TRIGGER fail_settings BEFORE INSERT ON setting BEGIN SELECT RAISE(FAIL, 'shared durable failure'); END")
    }
    let writer = PersistenceWriter(store: store, database: launch.database, folder: folder, persisted: launch.persisted)
    defer { writer.freeze() }
    let blocked = DispatchSemaphore(value: 0)
    let release = DispatchSemaphore(value: 0)
    writer.queue.async {
      blocked.signal()
      _ = release.wait(timeout: .now() + 5)
    }
    try #require(blocked.wait(timeout: .now() + 5) == .success)
    let done = DispatchSemaphore(value: 0)
    let results = Mutex<[FlushResult]>([])
    let errorCounts = Mutex<[Int]>([])
    for _ in 0..<16 {
      writer.enqueueDurableFlush { result in
        results.withLock { $0.append(result) }
        errorCounts.withLock { $0.append(writer.errors.count) }
        done.signal()
      }
    }
    release.signal()
    for _ in 0..<16 { try #require(done.wait(timeout: .now() + 5) == .success) }
    let failures = results.withLock { $0 }
    #expect(failures.count == 16)
    let firstFailure = try #require(failures.first)
    #expect(failures.allSatisfy { $0 == firstFailure })
    #expect(failures.allSatisfy { $0.description.contains("shared durable failure") })
    #expect(errorCounts.withLock { Set($0).count } == 1)
    try launch.database.pool.write { try $0.execute(sql: "DROP TRIGGER fail_settings") }
    #expect(writer.flush(timeout: 5) == .saved)
    #expect(try launch.database.load().settings?["appearance"] == "dark")
  }

  @Test func aRequestAfterTheSaveSnapshotNeedsAnotherCheckpoint() throws {
    let folder = try scratchFolder()
    defer { try? FileManager.default.removeItem(at: folder.url) }
    let launch = try open(folder)
    let store = store(for: launch)
    let writer = PersistenceWriter(store: store, database: launch.database, folder: folder, persisted: launch.persisted)
    defer { writer.freeze() }
    let checkpointStarted = DispatchSemaphore(value: 0)
    let release = DispatchSemaphore(value: 0)
    let checkpoints = Mutex(0)
    try launch.database.pool.writeWithoutTransaction { db in
      db.trace { event in
        guard event.description.contains("wal_checkpoint(FULL)") else { return }
        let first = checkpoints.withLock { value in
          value += 1
          return value == 1
        }
        if first {
          checkpointStarted.signal()
          _ = release.wait(timeout: .now() + 5)
        }
      }
    }
    defer { try? launch.database.pool.writeWithoutTransaction { $0.trace(nil) } }
    let firstDone = DispatchSemaphore(value: 0)
    let firstResult = Mutex<FlushResult>(.timedOut)
    writer.enqueueDurableFlush { result in
      firstResult.withLock { $0 = result }
      firstDone.signal()
    }
    try #require(checkpointStarted.wait(timeout: .now() + 5) == .success)
    let window = try store.dispatch(Command("createWindow", [["url": "https://later.example/"]])).result!.string!
    let secondDone = DispatchSemaphore(value: 0)
    let secondResult = Mutex<FlushResult>(.timedOut)
    writer.enqueueDurableFlush { result in
      secondResult.withLock { $0 = result }
      secondDone.signal()
    }
    release.signal()
    try #require(firstDone.wait(timeout: .now() + 5) == .success)
    try #require(secondDone.wait(timeout: .now() + 5) == .success)
    #expect(firstResult.withLock { $0 } == .failed("persistence still has pending writes"))
    #expect(secondResult.withLock { $0 } == .saved)
    #expect(checkpoints.withLock { $0 } == 2)
    #expect(try launch.database.load().workspace?.tables["window"]?.ids.contains(window) == true)
  }

  @Test func successfulCheckpointReuseRequiresUnchangedRowsAnchorAndShadow() throws {
    let folder = try scratchFolder()
    defer { try? FileManager.default.removeItem(at: folder.url) }
    let launch = try open(folder)
    let store = store(for: launch)
    let writer = PersistenceWriter(store: store, database: launch.database, folder: folder, persisted: launch.persisted)
    defer { writer.freeze() }
    let checkpoints = Mutex(0)
    try launch.database.pool.writeWithoutTransaction { db in
      db.trace { event in
        if event.description.contains("wal_checkpoint(FULL)") { checkpoints.withLock { $0 += 1 } }
      }
    }
    defer { try? launch.database.pool.writeWithoutTransaction { $0.trace(nil) } }
    #expect(writer.flush(timeout: 5) == .saved)
    #expect(checkpoints.withLock { $0 } == 1)
    try store.dispatch(Command("createWindow", [[:]]))
    writer.queue.sync { writer.flushRows() }
    #expect(writer.flush(timeout: 5) == .saved)
    #expect(checkpoints.withLock { $0 } == 2)
    writer.setSyncAnchor("next-anchor")
    writer.queue.sync { writer.flushRows() }
    #expect(writer.flush(timeout: 5) == .saved)
    #expect(checkpoints.withLock { $0 } == 3)
    #expect(try launch.database.load().syncAnchor == "next-anchor")
    writer.markShadowDirty()
    #expect(writer.flush(timeout: 5) == .saved)
    #expect(checkpoints.withLock { $0 } == 4)
    #expect(writer.flush(timeout: 5) == .saved)
    #expect(checkpoints.withLock { $0 } == 4)
    writer.freeze()
    #expect(writer.flush(timeout: 5) == .failed("persistence is frozen"))
    #expect(checkpoints.withLock { $0 } == 4)
  }

  @Test func aDatabaseWriteAfterTheCheckpointCannotEnterItsCachedToken() throws {
    let folder = try scratchFolder()
    defer { try? FileManager.default.removeItem(at: folder.url) }
    let launch = try open(folder)
    let store = store(for: launch)
    let shadowStarted = DispatchSemaphore(value: 0)
    let release = DispatchSemaphore(value: 0)
    let first = Mutex(true)
    let writer = PersistenceWriter(
      store: store, database: launch.database, folder: folder, persisted: launch.persisted,
      clock: {
        if first.withLock({ value in let old = value; value = false; return old }) {
          shadowStarted.signal()
          _ = release.wait(timeout: .now() + 5)
        }
        return 42
      })
    defer { writer.freeze() }
    let checkpoints = Mutex(0)
    launch.database.pool.writeWithoutTransaction { db in
      db.trace { event in
        if event.description.contains("wal_checkpoint(FULL)") { checkpoints.withLock { $0 += 1 } }
      }
    }
    defer { launch.database.pool.writeWithoutTransaction { $0.trace(nil) } }
    writer.markShadowDirty()
    let done = DispatchSemaphore(value: 0)
    let result = Mutex<FlushResult>(.timedOut)
    writer.enqueueDurableFlush { saved in result.withLock { $0 = saved }; done.signal() }
    try #require(shadowStarted.wait(timeout: .now() + 5) == .success)
    try launch.database.setMeta(["after-checkpoint": "new"])
    release.signal()
    try #require(done.wait(timeout: .now() + 5) == .success)
    #expect(result.withLock { $0 } == .saved)
    #expect(checkpoints.withLock { $0 } == 1)
    #expect(writer.flush(timeout: 5) == .saved)
    #expect(checkpoints.withLock { $0 } == 2)
    #expect(try launch.database.meta("after-checkpoint") == "new")
  }

  @Test func directDatabaseChangesInvalidateSuccessfulCheckpointReuse() throws {
    let folder = try scratchFolder()
    defer { try? FileManager.default.removeItem(at: folder.url) }
    let launch = try open(folder)
    let store = store(for: launch)
    let writer = PersistenceWriter(store: store, database: launch.database, folder: folder, persisted: launch.persisted)
    defer { writer.freeze() }
    let checkpoints = Mutex(0)
    try launch.database.pool.writeWithoutTransaction { db in
      db.trace { event in
        if event.description.contains("wal_checkpoint(FULL)") { checkpoints.withLock { $0 += 1 } }
      }
    }
    defer { try? launch.database.pool.writeWithoutTransaction { $0.trace(nil) } }
    #expect(writer.flush(timeout: 5) == .saved)
    #expect(checkpoints.withLock { $0 } == 1)
    try launch.database.setMeta(["external-save": "first"])
    #expect(writer.flush(timeout: 5) == .saved)
    #expect(checkpoints.withLock { $0 } == 2)
    try launch.database.pool.write { db in
      try db.execute(sql: "UPDATE meta SET value = 'second' WHERE key = 'external-save'")
    }
    #expect(writer.flush(timeout: 5) == .saved)
    #expect(checkpoints.withLock { $0 } == 3)
    #expect(writer.flush(timeout: 5) == .saved)
    #expect(checkpoints.withLock { $0 } == 3)
  }
}
