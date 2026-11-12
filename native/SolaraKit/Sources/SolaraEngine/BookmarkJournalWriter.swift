import Foundation

final class BookmarkJournalWriter: @unchecked Sendable {
  typealias Completion = @Sendable (Error?) -> Void
  typealias Operation = @Sendable (BookmarkCoordinator) -> Completion
  private final class Batch: @unchecked Sendable {
    var operations: [Operation] = []
  }

  private final class Quit: @unchecked Sendable {
    var result: Result<Void, Error>?
    var waiters: [@Sendable (Result<Void, Error>) -> Void] = []
  }

  let queue = DispatchQueue(label: "app.solara.bookmarks.journal", qos: .utility)
  private let lock = NSLock()
  private var pending: Batch?
  private var closing = false
  private var quit: Quit?

  var admissionsClosed: Bool { lock.lock(); defer { lock.unlock() }; return closing }

  func enqueue<T: Sendable>(_ operation: @escaping @Sendable (BookmarkCoordinator) throws -> T, process: @escaping @Sendable ([Operation]) -> Void, completion: @escaping @Sendable (Result<T, Error>) -> Void) {
    lock.lock()
    guard !closing else { lock.unlock(); completion(.failure(BookmarkPendingStoreError.unavailable)); return }
    let batch: Batch
    if let pending { batch = pending }
    else {
      batch = Batch()
      pending = batch
      queue.async { [self] in
        lock.lock()
        if pending === batch { pending = nil }
        let operations = batch.operations
        lock.unlock()
        process(operations)
      }
    }
    batch.operations.append { staged in
      let result = Result { try operation(staged) }
      return { failure in completion(failure.map { .failure($0) } ?? result) }
    }
    lock.unlock()
  }

  func schedule(_ operation: @escaping @Sendable () -> Void) {
    lock.lock()
    pending = nil
    queue.async(execute: operation)
    lock.unlock()
  }

  func settle() {
    lock.lock()
    pending = nil
    lock.unlock()
    queue.sync {}
  }

  func beginQuit(flush: @escaping @Sendable (@Sendable () -> Bool) throws -> Void, completion: @escaping @Sendable (Result<Void, Error>) -> Void) {
    lock.lock()
    if let quit {
      if let result = quit.result { lock.unlock(); completion(result) }
      else { quit.waiters.append(completion); lock.unlock() }
      return
    }
    let attempt = Quit()
    attempt.waiters.append(completion)
    quit = attempt
    closing = true
    pending = nil
    queue.async { [self] in
      let result = Result {
        try flush {
          self.lock.lock()
          defer { self.lock.unlock() }
          return self.closing && self.quit === attempt
        }
      }
      lock.lock()
      attempt.result = result
      let waiters = attempt.waiters
      attempt.waiters.removeAll()
      lock.unlock()
      for waiter in waiters { waiter(result) }
    }
    lock.unlock()
  }

  func cancelQuit() {
    lock.lock()
    closing = false
    quit = nil
    lock.unlock()
  }
}

final class BookmarkJournalBarrier: @unchecked Sendable {
  private let lock = NSLock()
  private var result: Result<Void, Error>?
  private var waiters: [CheckedContinuation<Void, Error>] = []

  func complete(_ result: Result<Void, Error>) {
    lock.lock()
    self.result = result
    let captured = waiters
    waiters.removeAll()
    lock.unlock()
    for waiter in captured { waiter.resume(with: result) }
  }

  func wait() async throws {
    try await withCheckedThrowingContinuation { continuation in
      lock.lock()
      if let result { lock.unlock(); continuation.resume(with: result) }
      else { waiters.append(continuation); lock.unlock() }
    }
  }
}
