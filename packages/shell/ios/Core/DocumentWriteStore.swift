import Foundation

final class DocumentWriteStore: @unchecked Sendable {
  typealias Done = (Error?) -> Void
  private struct Staged {
    let url: URL
    let generation: UInt64
    let contents: String
    var waiters: [Done]
  }

  private struct Removal: @unchecked Sendable {
    let url: URL
    let waiters: [Done]
  }

  private let queue = DispatchQueue(label: "solara.documents", qos: .utility)
  private let historyQueue = DispatchQueue(label: "solara.documents.history", qos: .utility)
  private let lock = NSLock()
  private let writer: @Sendable (String, URL) throws -> Void
  private var staged: [String: Staged] = [:]
  private var removing: [String: Int] = [:]
  private var generation: UInt64 = 0
  private var closed = false

  init(writer: @escaping @Sendable (String, URL) throws -> Void = { contents, url in
    if url.lastPathComponent == "history.json" {
      try DurableDocument.write(contents, to: url)
    } else {
      try contents.write(to: url, atomically: true, encoding: .utf8)
    }
  }) {
    self.writer = writer
  }

  func pendingContents(for url: URL) -> String? {
    lock.lock()
    defer { lock.unlock() }
    return staged[url.lastPathComponent]?.contents
  }

  func pendingNames() -> DocumentListing.Pending {
    lock.lock()
    defer { lock.unlock() }
    return DocumentListing.Pending(staged: Set(staged.keys), removing: Set(removing.keys))
  }

  func write(_ url: URL, contents: String, done: Done? = nil) {
    let key = url.lastPathComponent
    lock.lock()
    if closed {
      lock.unlock()
      done?(CocoaError(.fileWriteNoPermission))
      return
    }
    generation += 1
    let mine = generation
    staged[key] = Staged(url: url, generation: mine, contents: contents, waiters: (staged[key]?.waiters ?? []) + (done.map { [$0] } ?? []))
    lock.unlock()
    lane(key).async { self.land(key, mine, attempt: 0) }
  }

  func remove(_ url: URL) {
    lock.lock()
    if closed { return lock.unlock() }
    generation += 1
    let key = url.lastPathComponent
    let removal = Removal(url: url, waiters: staged.removeValue(forKey: key)?.waiters ?? [])
    removing[key, default: 0] += 1
    lock.unlock()
    lane(key).async {
      try? FileManager.default.removeItem(at: removal.url)
      self.lock.lock()
      self.removing[key] = self.removing[key].flatMap { $0 > 1 ? $0 - 1 : nil }
      self.lock.unlock()
      for waiter in removal.waiters { waiter(nil) }
    }
  }

  private func lane(_ key: String) -> DispatchQueue {
    key == "history.json" ? historyQueue : queue
  }

  private func land(_ key: String, _ generation: UInt64, attempt: Int) {
    lock.lock()
    guard let save = staged[key], save.generation == generation else { return lock.unlock() }
    lock.unlock()
    var failure: Error?
    do {
      try writer(save.contents, save.url)
    } catch {
      failure = error
    }
    lock.lock()
    var waiters: [Done] = []
    if staged[key]?.generation == generation {
      waiters = staged[key]!.waiters
      if failure == nil { staged[key] = nil } else { staged[key]!.waiters = [] }
    }
    lock.unlock()
    for waiter in waiters { waiter(failure) }
    guard let failure else { return }
    NSLog("Saving \(key) failed (try \(attempt + 1)): \(failure.localizedDescription)")
    let delay = min(60.0, 2.0 * pow(2.0, Double(min(attempt, 5))))
    lane(key).asyncAfter(deadline: .now() + delay) { self.land(key, generation, attempt: attempt + 1) }
  }

  func close() {
    lock.lock()
    closed = true
    lock.unlock()
  }

  @discardableResult
  func flush() -> Bool {
    queue.sync {
      lock.lock()
      let keys = staged.keys.filter { $0 != "history.json" }
      lock.unlock()
      for key in keys {
        lock.lock()
        let generation = staged[key]?.generation
        lock.unlock()
        if let generation { land(key, generation, attempt: 99) }
      }
    }
    lock.lock()
    defer { lock.unlock() }
    return staged.keys.allSatisfy { $0 == "history.json" }
  }
}
