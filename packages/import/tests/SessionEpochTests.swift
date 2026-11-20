import Foundation
import XCTest
@testable import SolaraLegacyImportCore

final class SessionEpochTests: XCTestCase {
  let cookie = Cookie(domain: ".example.test", name: "a", value: SecretBytes(count: 1))
  let deadline: TimeInterval = 10

  func makeSession() -> ImportSession { ImportSession(importer: Importer(discovery: Fixtures.discovery())) }

  func testVaultDropsWorkThatFinishesAfterForget() {
    let epoch = ImportEpoch()
    let vault = ImportVault()
    let started = epoch.current
    let next = epoch.advance()
    vault.discardAll(before: next)
    XCTAssertNil(vault.keep(cookies: [cookie], addresses: [], cards: [], epoch: epoch, started: started))
    XCTAssertEqual(vault.count, 0)
    XCTAssertNotNil(vault.keep(cookies: [cookie], addresses: [], cards: [], epoch: epoch, started: next))
    XCTAssertEqual(vault.count, 1)
  }

  func testForgetWaitingOnAKeepThatPassedItsCheckStillClearsIt() {
    let epoch = ImportEpoch()
    let vault = ImportVault()
    let started = epoch.current
    let checked = DispatchSemaphore(value: 0)
    let kept = DispatchSemaphore(value: 0)
    vault.betweenCheckAndInsert.set {
      checked.signal()
      Thread.sleep(forTimeInterval: 0.2)
    }
    DispatchQueue.global().async {
      _ = vault.keep(cookies: [self.cookie], addresses: [], cards: [], epoch: epoch, started: started)
      kept.signal()
    }
    XCTAssertEqual(checked.wait(timeout: .now() + deadline), .success)
    vault.betweenCheckAndInsert.set(nil)
    let next = epoch.advance()
    vault.discardAll(before: next)
    XCTAssertEqual(kept.wait(timeout: .now() + deadline), .success)
    XCTAssertEqual(vault.count, 0)
  }

  func testConcurrentKeepsNeverOutliveForget() {
    for _ in 0..<20 {
      let epoch = ImportEpoch()
      let vault = ImportVault()
      let started = epoch.current
      DispatchQueue.concurrentPerform(iterations: 64) { i in
        if i == 32 {
          vault.discardAll(before: epoch.advance())
        } else {
          _ = vault.keep(cookies: [cookie], addresses: [], cards: [], epoch: epoch, started: started)
        }
      }
      XCTAssertEqual(vault.count, 0)
    }
  }

  func testFinishRemovesOnlyItsOwnCancellation() {
    let jobs = ImportJobs()
    let first = jobs.start("job")
    let second = jobs.start("job")
    jobs.finish("job", first)
    jobs.cancel("job")
    XCTAssertFalse(first.isCancelled)
    XCTAssertTrue(second.isCancelled)
  }

  func testCancelAllCancelsEveryRunningJob() {
    let jobs = ImportJobs()
    let a = jobs.start("a")
    let b = jobs.start("b")
    jobs.cancelAll()
    XCTAssertTrue(a.isCancelled)
    XCTAssertTrue(b.isCancelled)
    let c = jobs.start("a")
    jobs.cancel("a")
    XCTAssertTrue(c.isCancelled)
  }

  func testUnlockThatFinishesAfterForgetLeavesTheBrowserLocked() {
    let importer = Importer(discovery: Fixtures.discovery())
    let entered = DispatchSemaphore(value: 0)
    let release = DispatchSemaphore(value: 0)
    let done = DispatchSemaphore(value: 0)
    DispatchQueue.global().async {
      try? importer.unlock(browserId: "chrome", secret: { _, _ in
        entered.signal()
        _ = release.wait(timeout: .now() + 10)
        return Fixtures.chromiumSecret
      })
      done.signal()
    }
    XCTAssertEqual(entered.wait(timeout: .now() + deadline), .success)
    importer.forgetKeys()
    release.signal()
    XCTAssertEqual(done.wait(timeout: .now() + deadline), .success)
    XCTAssertFalse(importer.isUnlocked("chrome"))
  }

  func testUnlockBlockedInTheKeychainWhenTheSessionEndsStaysLocked() {
    let session = makeSession()
    let owner = session.claim()
    let started = session.begin(owner: owner)!
    let entered = DispatchSemaphore(value: 0)
    let release = DispatchSemaphore(value: 0)
    let done = DispatchSemaphore(value: 0)
    DispatchQueue.global().async {
      try? session.importer.unlock(browserId: "chrome", session: (session.epoch, started), secret: { _, _ in
        entered.signal()
        _ = release.wait(timeout: .now() + 10)
        return Fixtures.chromiumSecret
      })
      done.signal()
    }
    XCTAssertEqual(entered.wait(timeout: .now() + deadline), .success)
    session.forget(owner: owner)
    release.signal()
    XCTAssertEqual(done.wait(timeout: .now() + deadline), .success)
    XCTAssertFalse(session.importer.isUnlocked("chrome"))
  }

