import Darwin
import Foundation
import Synchronization
import Testing
@testable import SolaraOmnibox

private final class BangHTTPServer: @unchecked Sendable {
  struct Reply: Sendable {
    var status: Int
    var headers: [String: String] = [:]
    var body = ""
  }

  private let socketFD: Int32
  private let state = Mutex((stopped: false, requests: [String]()))
  let url: URL

  init(_ replies: [Reply]) throws {
    let fd = Darwin.socket(AF_INET, SOCK_STREAM, 0)
    guard fd >= 0 else { throw POSIXError(.EIO) }
    var address = sockaddr_in()
    address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
    address.sin_family = sa_family_t(AF_INET)
    address.sin_addr.s_addr = inet_addr("127.0.0.1")
    let bound = withUnsafePointer(to: &address) {
      $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { Darwin.bind(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) }
    }
    guard bound == 0, Darwin.listen(fd, 8) == 0 else {
      let code = POSIXErrorCode(rawValue: errno) ?? .EIO
      Darwin.close(fd)
      throw POSIXError(code)
    }
    var length = socklen_t(MemoryLayout<sockaddr_in>.size)
    _ = withUnsafeMutablePointer(to: &address) {
      $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { getsockname(fd, $0, &length) }
    }
    socketFD = fd
    url = URL(string: "http://127.0.0.1:\(UInt16(bigEndian: address.sin_port))/bangs.json")!
    DispatchQueue(label: "solara.bangs.mock.\(UUID().uuidString)").async { [self] in serve(replies) }
  }

  var requests: [String] { state.withLock { $0.requests } }

  func stop() {
    let close = state.withLock { value in
      if value.stopped { return false }
      value.stopped = true
      return true
    }
    if close {
      Darwin.shutdown(socketFD, SHUT_RDWR)
      Darwin.close(socketFD)
    }
  }

  private func serve(_ replies: [Reply]) {
    defer { stop() }
    for reply in replies {
      var descriptor = pollfd(fd: socketFD, events: Int16(POLLIN), revents: 0)
      guard poll(&descriptor, 1, 5000) > 0, !state.withLock({ $0.stopped }) else { return }
      let client = Darwin.accept(socketFD, nil, nil)
      guard client >= 0 else { return }
      defer { Darwin.close(client) }
      var timeout = timeval(tv_sec: 2, tv_usec: 0)
      setsockopt(client, SOL_SOCKET, SO_RCVTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))
      var noSignal: Int32 = 1
      setsockopt(client, SOL_SOCKET, SO_NOSIGPIPE, &noSignal, socklen_t(MemoryLayout<Int32>.size))
      var request = Data()
      var buffer = [UInt8](repeating: 0, count: 4096)
      while request.count < 32_768 {
        let count = Darwin.recv(client, &buffer, buffer.count, 0)
        if count <= 0 { break }
        request.append(contentsOf: buffer[..<count])
        if request.range(of: Data("\r\n\r\n".utf8)) != nil { break }
      }
      state.withLock { $0.requests.append(String(decoding: request, as: UTF8.self)) }
      let headers = reply.headers.map { "\($0.key): \($0.value)\r\n" }.joined()
      let data = Data("HTTP/1.1 \(reply.status) Mock\r\n\(headers)Content-Length: \(reply.body.utf8.count)\r\nConnection: close\r\n\r\n\(reply.body)".utf8)
      data.withUnsafeBytes { bytes in
        var sent = 0
        while sent < bytes.count {
          let count = Darwin.send(client, bytes.baseAddress!.advanced(by: sent), bytes.count - sent, 0)
          if count <= 0 { break }
          sent += count
        }
      }
    }
  }
}

