import Foundation
import GRDB
import SolaraModel
@testable import SolaraPersistence
import SolaraStore
import Synchronization
import Testing

@Suite struct QuitFlushTests {
  @Test func quitSavesShadowWhenAnotherDeliveryOwnerBlocksBeforeWriterNote() throws {
    let folder = try scratchFolder()
    defer { try? FileManager.default.removeItem(at: folder.url) }
    let launch = try open(folder)
    let store = store(for: launch)
    let id = try persistencePage(store)
    let armed = Mutex(false)
    let entered = DispatchSemaphore(value: 0)
    let release = DispatchSemaphore(value: 0)
    let finished = DispatchSemaphore(value: 0)
    let token = store.subscribe { _ in
      guard armed.withLock({ $0 }) else { return }
      entered.signal()
      _ = release.wait(timeout: .now() + 5)
    }
    let writer = PersistenceWriter(store: store, database: launch.database, folder: folder, persisted: launch.persisted)
    defer { release.signal(); store.unsubscribe(token); writer.freeze(); try? launch.database.close() }
    writer.markShadowDirty()
    #expect(writer.flush(timeout: 5) == .saved)
    #expect(writer.pending.withLock { !$0.rows && !$0.shadow })
    armed.withLock { $0 = true }
    Thread.detachNewThread {
      _ = try? store.dispatch(Command("pageReport", [.string(id), persistenceNavigation()]))
      finished.signal()
    }
    try #require(entered.wait(timeout: .now() + 1) == .success)
    #expect(writer.pending.withLock { !$0.rows && !$0.shadow })
    #expect(QuitFlush.run(store: store, writer: writer, barrierTimeout: 5, writerTimeout: 5) == .saved)
    let revision = store.committedSnapshot.0
    let persisted = try #require(try launch.database.load().sessionJSON())
    let row = try #require(persisted["tabs"]?.array?.first { $0["id"]?.string == id })
    let shadow = try JSONValue.parse(Data(contentsOf: folder.session))
    let shadowRow = try #require(shadow["tabs"]?.array?.first { $0["id"]?.string == id })
    for value in [row, shadowRow] {
      #expect(value["url"] == "https://after.example/")
      #expect(value["title"] == "Final title")
    }
    #expect(try launch.database.meta("rev") == String(revision))
    #expect(shadow["nativeExport"]?["rev"] == JSONValue(revision))
    release.signal()
    #expect(finished.wait(timeout: .now() + 5) == .success)
  }

  @Test func quitFromAListenerDoesNotWaitForTheExistingDeliveryOwner() throws {
    let store = Store()
    let once = Mutex(false)
    let results = Mutex<[FlushResult]>([])
    let token = store.subscribe { _ in
      guard once.withLock({ value in let old = value; value = true; return !old }) else { return }
      store.enqueueSequenced(Command("updateSettings", [["sidebarWidth": 247]]))
      results.withLock { $0.append(QuitFlush.run(store: store, writer: nil, barrierTimeout: 5, writerTimeout: 5)) }
    }
    defer { store.unsubscribe(token) }
    try store.dispatch(Command("createWindow", [["url": "https://quit.example/"]]))
    #expect(results.withLock { $0 } == [.safeModeOpenedNoDatabase])
    #expect(store.state.settings["sidebarWidth"] == 247)
  }

  @Test func simultaneousQuitRequestsShareOneWriterOperation() throws {
    let folder = try scratchFolder()
    defer { try? FileManager.default.removeItem(at: folder.url) }
    let launch = try open(folder)
    let store = store(for: launch)
    let writer = PersistenceWriter(store: store, database: launch.database, folder: folder, persisted: launch.persisted)
    defer { writer.freeze(); try? launch.database.close() }
    #expect(writer.flush(timeout: 5) == .saved)
    let checkpoints = Mutex(0)
    try launch.database.pool.writeWithoutTransaction { db in db.trace { event in
      if event.description.contains("wal_checkpoint(FULL)") { checkpoints.withLock { $0 += 1 } }
    } }
    let writing = DispatchSemaphore(value: 0)
    let release = DispatchSemaphore(value: 0)
    let drained = DispatchSemaphore(value: 0)
    let finished = DispatchSemaphore(value: 0)
    let results = Mutex<[FlushResult]>([])
    let token = store.subscribe { _ in drained.signal() }
    defer { store.unsubscribe(token); release.signal() }
    writer.queue.async { writing.signal(); _ = release.wait(timeout: .now() + 5) }
    try #require(writing.wait(timeout: .now() + 5) == .success)
    store.enqueueSequenced(Command("createWindow", [["url": "https://quit.example/"]]))
    Thread.detachNewThread {
      let result = QuitFlush.run(store: store, writer: writer, barrierTimeout: 1, writerTimeout: 2)
      results.withLock { $0.append(result) }
      finished.signal()
    }
    try #require(drained.wait(timeout: .now() + 1) == .success)
    #expect(QuitFlush.run(store: store, writer: writer, barrierTimeout: 0.02, writerTimeout: 0.02) == .timedOut)
    release.signal()
    #expect(finished.wait(timeout: .now() + 5) == .success)
    writer.queue.sync {}
    #expect(results.withLock { $0 } == [.saved])
    #expect(checkpoints.withLock { $0 } == 1)
    try launch.database.pool.writeWithoutTransaction { db in db.trace(nil) }
  }

