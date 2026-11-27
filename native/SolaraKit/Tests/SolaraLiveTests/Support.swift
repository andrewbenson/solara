import Foundation
import Testing

@testable import SolaraLive

enum Fixture {
  static func url(_ name: String) -> URL {
    Bundle.module.url(forResource: name, withExtension: nil, subdirectory: "Fixtures")!
  }

  static func data(_ name: String) -> Data { try! Data(contentsOf: url(name)) }
  static func text(_ name: String) -> String { String(decoding: data(name), as: UTF8.self) }
  static func decode<T: Decodable>(_ type: T.Type, _ name: String) -> T { try! JSONDecoder().decode(type, from: data(name)) }

  nonisolated(unsafe) static let golden: [String: Any] = try! JSONSerialization.jsonObject(with: data("golden.json")) as! [String: Any]
}

func canonical(_ object: Any) -> String {
  let data = try! JSONSerialization.data(withJSONObject: object, options: [.sortedKeys, .fragmentsAllowed, .withoutEscapingSlashes])
  return String(decoding: data, as: UTF8.self)
}

func canonical<T: Encodable>(encoding value: T) -> String {
  canonical(try! JSONSerialization.jsonObject(with: try! LiveJSON.encode(value), options: [.fragmentsAllowed]))
}

func decoded<T: Decodable>(_ type: T.Type, _ object: Any) -> T {
  let data = try! JSONSerialization.data(withJSONObject: object, options: [.fragmentsAllowed])
  do {
    return try JSONDecoder().decode(type, from: data)
  } catch {
    Issue.record("decode \(T.self): \(error)")
    fatalError("decode \(T.self): \(error)")
  }
}

final class Locked<Value>: @unchecked Sendable {
  private let lock = NSLock()
  private var value: Value

  init(_ value: Value) { self.value = value }

  func with<R>(_ body: (inout Value) -> R) -> R {
    lock.lock()
    defer { lock.unlock() }
    return body(&value)
  }

  var current: Value { with { $0 } }
}

final class ManualClock: LiveClock, @unchecked Sendable {
  struct Sleeper {
    var id: UUID
    var deadline: Double
    var continuation: CheckedContinuation<Void, Error>
  }

  private let lock = NSLock()
  private var time: Double
  private var sleepers: [Sleeper] = []

  init(_ start: Double = 1_790_000_000_000) { time = start }

  func now() -> Double {
    lock.lock()
    defer { lock.unlock() }
    return time
  }

  var pending: [Double] {
    lock.lock()
    defer { lock.unlock() }
    return sleepers.map(\.deadline).sorted()
  }

  func sleep(milliseconds: Double) async throws {
    let id = UUID()
    try await withTaskCancellationHandler {
      try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
        lock.lock()
        let deadline = time + max(0, milliseconds)
        if Task.isCancelled {
          lock.unlock()
          continuation.resume(throwing: CancellationError())
          return
        }
        if milliseconds <= 0 {
          lock.unlock()
          continuation.resume()
          return
        }
        sleepers.append(Sleeper(id: id, deadline: deadline, continuation: continuation))
        lock.unlock()
      }
    } onCancel: {
      lock.lock()
      let index = sleepers.firstIndex { $0.id == id }
      let sleeper = index.map { sleepers.remove(at: $0) }
      lock.unlock()
      sleeper?.continuation.resume(throwing: CancellationError())
    }
  }

  func advance(by ms: Double) async {
    await settle()
    let target = now() + ms
    while true {
      let ready: [Sleeper]? = lock.withLock {
        guard let due = sleepers.filter({ $0.deadline <= target }).min(by: { $0.deadline < $1.deadline }) else {
          time = target
          return nil
        }
        time = max(time, due.deadline)
        let ready = sleepers.filter { $0.deadline <= time }
        sleepers.removeAll { $0.deadline <= time }
        return ready
      }
      guard let ready else { break }
      for s in ready { s.continuation.resume() }
      await settle()
    }
    await settle()
  }
}

func settle() async {
  for _ in 0..<8 {
    await Task.yield()
    try? await Task.sleep(nanoseconds: 2_000_000)
  }
}

final class FakeHTTP: LiveHTTPClient, @unchecked Sendable {
  typealias Handler = @Sendable (LiveHTTPRequest) async throws -> LiveHTTPResponse
  let log = Locked<[LiveHTTPRequest]>([])
  let handler: Locked<Handler>

  init(_ handler: @escaping Handler = { _ in LiveHTTPResponse(status: 404) }) {
    self.handler = Locked(handler)
  }

  func send(_ request: LiveHTTPRequest) async throws -> LiveHTTPResponse {
    log.with { $0.append(request) }
    return try await handler.current(request)
  }

  var paths: [String] { log.current.map { "\($0.method) \(URLComponents(string: $0.url)?.path ?? $0.url)" } }
}