  func testWorkQueuedBehindABlockerBeforeAForgetLandsNothing() throws {
    for browserId in ["chrome", "firefox"] {
      let session = makeSession()
      let owner = session.claim()
      let functions = DispatchQueue(label: "expo.modules.AsyncFunctionQueue.standin")
      let work = DispatchQueue(label: "work.standin", attributes: .concurrent)
      let blocker = DispatchSemaphore(value: 0)
      let finished = DispatchGroup()
      var outcomes: [String] = []
      let outcomesLock = NSLock()
      func record(_ s: String) { outcomesLock.withLock { outcomes.append(s) } }

      functions.async { _ = blocker.wait(timeout: .now() + 10) }
      finished.enter()
      functions.async {
        guard let job = session.start("job", owner: owner) else { record("rejected"); finished.leave(); return }
        work.async {
          defer { session.jobs.finish("job", job.cancellation); finished.leave() }
          let token = session.keep(cookies: [self.cookie], addresses: [], cards: [], started: job.started)
          record(session.isCurrent(job.started) ? "resolved \(token != nil)" : "cancelled")
        }
      }
      finished.enter()
      functions.async {
        guard let started = session.begin(owner: owner) else { record("rejected"); finished.leave(); return }
        work.async {
          try? session.importer.unlock(browserId: browserId, primaryPassword: "pw", session: (session.epoch, started),
                                       secret: { _, _ in Fixtures.chromiumSecret })
          record(session.isCurrent(started) ? "unlocked" : "cancelled")
          finished.leave()
        }
      }
      functions.async { session.forget(owner: owner) }
      blocker.signal()
      XCTAssertEqual(finished.wait(timeout: .now() + deadline), .success)
      functions.sync {}
      XCTAssertFalse(outcomes.contains { $0.hasPrefix("resolved") || $0 == "unlocked" }, "\(browserId): \(outcomes)")
      XCTAssertFalse(session.importer.isUnlocked(browserId), browserId)
      XCTAssertEqual(session.vault.count, 0, browserId)
    }
  }

  func testSwiftUnlockWithNoForgetUnlocksAndReportsTrue() async {
    let session = makeSession()
    _ = session.claim()
    let work = DispatchQueue(label: "work.standin", attributes: .concurrent)
    let unlocked = await session.unlock("chrome", on: work, secret: { _, _ in Fixtures.chromiumSecret })
    XCTAssertTrue(unlocked)
    XCTAssertTrue(session.importer.isUnlocked("chrome"))
  }

  func testSwiftUnlockReportsFalseWhenAForgetLandsDuringItsWork() async {
    let session = makeSession()
    let owner = session.claim()
    let work = DispatchQueue(label: "work.standin", attributes: .concurrent)
    let entered = DispatchSemaphore(value: 0)
    let release = DispatchSemaphore(value: 0)
    let forgotten = Task.detached {
      XCTAssertEqual(entered.wait(timeout: .now() + 10), .success)
      session.forget(owner: owner)
      release.signal()
    }
    let unlocked = await session.unlock("chrome", on: work, secret: { _, _ in
      entered.signal()
      _ = release.wait(timeout: .now() + 10)
      return Fixtures.chromiumSecret
    })
    await forgotten.value
    XCTAssertFalse(unlocked)
    XCTAssertFalse(session.importer.isUnlocked("chrome"))
  }

  func testSwiftUnlockLosesToAJSForgetAlreadyQueued() async {
    let session = makeSession()
    let owner = session.claim()
    let functions = DispatchQueue(label: "expo.modules.AsyncFunctionQueue.standin")
    let work = DispatchQueue(label: "work.standin", attributes: .concurrent)
    let blocker = DispatchSemaphore(value: 0)
    let forgot = DispatchSemaphore(value: 0)
    functions.async { _ = blocker.wait(timeout: .now() + 10) }
    functions.async {
      session.forget(owner: owner)
      forgot.signal()
    }
    let unlocked = await session.unlock("chrome", on: work, secret: { _, _ in Fixtures.chromiumSecret })
    XCTAssertTrue(unlocked)
    XCTAssertTrue(session.importer.isUnlocked("chrome"))
    blocker.signal()
    XCTAssertEqual(forgot.wait(timeout: .now() + deadline), .success)
    XCTAssertFalse(session.importer.isUnlocked("chrome"))
  }

  func testOldOwnersLateBodyAfterANewCreateIsRejected() throws {
    let session = makeSession()
    let old = session.claim()
    let new = session.claim()
    XCTAssertNil(session.begin(owner: old))
    XCTAssertNil(session.start("job", owner: old))
    let started = try XCTUnwrap(session.begin(owner: new))
    try session.importer.unlock(browserId: "chrome", session: (session.epoch, started), secret: { _, _ in Fixtures.chromiumSecret })
    XCTAssertNotNil(session.keep(cookies: [cookie], addresses: [], cards: [], started: started))

    session.forget(owner: old)
    XCTAssertTrue(session.isCurrent(started))
    XCTAssertTrue(session.importer.isUnlocked("chrome"))
    XCTAssertEqual(session.vault.count, 1)

    session.forget(owner: new)
    XCTAssertFalse(session.importer.isUnlocked("chrome"))
    XCTAssertEqual(session.vault.count, 0)
  }