  @Test func quitDrainsReservedNavigationBeforeDurableFlush() throws {
    let folder = try scratchFolder()
    defer { try? FileManager.default.removeItem(at: folder.url) }
    let launch = try open(folder)
    let store = store(for: launch)
    let id = try persistencePage(store)
    let writer = PersistenceWriter(store: store, database: launch.database, folder: folder, persisted: launch.persisted)
    defer { writer.freeze(); try? launch.database.close() }
    store.enqueuePageReport(id: id, report: persistenceNavigation())
    #expect(QuitFlush.run(store: store, writer: writer, barrierTimeout: 1, writerTimeout: 5) == .saved)
    let document = try #require(try launch.database.load().sessionJSON())
    let row = try #require(document["tabs"]?.array?.first { $0["id"]?.string == id })
    #expect(row["url"] == "https://after.example/")
    #expect(row["title"] == "Final title")
    #expect(try launch.database.meta("rev") == String(store.rev))
  }

  @Test func timedOutQuitKeepsWriterSharedUntilDurableCompletion() throws {
    let folder = try scratchFolder()
    defer { try? FileManager.default.removeItem(at: folder.url) }
    let launch = try open(folder)
    let store = store(for: launch)
    let writer = PersistenceWriter(store: store, database: launch.database, folder: folder, persisted: launch.persisted)
    defer { writer.freeze(); try? launch.database.close() }
    #expect(writer.flush(timeout: 5) == .saved)
    let checkpoints = Mutex(0)
    try launch.database.pool.writeWithoutTransaction { db in db.trace { event in
      if event.description.contains("wal_checkpoint(FULL)") { checkpoints.withLock { $0 += 1 } }
    } }
    let writing = DispatchSemaphore(value: 0)
    let release = DispatchSemaphore(value: 0)
    defer { release.signal() }
    writer.queue.async { writing.signal(); _ = release.wait(timeout: .now() + 5) }
    try #require(writing.wait(timeout: .now() + 1) == .success)
    #expect(QuitFlush.run(store: store, writer: writer, barrierTimeout: 1, writerTimeout: 0.02) == .timedOut)
    #expect(QuitFlush.run(store: store, writer: writer, barrierTimeout: 0.02, writerTimeout: 0.02) == .timedOut)
    release.signal()
    writer.queue.sync {}
    #expect(checkpoints.withLock { $0 } == 1)
    #expect(QuitFlush.run(store: store, writer: writer, barrierTimeout: 5, writerTimeout: 5) == .saved)
    #expect(checkpoints.withLock { $0 } == 2)
    try launch.database.pool.writeWithoutTransaction { db in db.trace(nil) }
  }

  @Test func quitBarrierDeadlineIncludesContendedIngress() throws {
    let store = Store()
    let entered = DispatchSemaphore(value: 0)
    let release = DispatchSemaphore(value: 0)
    let finished = DispatchSemaphore(value: 0)
    Thread.detachNewThread {
      store.sequence { entered.signal(); _ = release.wait(timeout: .now() + 5) }
      finished.signal()
    }
    defer { release.signal() }
    try #require(entered.wait(timeout: .now() + 5) == .success)
    let start = ContinuousClock.now
    #expect(!store.drainForQuit(until: start.advanced(by: .milliseconds(30))))
    #expect(start.duration(to: .now) < .seconds(1))
    release.signal()
    #expect(finished.wait(timeout: .now() + 5) == .success)
  }

  @Test func quitReturnsByDeadlineWithBlockedListener() throws {
    let store = Store()
    let entered = DispatchSemaphore(value: 0)
    let release = DispatchSemaphore(value: 0)
    let left = DispatchSemaphore(value: 0)
    let token = store.subscribe { _ in entered.signal(); _ = release.wait(timeout: .now() + 5); left.signal() }
    defer { release.signal(); store.unsubscribe(token) }
    store.enqueueSequenced(Command("createWindow", [["url": "https://quit.example/"]]))
    let start = ContinuousClock.now
    #expect(QuitFlush.run(store: store, writer: nil, barrierTimeout: 0.03, writerTimeout: 1) == .timedOut)
    #expect(start.duration(to: .now) < .seconds(1))
    #expect(entered.wait(timeout: .now() + 1) == .success)
    release.signal()
    #expect(left.wait(timeout: .now() + 5) == .success)
  }