final class MemorySecrets: LiveSecretStore, @unchecked Sendable {
  let values = Locked<[String: String]>([:])
  func secret(account: String) async -> String? { values.current[account] }
  let allowWrite = Locked(true)
  let deletions = Locked<[String]>([])
  @discardableResult func setSecret(_ secret: String, account: String) -> Bool {
    guard allowWrite.current else { return false }
    values.with { $0[account] = secret }
    return true
  }
  @discardableResult func deleteSecret(account: String) async -> Bool {
    deletions.with { $0.append(account) }
    guard allowWrite.current else { return false }
    _ = values.with { $0.removeValue(forKey: account) }
    return true
  }
}

final class MemoryDocuments: LiveDocumentStore, @unchecked Sendable {
  let docs = Locked<[String: String]>([:])
  let writes = Locked<Int>(0)
  let readFailure = Locked<String?>(nil)
  let writeFailure = Locked<Bool>(false)
  init(_ docs: [String: String] = [:]) { self.docs.with { $0 = docs } }
  func read(_ name: String) -> String? { docs.current[name] }
  func readStatus(_ name: String) -> LiveDocumentRead {
    if let failure = readFailure.current { return .failure(failure) }
    return docs.current[name].map(LiveDocumentRead.contents) ?? .missing
  }
  func write(_ name: String, _ text: String) throws {
    if writeFailure.current { throw LiveError(.other, "disk full") }
    docs.with { $0[name] = text }
    writes.with { $0 += 1 }
  }
}

final class FakeCalendar: LiveCalendarProvider, @unchecked Sendable {
  let access = Locked<CalendarAuthorization>(.notDetermined)
  let grant = Locked<Bool>(true)
  let calendarList = Locked<[SystemCalendar]>([])
  let eventList = Locked<[CalendarEvent]>([])
  let asked = Locked<[(Double, Double, [String])]>([])

  func authorization() async -> CalendarAuthorization { access.current }
  func requestAccess() async -> Bool {
    if grant.current { access.with { $0 = .fullAccess } }
    return grant.current
  }
  func calendars() async throws -> [SystemCalendar] { calendarList.current }
  func events(start: Double, end: Double, calendarIds: [String]) async throws -> [CalendarEvent] {
    asked.with { $0.append((start, end, calendarIds)) }
    return eventList.current.filter { calendarIds.contains($0.calendarId) }
  }
}

final class FakeAuth: LiveAuthPresenter, @unchecked Sendable {
  typealias Respond = @Sendable (String) async throws -> String
  let respond: Locked<Respond>
  let opened = Locked<[String]>([])
  init(_ respond: @escaping Respond = { _ in throw LiveAuthError("Sign-in was cancelled") }) { self.respond = Locked(respond) }
  func authorize(url: String, redirectPrefix: String) async throws -> String {
    opened.with { $0.append(url) }
    return try await respond.current(url)
  }
}

final class RecordingNotifier: LiveNotifier, @unchecked Sendable {
  let posted = Locked<[LiveNotification]>([])
  let removed = Locked<[String]>([])
  let failing = Locked<Bool>(false)
  func post(_ notification: LiveNotification) async -> Bool {
    if failing.current { return false }
    posted.with { $0.append(notification) }
    return true
  }
  func remove(ids: [String]) async { removed.with { $0 += ids } }
}

struct Rig {
  let engine: LiveEngine
  let clock: ManualClock
  let http: FakeHTTP
  let secrets: MemorySecrets
  let documents: MemoryDocuments
  let calendar: FakeCalendar
  let auth: FakeAuth
  let notifier: RecordingNotifier

  init(documents: [String: String] = [:], environment: LiveEnvironment = LiveEnvironment(), http: FakeHTTP = FakeHTTP(), state: LiveState? = nil, closeFolderTabs: @escaping @Sendable (String) async throws -> Void = { _ in }) {
    clock = ManualClock()
    self.http = http
    secrets = MemorySecrets()
    self.documents = MemoryDocuments(documents)
    calendar = FakeCalendar()
    auth = FakeAuth()
    notifier = RecordingNotifier()
    engine = LiveEngine(
      effects: LiveEffects(
        http: http, secrets: secrets, clock: clock, calendar: calendar, auth: auth, notifier: notifier, documents: self.documents,
        environment: environment, closeFolderTabs: closeFolderTabs),
      state: state)
  }
}

func json(_ object: Any, status: Int = 200, headers: [String: String] = [:]) -> LiveHTTPResponse {
  LiveHTTPResponse(status: status, headers: headers, body: try! JSONSerialization.data(withJSONObject: object, options: [.fragmentsAllowed]))
}

func jsonObject(_ data: Data?) -> [String: Any] {
  guard let data, let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return [:] }
  return object
}
