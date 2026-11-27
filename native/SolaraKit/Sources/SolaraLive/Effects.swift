import Foundation

public struct LiveHTTPRequest: Sendable, Equatable {
  public var method: String
  public var url: String
  public var headers: [String: String]
  public var body: Data?
  public var followsRedirects: Bool

  public init(method: String = "GET", url: String, headers: [String: String] = [:], body: Data? = nil, followsRedirects: Bool = true) {
    self.method = method
    self.url = url
    self.headers = headers
    self.body = body
    self.followsRedirects = followsRedirects
  }

  public var bodyText: String? { body.map { String(decoding: $0, as: UTF8.self) } }
}

public struct LiveHTTPResponse: Sendable, Equatable {
  public var status: Int
  public var headers: [String: String]
  public var body: Data

  public init(status: Int, headers: [String: String] = [:], body: Data = Data()) {
    self.status = status
    self.headers = headers
    self.body = body
  }

  public func header(_ name: String) -> String? {
    let lower = name.lowercased()
    return headers.first { $0.key.lowercased() == lower }?.value
  }
}

public protocol LiveHTTPClient: Sendable {
  func send(_ request: LiveHTTPRequest) async throws -> LiveHTTPResponse
}

public protocol LiveSecretStore: Sendable {
  func secret(account: String) async -> String?
  func setSecret(_ secret: String, account: String) -> Bool
  func deleteSecret(account: String) async -> Bool
}

public protocol LiveClock: Sendable {
  func now() -> Double
  func sleep(milliseconds: Double) async throws
}

public struct SystemLiveClock: LiveClock {
  public init() {}

  public func now() -> Double { (Date().timeIntervalSince1970 * 1000).rounded(.down) }

  public func sleep(milliseconds: Double) async throws {
    try await Task.sleep(nanoseconds: UInt64(max(0, milliseconds) * 1_000_000))
  }
}

public enum CalendarAuthorization: String, Codable, Sendable {
  case fullAccess, writeOnly, denied, restricted, notDetermined, fixture
}

public protocol LiveCalendarProvider: Sendable {
  func authorization() async -> CalendarAuthorization
  func requestAccess() async -> Bool
  func calendars() async throws -> [SystemCalendar]
  func events(start: Double, end: Double, calendarIds: [String]) async throws -> [CalendarEvent]
}

public protocol LiveAuthPresenter: Sendable {
  func authorize(url: String, redirectPrefix: String) async throws -> String
}

public struct LiveNotification: Sendable, Equatable {
  public var id: String
  public var title: String
  public var body: String
  public var data: [String: String]
}

public protocol LiveNotifier: Sendable {
  func post(_ notification: LiveNotification) async -> Bool
  func remove(ids: [String]) async
}

public enum LiveDocumentRead: Sendable, Equatable {
  case missing
  case contents(String)
  case failure(String)
}

public protocol LiveDocumentStore: Sendable {
  func read(_ name: String) -> String?
  func readStatus(_ name: String) -> LiveDocumentRead
  func write(_ name: String, _ text: String) throws
}

public extension LiveDocumentStore {
  func readStatus(_ name: String) -> LiveDocumentRead { read(name).map(LiveDocumentRead.contents) ?? .missing }
}

public struct LiveEnvironment: Sendable, Equatable {
  public var mockBase: String?
  public var isolatedDataDirectory: Bool
  public var separateSlowTimers: Bool
  public var safeMode: Bool
  public var calendarFixture: Bool

  public func checkRequest(_ url: String) throws {
    guard isolatedDataDirectory else { return }
    guard let mockBase, let mock = URLComponents(string: mockBase), mock.scheme == "http",
      ["127.0.0.1", "::1", "localhost"].contains(mock.host ?? ""), mock.user == nil, mock.password == nil,
      let target = URLComponents(string: url), target.host == mock.host, target.port == mock.port, target.scheme == mock.scheme else {
      throw LiveError(.network, "Isolated Live Folders requires a loopback SOLARA_LIVE_MOCK URL")
    }
  }

  public init(mockBase: String? = nil, calendarFixture: Bool = false, isolatedDataDirectory: Bool = false, separateSlowTimers: Bool = false, safeMode: Bool = false) {
    self.safeMode = safeMode
    self.mockBase = mockBase
    self.calendarFixture = calendarFixture
    self.isolatedDataDirectory = isolatedDataDirectory
    self.separateSlowTimers = separateSlowTimers
  }
}

public struct LiveEffects: Sendable {
  public var http: any LiveHTTPClient
  public var secrets: any LiveSecretStore
  public var clock: any LiveClock
  public var calendar: any LiveCalendarProvider
  public var auth: any LiveAuthPresenter
  public var notifier: any LiveNotifier
  public var documents: any LiveDocumentStore
  public var environment: LiveEnvironment
  public var closeFolderTabs: @Sendable (String) async throws -> Void

  public init(
    http: any LiveHTTPClient, secrets: any LiveSecretStore, clock: any LiveClock = SystemLiveClock(),
    calendar: any LiveCalendarProvider, auth: any LiveAuthPresenter, notifier: any LiveNotifier,
    documents: any LiveDocumentStore, environment: LiveEnvironment = LiveEnvironment(),
    closeFolderTabs: @escaping @Sendable (String) async throws -> Void = { _ in }
  ) {
    self.http = http
    self.secrets = secrets
    self.clock = clock
    self.calendar = calendar
    self.auth = auth
    self.notifier = notifier
    self.documents = documents
    self.environment = environment
    self.closeFolderTabs = closeFolderTabs
  }
}
