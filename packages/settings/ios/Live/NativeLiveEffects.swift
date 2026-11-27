import SolaraShell
import Foundation
import SolaraLive

final class RefusingRedirects: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
  func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse, newRequest request: URLRequest) async -> URLRequest? {
    nil
  }
}

struct NativeLiveHTTP: LiveHTTPClient {
  var session: URLSession = .shared
  var followsRedirects = true

  func send(_ request: LiveHTTPRequest) async throws -> LiveHTTPResponse {
    guard let url = URL(string: request.url) else { throw URLError(.badURL) }
    var task = URLRequest(url: url)
    task.httpMethod = request.method
    task.httpBody = request.body
    for (name, value) in request.headers { task.setValue(value, forHTTPHeaderField: name) }
    let (body, response) = try await session.data(for: task, delegate: followsRedirects && request.followsRedirects ? nil : RefusingRedirects())
    guard let response = response as? HTTPURLResponse else { throw URLError(.badServerResponse) }
    var headers: [String: String] = [:]
    for (name, value) in response.allHeaderFields { headers[String(describing: name)] = String(describing: value) }
    return LiveHTTPResponse(status: response.statusCode, headers: headers, body: body)
  }
}

struct NativeLiveSecrets: LiveSecretStore {
  let read: @Sendable (String) -> String?
  let write: @Sendable (String, String) -> Bool
  let delete: @Sendable (String) -> Bool

  init(
    read: @escaping @Sendable (String) -> String? = { KeychainModule.readSecret($0) },
    write: @escaping @Sendable (String, String) -> Bool = { KeychainModule.writeSecret($0, $1) },
    delete: @escaping @Sendable (String) -> Bool = { KeychainModule.deleteSecret($0) }
  ) {
    self.read = read
    self.write = write
    self.delete = delete
  }

  func secret(account: String) async -> String? { read(account) }
  func setSecret(_ secret: String, account: String) -> Bool { write(account, secret) }
  func deleteSecret(account: String) async -> Bool { delete(account) }
}

struct NativeLiveCalendar: LiveCalendarProvider {
  let fixture: Bool
  let launchedAt: Double
  let readFixture: @Sendable () -> String?

  init(fixture: Bool, launchedAt: Double, readFixture: @escaping @Sendable () -> String? = { DocumentStore.read(CalendarFixture.documentName) }) {
    self.fixture = fixture
    self.launchedAt = launchedAt
    self.readFixture = readFixture
  }

  func authorization() async -> CalendarAuthorization {
    if fixture { return .fixture }
    let status = await CalendarModule.liveAuthorization()
    return CalendarAuthorization(rawValue: status) ?? .notDetermined
  }

  func requestAccess() async -> Bool {
    if fixture { return true }
    return await CalendarModule.liveRequestAccess()
  }

  func calendars() async throws -> [SystemCalendar] {
    if fixture { return try loadFixture().calendars }
    return try decode(await MainActor.run { try JSONSerialization.data(withJSONObject: CalendarModule.liveCalendars()) })
  }

  func events(start: Double, end: Double, calendarIds: [String]) async throws -> [CalendarEvent] {
    if fixture {
      return try loadFixture().events.filter { calendarIds.contains($0.calendarId) }
    }
    return try decode(
      await MainActor.run { try JSONSerialization.data(withJSONObject: CalendarModule.liveEvents(start: start, end: end, calendarIds: calendarIds)) })
  }

  @MainActor func observeChanges(_ changed: @escaping @Sendable () -> Void) -> NSObjectProtocol? {
    fixture ? nil : CalendarModule.observeLiveChanges(changed)
  }

  private func loadFixture() throws -> (calendars: [SystemCalendar], events: [CalendarEvent]) {
    let text = readFixture() ?? #"{"calendars":[],"events":[]}"#
    return try LiveJSON.decode(CalendarFixture.self, from: text).resolved(launchedAt: launchedAt)
  }

  private func decode<T: Decodable>(_ data: Data) throws -> [T] {
    try JSONDecoder().decode([T].self, from: data)
  }
}

struct NativeLiveNotifier: LiveNotifier {
  let postEffect: @Sendable (LiveNotification) async -> Bool
  let removeEffect: @Sendable ([String]) async -> Void

  init(
    post: @escaping @Sendable (LiveNotification) async -> Bool = {
      await ShellLiveNotifications.post(id: $0.id, title: $0.title, body: $0.body, data: $0.data)
    },
    remove: @escaping @Sendable ([String]) async -> Void = { await ShellLiveNotifications.remove(ids: $0) }
  ) {
    postEffect = post
    removeEffect = remove
  }

  func post(_ notification: LiveNotification) async -> Bool { await postEffect(notification) }
  func remove(ids: [String]) async { await removeEffect(ids) }
}