  func testOldBodyThatBeganBeforeANewCreateDropsItsWork() throws {
    let session = makeSession()
    let old = session.claim()
    let started = try XCTUnwrap(session.begin(owner: old))
    _ = session.claim()
    try session.importer.unlock(browserId: "chrome", session: (session.epoch, started), secret: { _, _ in Fixtures.chromiumSecret })
    XCTAssertNil(session.keep(cookies: [cookie], addresses: [], cards: [], started: started))
    XCTAssertFalse(session.importer.isUnlocked("chrome"))
    XCTAssertFalse(session.isCurrent(started))
  }

  func testALateClearSparesTheNewEpochsWork() throws {
    let session = makeSession()
    let owner = session.claim()
    let old = try XCTUnwrap(session.begin(owner: owner))
    let oldJob = try XCTUnwrap(session.start("old", owner: owner))
    try session.importer.unlock(browserId: "firefox", primaryPassword: "pw", session: (session.epoch, old))
    XCTAssertNotNil(session.keep(cookies: [cookie], addresses: [], cards: [], started: old))

    let next = session.epoch.advance()
    let newJob = try XCTUnwrap(session.start("new", owner: owner))
    try session.importer.unlock(browserId: "chrome", session: (session.epoch, next), secret: { _, _ in Fixtures.chromiumSecret })
    XCTAssertNotNil(session.keep(cookies: [cookie], addresses: [], cards: [], started: next))
    session.clear(before: next)

    XCTAssertTrue(oldJob.cancellation.isCancelled)
    XCTAssertFalse(newJob.cancellation.isCancelled)
    XCTAssertFalse(session.importer.isUnlocked("firefox"))
    XCTAssertTrue(session.importer.isUnlocked("chrome"))
    XCTAssertEqual(session.vault.count, 1)
  }

  func testForgetCancelsAStartedJobAndTheNextStartRuns() throws {
    let session = makeSession()
    let owner = session.claim()
    let job = try XCTUnwrap(session.start("job", owner: owner))
    XCTAssertFalse(job.cancellation.isCancelled)
    session.forget(owner: owner)
    XCTAssertTrue(job.cancellation.isCancelled)
    let again = try XCTUnwrap(session.start("job", owner: owner))
    XCTAssertFalse(again.cancellation.isCancelled)
  }

  func testStartRechecksTheEpochAfterRegisteringItsJob() throws {
    let session = makeSession()
    let owner = session.claim()
    session.afterJobStart.set { session.forget(owner: owner) }
    XCTAssertNil(session.start("job", owner: owner))
    XCTAssertEqual(session.jobs.count, 0)
    session.afterJobStart.set(nil)
    let job = try XCTUnwrap(session.start("job", owner: owner))
    XCTAssertFalse(job.cancellation.isCancelled)
    XCTAssertEqual(session.jobs.count, 1)
  }

  func testSessionForgetClearsEverythingAndDropsLateWork() throws {
    let session = makeSession()
    let owner = session.claim()
    let started = try XCTUnwrap(session.begin(owner: owner))
    let unlockSession = (epoch: session.epoch, started: started)
    try session.importer.unlock(browserId: "chrome", session: unlockSession, secret: { _, _ in Fixtures.chromiumSecret })
    try session.importer.unlock(browserId: "firefox", primaryPassword: "pw", session: unlockSession)
    let job = try XCTUnwrap(session.start("job", owner: owner))
    XCTAssertNotNil(session.keep(cookies: [cookie], addresses: [], cards: [], started: started))

    session.forget(owner: owner)

    XCTAssertTrue(job.cancellation.isCancelled)
    XCTAssertFalse(session.importer.isUnlocked("chrome"))
    XCTAssertFalse(session.importer.isUnlocked("firefox"))
    XCTAssertEqual(session.vault.count, 0)
    XCTAssertNil(session.keep(cookies: [cookie], addresses: [], cards: [], started: started))
    try session.importer.unlock(browserId: "chrome", session: unlockSession, secret: { _, _ in Fixtures.chromiumSecret })
    try session.importer.unlock(browserId: "firefox", primaryPassword: "pw", session: unlockSession)
    XCTAssertFalse(session.importer.isUnlocked("chrome"))
    XCTAssertFalse(session.importer.isUnlocked("firefox"))
  }

  func testFirefoxUnlockStoresItsPassword() throws {
    let importer = Importer(discovery: Fixtures.discovery())
    try importer.unlock(browserId: "firefox", primaryPassword: "pw")
    XCTAssertTrue(importer.isUnlocked("firefox"))
    importer.forgetKeys()
    XCTAssertFalse(importer.isUnlocked("firefox"))
  }
}