  @Test func quitBarrierTimeoutNeverStartsLateWriterFlush() throws {
    let folder = try scratchFolder()
    defer { try? FileManager.default.removeItem(at: folder.url) }
    let launch = try open(folder)
    let store = store(for: launch)
    let writer = PersistenceWriter(store: store, database: launch.database, folder: folder, persisted: launch.persisted)
    defer { writer.freeze(); try? launch.database.close() }
    #expect(writer.flush(timeout: 5) == .saved)
    let checkpoints = Mutex(0)
    try launch.database.pool.writeWithoutTransaction { db in db.trace { event in
      if event.description.contains("wal_checkpoint(FULL)") { checkpoints.withLock { $0 += 1 } }
    } }
    let entered = DispatchSemaphore(value: 0)
    let release = DispatchSemaphore(value: 0)
    let finished = DispatchSemaphore(value: 0)
    Thread.detachNewThread {
      store.sequence { entered.signal(); _ = release.wait(timeout: .now() + 5) }
      finished.signal()
    }
    try #require(entered.wait(timeout: .now() + 5) == .success)
    defer { release.signal() }
    #expect(QuitFlush.run(store: store, writer: writer, barrierTimeout: 0.03, writerTimeout: 1) == .timedOut)
    release.signal()
    #expect(finished.wait(timeout: .now() + 5) == .success)
    #expect(store.drainForQuit(until: .now.advanced(by: .seconds(1))))
    writer.queue.sync {}
    #expect(checkpoints.withLock { $0 } == 0)
    try launch.database.pool.writeWithoutTransaction { db in db.trace(nil) }
  }

  @Test func quitWriterGetsIndependentDeadline() throws {
    let folder = try scratchFolder()
    defer { try? FileManager.default.removeItem(at: folder.url) }
    let launch = try open(folder)
    let store = store(for: launch)
    let writer = PersistenceWriter(store: store, database: launch.database, folder: folder, persisted: launch.persisted)
    defer { writer.freeze(); try? launch.database.close() }
    let queued = DispatchSemaphore(value: 0)
    let release = DispatchSemaphore(value: 0)
    writer.queue.async { queued.signal(); _ = release.wait(timeout: .now() + 5) }
    try #require(queued.wait(timeout: .now() + 5) == .success)
    defer { release.signal() }
    let start = ContinuousClock.now
    #expect(QuitFlush.run(store: store, writer: writer, barrierTimeout: 0.03, writerTimeout: 0.08) == .timedOut)
    let elapsed = start.duration(to: .now)
    #expect(elapsed >= .milliseconds(60))
    #expect(elapsed < .seconds(1))
    release.signal()
    writer.queue.sync {}
  }

  @Test func quitNoWriterDrainsThenSkips() throws {
    let store = Store()
    store.enqueueSequenced(Command("createWindow", [["url": "https://quit.example/"]]))
    #expect(QuitFlush.run(store: store, writer: nil, barrierTimeout: 5, writerTimeout: 5) == .safeModeOpenedNoDatabase)
    #expect(store.state.windows.count == 1)
    #expect(QuitFlush.run(store: store, writer: nil, barrierTimeout: 0, writerTimeout: 1) == .timedOut)
    #expect(QuitFlush.run(store: store, writer: nil, barrierTimeout: 1, writerTimeout: -1) == .timedOut)
  }

