import Foundation
import XCTest
@testable import SolaraShellCore

final class DocumentWriteStoreTests: XCTestCase {
  func testPairingDocumentsRequireDurableBarriers() {
    for name in ["sync.json", "sync-bootstrap-abc-1.nns", "sync-pairing-marker.json"] {
      XCTAssertTrue(DocumentWriteStore.requiresDurability(name))
    }
    XCTAssertFalse(DocumentWriteStore.requiresDurability("session.json"))
  }

  func testCoalescedPairingWriteCannotAcknowledgeDifferentBytes() throws {
    let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: folder) }
    let entered = DispatchSemaphore(value: 0), release = DispatchSemaphore(value: 0)
    let firstDone = DispatchSemaphore(value: 0), secondDone = DispatchSemaphore(value: 0)
    let attempt = Attempt()
    let writes = DocumentWriteStore { contents, url in
      if attempt.next() == 1 {
        entered.signal()
        guard release.wait(timeout: .now() + 3) == .success else { throw POSIXError(.ETIMEDOUT) }
      }
      try DurableDocument.write(contents, to: url)
    }
    let state = SaveResult()
    let url = folder.appendingPathComponent("sync.json")
    writes.write(url, contents: "first") { error in state.first(error); firstDone.signal() }
    XCTAssertEqual(entered.wait(timeout: .now() + 1), .success)
    writes.write(url, contents: "second") { _ in secondDone.signal() }
    release.signal()
    XCTAssertEqual(firstDone.wait(timeout: .now() + 2), .success)
    XCTAssertEqual(secondDone.wait(timeout: .now() + 2), .success)
    XCTAssertTrue(state.failed)
    XCTAssertEqual(try String(contentsOf: url), "second")
  }

  private final class SaveResult: @unchecked Sendable {
    private let lock = NSLock()
    private var failure = false
    var failed: Bool { lock.lock(); defer { lock.unlock() }; return failure }
    func first(_ error: Error?) { lock.lock(); failure = error != nil; lock.unlock() }
  }

  private final class Attempt: @unchecked Sendable {
    let lock = NSLock()
    var count = 0

    func next() -> Int {
      lock.lock()
      defer { lock.unlock() }
      count += 1
      return count
    }
  }

  func testQuitFlushDoesNotJoinAnAlreadyRunningHistoryWrite() throws {
    let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: folder) }
    let history = folder.appendingPathComponent("history.json")
    try Data("original".utf8).write(to: history)
    let entered = DispatchSemaphore(value: 0)
    let release = DispatchSemaphore(value: 0)
    let completed = DispatchSemaphore(value: 0)
    let flushed = DispatchSemaphore(value: 0)
    let writes = DocumentWriteStore { contents, url in
      if url.lastPathComponent == "history.json" {
        entered.signal()
        guard release.wait(timeout: .now() + 3) == .success else { throw POSIXError(.ETIMEDOUT) }
      }
      try DurableDocument.write(contents, to: url)
    }
    writes.write(history, contents: "redacted") { _ in completed.signal() }
    guard entered.wait(timeout: .now() + 1) == .success else {
      release.signal()
      return XCTFail("The history writer did not start")
    }
    defer { release.signal() }
    writes.write(folder.appendingPathComponent("session.json"), contents: "session")
    DispatchQueue.global().async {
      if writes.flush() { flushed.signal() }
    }
    let result = flushed.wait(timeout: .now() + 0.5)
    let pending = writes.pendingContents(for: history)
    let saved = try String(contentsOf: history, encoding: .utf8)
    release.signal()
    XCTAssertEqual(completed.wait(timeout: .now() + 1), .success)
    XCTAssertEqual(result, .success)
    XCTAssertEqual(pending, "redacted")
    XCTAssertEqual(saved, "original")
    XCTAssertEqual(try String(contentsOf: folder.appendingPathComponent("session.json"), encoding: .utf8), "session")
  }

  func testQuitFlushLeavesFailedHistoryQueuedForRetry() throws {
    let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: folder) }
    let history = folder.appendingPathComponent("history.json")
    try Data("original".utf8).write(to: history)
    let failed = DispatchSemaphore(value: 0)
    let retried = DispatchSemaphore(value: 0)
    let landed = DispatchSemaphore(value: 0)
    let release = DispatchSemaphore(value: 0)
    let attempt = Attempt()
    let writes = DocumentWriteStore { contents, url in
      if attempt.next() == 1 { throw POSIXError(.EIO) }
      retried.signal()
      guard release.wait(timeout: .now() + 3) == .success else { throw POSIXError(.ETIMEDOUT) }
      try DurableDocument.write(contents, to: url)
      landed.signal()
    }
    writes.write(history, contents: "redacted") { error in
      if error != nil { failed.signal() }
    }
    guard failed.wait(timeout: .now() + 1) == .success else {
      release.signal()
      return XCTFail("The injected history failure did not complete")
    }
    defer { release.signal() }
    let flushed = DispatchSemaphore(value: 0)
    DispatchQueue.global().async {
      if writes.flush() { flushed.signal() }
    }
    let result = flushed.wait(timeout: .now() + 0.5)
    let pending = writes.pendingContents(for: history)
    let saved = try String(contentsOf: history, encoding: .utf8)
    let retryResult = retried.wait(timeout: .now() + 3)
    release.signal()
    XCTAssertEqual(landed.wait(timeout: .now() + 1), .success)
    XCTAssertEqual(result, .success)
    XCTAssertEqual(pending, "redacted")
    XCTAssertEqual(saved, "original")
    XCTAssertEqual(retryResult, .success)
    XCTAssertEqual(try String(contentsOf: history, encoding: .utf8), "redacted")
    XCTAssertTrue(writes.flush())
  }
}