private func bangFixture(_ name: String) throws -> String {
  try String(contentsOf: URL(fileURLWithPath: #filePath).deletingLastPathComponent().appendingPathComponent("Fixtures/\(name)"), encoding: .utf8)
}

@MainActor
@Suite struct BangStoreTests {
  private func directory() throws -> URL {
    let url = FileManager.default.temporaryDirectory.appendingPathComponent("solara-bang-store-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url
  }

  private func write(_ text: String, _ name: String, to directory: URL) throws {
    try text.write(to: directory.appendingPathComponent(name), atomically: true, encoding: .utf8)
  }

  @Test func aLoopback200PersistsAndPublishesThen304KeepsTheSameTable() async throws {
    let directory = try directory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let body = try bangFixture("bangs-http.json")
    let server = try BangHTTPServer([
      .init(status: 200, headers: ["ETag": "\"http-v1\"", "Content-Type": "application/json"], body: body),
      .init(status: 304, headers: ["ETag": "\"http-v1\""]),
    ])
    defer { server.stop() }
    var clock = 1_000_000.0
    let store = BangStore(directory: directory, endpoint: server.url, now: { clock })
    #expect(store.table.get("gh")?.name == "GitHub")
    let first = await store.refresh()
    #expect(first.result == .updated)
    #expect(first.status == .http(200))
    #expect(store.source == .fetched)
    #expect(store.table.get("fixture7")?.name == "Fixture 7")
    #expect(store.etag == "\"http-v1\"")
    let saved = try String(contentsOf: directory.appendingPathComponent("bangs.txt"), encoding: .utf8)
    #expect(saved.hasPrefix("solara-bangs 1\t\"http-v1\"\n"))
    #expect(readBangDocument(saved)?.table.get("gh")?.name == "Stored gh")
    #expect(store.revision == 2)
    try #require(!server.requests.isEmpty)
    #expect(server.requests[0].lowercased().contains("accept: application/json"))
    #expect(server.requests[0].contains(BundledBangs.etag))
    clock += 86_400_000
    let second = await store.refresh()
    #expect(second.result == .unchanged)
    #expect(second.status == .http(304))
    #expect(store.source == .fetched)
    #expect(store.revision == 2)
    try #require(server.requests.count == 2)
    #expect(server.requests[1].lowercased().contains("if-none-match: \"http-v1\""))
    #expect(store.refreshes.count == 2)
    #expect(store.checkedAt == clock)
    let reopened = BangStore(directory: directory, endpoint: server.url, now: { clock })
    #expect(reopened.load().get("fixture7")?.name == "Fixture 7")
    #expect(reopened.source == .stored)
    #expect(await reopened.refresh().result == .fresh)
  }

  @Test func injected200And304ExchangeTheStoredETag() async throws {
    let directory = try directory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let body = try bangFixture("bangs-http.json")
    let seen = Mutex([String?]())
    var clock = 1000.0
    let store = BangStore(directory: directory, now: { clock }, fetch: { etag in
      let count = seen.withLock { values -> Int in values.append(etag); return values.count }
      if count == 1 { return BangFetchReply(status: 200, body: body, etag: "\"v1\"", contentType: "application/json") }
      return BangFetchReply(status: 304)
    })
    #expect(await store.refresh().result == .updated)
    #expect(store.table.get("fixture7")?.name == "Fixture 7")
    clock += 86_400_000
    #expect(await store.refresh().result == .unchanged)
    #expect(seen.withLock { $0 } == [BundledBangs.etag, "\"v1\""])
    #expect(store.source == .fetched)
    #expect(store.etag == "\"v1\"")
  }

  @Test func injectedOfflineFailureUsesStoredThenBundled() async throws {
    let directory = try directory()
    defer { try? FileManager.default.removeItem(at: directory) }
    try write(bangFixture("bangs-js-document.txt"), "bangs.txt", to: directory)
    let stored = BangStore(directory: directory, now: { 1000 }, fetch: { _ in throw URLError(.notConnectedToInternet) })
    #expect(await stored.refresh().result == .failed)
    #expect(stored.source == .stored)
    #expect(stored.table.get("fixture7")?.name == "Fixture 7")
    try FileManager.default.removeItem(at: directory.appendingPathComponent("bangs.txt"))
    try FileManager.default.removeItem(at: directory.appendingPathComponent("bangs-state.json"))
    let bundled = BangStore(directory: directory, now: { 2000 }, fetch: { _ in throw URLError(.notConnectedToInternet) })
    #expect(await bundled.refresh().result == .failed)
    #expect(bundled.source == .bundled)
    #expect(bundled.table.get("gh")?.name == "GitHub")
  }

  @Test func refusedConnectionsKeepStoredDataAndThenUseBundledDataWhenMissing() async throws {
    let directory = try directory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let server = try BangHTTPServer([])
    server.stop()
    try write(bangFixture("bangs-js-document.txt"), "bangs.txt", to: directory)
    let stored = BangStore(directory: directory, endpoint: server.url, now: { 10 })
    #expect(await stored.refresh().result == .failed)
    #expect(stored.source == .stored)
    #expect(stored.table.get("fixture7")?.name == "Fixture 7")
    #expect(stored.etag == "\"js-fixture-v1\"")
    try FileManager.default.removeItem(at: directory.appendingPathComponent("bangs.txt"))
    try FileManager.default.removeItem(at: directory.appendingPathComponent("bangs-state.json"))
    let bundled = BangStore(directory: directory, endpoint: server.url, now: { 20 })
    #expect(await bundled.refresh().result == .failed)
    #expect(bundled.source == .bundled)
    #expect(bundled.table.get("gh")?.name == "GitHub")
    #expect(bundled.table.get("fixture7") == nil)
  }

  @Test func corruptStoredDocumentsFallBackAndTheJSFixtureRoundTrips() throws {
    let directory = try directory()
    defer { try? FileManager.default.removeItem(at: directory) }
    for text in ["garbage", "solara-bangs 1\tbad\ngh\tBad\tbad.example/{s}", "solara-bangs 2\tbad\ninvalid"] {
      try write(text, "bangs.txt", to: directory)
      let store = BangStore(directory: directory, fetch: { _ in throw URLError(.notConnectedToInternet) })
      #expect(store.load().get("gh")?.name == "GitHub")
      #expect(store.source == .bundled)
      #expect(store.etag == nil)
    }
    let fixture = try bangFixture("bangs-js-document.txt")
    let firstLine = try #require(fixture.firstIndex(of: "\n"))
    let slim = String(fixture[fixture.index(after: firstLine)...])
    #expect(bangDocument(etag: "\"js-fixture-v1\"", slim: slim) == fixture)
    try write(fixture, "bangs.txt", to: directory)
    let store = BangStore(directory: directory, fetch: { _ in throw URLError(.notConnectedToInternet) })
    #expect(store.load().get("fixture7")?.template == "https://fixture7.example/?q={searchTerms}")
    #expect(store.source == .stored)
  }

  @Test func dailyBoundaryFailureThrottleAndClockRollbackUseTheInjectedClock() async throws {
    let directory = try directory()
    defer { try? FileManager.default.removeItem(at: directory) }
    var clock = 1_000_000.0
    let calls = Mutex(0)
    let store = BangStore(directory: directory, now: { clock }, fetch: { _ in
      calls.withLock { $0 += 1 }
      throw URLError(.notConnectedToInternet)
    })
    #expect(await store.refresh().result == .failed)
    clock += 86_399_999
    #expect(await store.refresh().result == .fresh)
    #expect(calls.withLock { $0 } == 1)
    clock += 1
    #expect(await store.refresh().result == .failed)
    #expect(calls.withLock { $0 } == 2)
    clock = 1
    #expect(await store.refresh().result == .failed)
    #expect(calls.withLock { $0 } == 3)
    let state = try Data(contentsOf: directory.appendingPathComponent("bangs-state.json"))
    let json = try #require(JSONSerialization.jsonObject(with: state) as? [String: Double])
    #expect(json["checkedAt"] == 1)
  }

  @Test func aFreshPersistedStateSkipsLoadingAndInvalidStateDoesNotBlockRefresh() async throws {
    let directory = try directory()
    defer { try? FileManager.default.removeItem(at: directory) }
    try write("{\"checkedAt\":1000}", "bangs-state.json", to: directory)
    let calls = Mutex(0)
    let fetch: BangStore.Fetch = { _ in
      calls.withLock { $0 += 1 }
      return BangFetchReply(status: 304)
    }
    let fresh = BangStore(directory: directory, now: { 1001 }, fetch: fetch)
    #expect(await fresh.refresh().result == .fresh)
    #expect(fresh.source == nil)
    #expect(calls.withLock { $0 } == 0)
    for state in ["invalid", "{\"checkedAt\":true}", "{\"checkedAt\":\"1000\"}"] {
      try write(state, "bangs-state.json", to: directory)
      let store = BangStore(directory: directory, now: { 1001 }, fetch: fetch)
      #expect(await store.refresh().result == .unchanged)
    }
    #expect(calls.withLock { $0 } == 3)
  }

  @Test func concurrentAndOnceRefreshesShareOneAttemptEvenWithoutStateWrites() async throws {
    let directory = try directory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let calls = Mutex(0)
    let store = BangStore(directory: directory, now: { 1000 }, fetch: { _ in
      calls.withLock { $0 += 1 }
      try await Task.sleep(for: .milliseconds(20))
      return BangFetchReply(status: 304)
    }, writeDocument: { _, _ in throw CocoaError(.fileWriteNoPermission) })
    async let first = store.refresh()
    async let second = store.refresh()
    let results = await [first, second]
    #expect(results.map(\.result) == [.unchanged, .unchanged])
    #expect(calls.withLock { $0 } == 1)
    #expect(await store.refresh().result == .fresh)
    _ = await store.refreshOnce()
    _ = await store.refreshOnce()
    #expect(calls.withLock { $0 } == 1)
  }

  @Test func badHTTPOrInvalidListsAndSaveFailuresNeverReplaceAValidTable() async throws {
    let directory = try directory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let fixture = try bangFixture("bangs-js-document.txt")
    let body = try bangFixture("bangs-http.json")
    let replies = [
      BangFetchReply(status: 500),
      BangFetchReply(status: 200, body: body, contentType: "text/html"),
      BangFetchReply(status: 200, body: "[]", contentType: "application/json"),
      BangFetchReply(status: 200, body: body, etag: "new", contentType: "application/json"),
    ]
    for reply in replies {
      try write(fixture, "bangs.txt", to: directory)
      try? FileManager.default.removeItem(at: directory.appendingPathComponent("bangs-state.json"))
      let store = BangStore(directory: directory, now: { 1000 }, fetch: { _ in reply },
        saveDocument: { _, _ in throw CocoaError(.fileWriteNoPermission) })
      #expect(await store.refresh().result == .failed)
      #expect(store.source == .stored)
      #expect(store.etag == "\"js-fixture-v1\"")
      #expect(store.table.get("fixture7")?.name == "Fixture 7")
      #expect(try String(contentsOf: directory.appendingPathComponent("bangs.txt"), encoding: .utf8) == fixture)
      #expect(await store.refresh().result == .fresh)
    }
  }

  @Test func redirectsAndOversizeResponsesFailWithoutReplacingBundledData() async throws {
    let directory = try directory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let server = try BangHTTPServer([
      .init(status: 302, headers: ["Location": "http://127.0.0.1:1/forbidden"]),
      .init(status: 200, headers: ["Content-Type": "application/json"], body: String(repeating: " ", count: 5_000_001)),
    ])
    defer { server.stop() }
    var clock = 1000.0
    let store = BangStore(directory: directory, endpoint: server.url, now: { clock })
    let redirected = await store.refresh()
    #expect(redirected.status == .http(302))
    #expect(redirected.result == .failed)
    clock += 86_400_000
    #expect(await store.refresh().result == .failed)
    #expect(store.source == .bundled)
    #expect(store.table.get("gh")?.name == "GitHub")
    #expect(server.requests.count == 2)
  }
}