  @Test func oversizedBudgetsReturnAtOnceWithoutRunningStages() throws {
    let store = Store()
    let ran = Mutex(0)
    let stages = QuitFlush.Stages(
      drain: { _ in ran.withLock { $0 += 1 }; return true },
      flush: { complete in ran.withLock { $0 += 1 }; complete(.saved) })
    let over = QuitFlush.maximumBudget.nextUp
    for (barrier, writer) in [(1e300, 1.0), (1.0, 1e300), (Double.greatestFiniteMagnitude, 1.0), (over, 1.0), (1.0, over)] {
      let start = ContinuousClock.now
      #expect(QuitFlush.run(store: store, writer: nil, barrierTimeout: barrier, writerTimeout: writer, stages: stages) == .timedOut)
      #expect(start.duration(to: .now) < .seconds(1))
    }
    #expect(ran.withLock { $0 } == 0)
    #expect(QuitFlush.run(
      store: store, writer: nil, barrierTimeout: QuitFlush.maximumBudget, writerTimeout: QuitFlush.maximumBudget,
      stages: stages) == .saved)
    #expect(ran.withLock { $0 } == 2)
  }

  @Test func aQuitAfterACompletedOneRunsItsOwnOperation() throws {
    let store = Store()
    let calls = Mutex(0)
    let stages = QuitFlush.Stages(
      drain: { _ in true },
      flush: { complete in
        let call = calls.withLock { value in value += 1; return value }
        let thread = Thread { complete(.failed("call \(call)")) }
        thread.qualityOfService = .background
        thread.start()
      })
    var mismatches = 0
    for call in 1...2000 where QuitFlush.run(store: store, writer: nil, barrierTimeout: 5, writerTimeout: 5, stages: stages) != .failed("call \(call)") {
      mismatches += 1
    }
    #expect(mismatches == 0)
  }

  @Test func oversizedBudgetCannotJoinARunningQuit() throws {
    let store = Store()
    let entered = DispatchSemaphore(value: 0)
    let release = DispatchSemaphore(value: 0)
    let stages = QuitFlush.Stages(
      drain: { _ in entered.signal(); _ = release.wait(timeout: .now() + 5); return true },
      flush: { complete in complete(.saved) })
    let first = Mutex<FlushResult?>(nil)
    let finished = DispatchSemaphore(value: 0)
    Thread.detachNewThread {
      first.withLock { $0 = QuitFlush.run(store: store, writer: nil, barrierTimeout: 5, writerTimeout: 5, stages: stages) }
      finished.signal()
    }
    try #require(entered.wait(timeout: .now() + 5) == .success)
    defer { release.signal() }
    let start = ContinuousClock.now
    #expect(QuitFlush.run(store: store, writer: nil, barrierTimeout: 1, writerTimeout: 1e300, stages: stages) == .timedOut)
    #expect(start.duration(to: .now) < .seconds(1))
    release.signal()
    #expect(finished.wait(timeout: .now() + 5) == .success)
    #expect(first.withLock { $0 } == .saved)
  }

  @Test func quitFailureAndFrozenWriterAreNotSaved() throws {
    let folder = try scratchFolder()
    defer { try? FileManager.default.removeItem(at: folder.url) }
    let launch = try open(folder)
    let store = store(for: launch)
    let writer = PersistenceWriter(store: store, database: launch.database, folder: folder, persisted: launch.persisted)
    defer { writer.freeze(); try? launch.database.close() }
    try launch.database.pool.write { db in
      try db.execute(sql: "CREATE TRIGGER fail_quit BEFORE INSERT ON setting BEGIN SELECT RAISE(FAIL, 'quit row failure'); END")
    }
    store.enqueueSequenced(Command("updateSettings", [["appearance": "dark"]]))
    let failed = QuitFlush.run(store: store, writer: writer, barrierTimeout: 1, writerTimeout: 5)
    #expect(failed.description.contains("quit row failure"))
    #expect(failed != .saved)
    writer.freeze()
    #expect(QuitFlush.run(store: store, writer: writer, barrierTimeout: 5, writerTimeout: 5) == .failed("persistence is frozen"))
  }

  @Test func quitFlushDoesNotHoldIngressWhileWaitingForWriter() throws {
    let folder = try scratchFolder()
    defer { try? FileManager.default.removeItem(at: folder.url) }
    let launch = try open(folder)
    let store = store(for: launch)
    let writer = PersistenceWriter(store: store, database: launch.database, folder: folder, persisted: launch.persisted)
    defer { writer.freeze(); try? launch.database.close() }
    #expect(writer.flush(timeout: 5) == .saved)
    let writing = DispatchSemaphore(value: 0)
    let release = DispatchSemaphore(value: 0)
    let flushed = DispatchSemaphore(value: 0)
    let read = DispatchSemaphore(value: 0)
    let readerRelease = DispatchSemaphore(value: 0)
    let readerFinished = DispatchSemaphore(value: 0)
    let result = Mutex<FlushResult?>(nil)
    defer { release.signal(); readerRelease.signal() }
    try launch.database.pool.writeWithoutTransaction { db in db.trace { event in
      if event.description.contains("wal_checkpoint(FULL)") {
        writing.signal()
        _ = release.wait(timeout: .now() + 5)
      }
    } }
    Thread.detachNewThread {
      let saved = QuitFlush.run(store: store, writer: writer, barrierTimeout: 1, writerTimeout: 2)
      result.withLock { $0 = saved }
      flushed.signal()
    }
    try #require(writing.wait(timeout: .now() + 1) == .success)
    Thread.detachNewThread {
      store.sequence { read.signal(); _ = readerRelease.wait(timeout: .now() + 5) }
      readerFinished.signal()
    }
    #expect(read.wait(timeout: .now() + 1) == .success)
    release.signal()
    #expect(flushed.wait(timeout: .now() + 1) == .success)
    #expect(result.withLock { $0 } == .saved)
    readerRelease.signal()
    #expect(readerFinished.wait(timeout: .now() + 5) == .success)
    try launch.database.pool.writeWithoutTransaction { db in db.trace(nil) }
  }
}
