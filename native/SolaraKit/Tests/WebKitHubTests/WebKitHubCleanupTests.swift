import AppKit
import Testing
import Synchronization
import WebKit

@MainActor
private final class DownloadSource: WebKitDownloadSource {
  let originalRequest: URLRequest?
  let progress = Progress(totalUnitCount: 10)
  weak var delegate: (any WKDownloadDelegate)?
  var cancellations: [(@MainActor (Data?) -> Void)?] = []

  init(_ url: String) { originalRequest = URLRequest(url: URL(string: url)!) }
  func cancel(_ completionHandler: (@MainActor (Data?) -> Void)?) { cancellations.append(completionHandler) }
}

@MainActor
private final class DestinationOwner {}

private final class MainQueueDrain: Sendable {
  private struct State {
    var result: Bool?
    var continuation: CheckedContinuation<Bool, Never>?
  }
  private let state = Mutex(State())

  func wait() async -> Bool {
    await withTaskCancellationHandler {
      await withCheckedContinuation { continuation in
        let result = state.withLock { state -> Bool? in
          if let result = state.result { return result }
          state.continuation = continuation
          return nil
        }
        if let result { continuation.resume(returning: result) }
        else { DispatchQueue.global().asyncAfter(deadline: .now() + 5) { self.finish(false) } }
      }
    } onCancel: { self.finish(false) }
  }

  func finish(_ result: Bool) {
    let continuation = state.withLock { state -> CheckedContinuation<Bool, Never>? in
      guard state.result == nil else { return nil }
      state.result = result
      let continuation = state.continuation
      state.continuation = nil
      return continuation
    }
    continuation?.resume(returning: result)
  }
}

@Suite @MainActor struct WebKitHubCleanupTests {
  private let profile = "incognito:window@shared"

  private func view(_ hub: WebKitHub, profile: String) -> WKWebView {
    let configuration = WKWebViewConfiguration()
    configuration.websiteDataStore = WebKitHub.isPrivate(profile) ? hub.dataStore(for: profile) : .nonPersistent()
    return WKWebView(frame: .zero, configuration: configuration)
  }

  private func drainMainQueue() async {
    let drain = MainQueueDrain()
    DispatchQueue.main.async { drain.finish(true) }
    #expect(await drain.wait())
  }

  @Test func endingHubSessionCompletesPendingDestinationOnceAndDropsDelayedSettings() throws {
    let hub = WebKitHub()
    let webView = view(hub, profile: profile)
    let source = DownloadSource("https://private.test/pending")
    var settings: ((URL, Bool) -> Void)?
    hub.downloads.destinationSettings = { _, completion in settings = completion }
    let id = try #require(hub.downloads.adopt(source, profile: profile, webView: webView))
    var destinations: [URL?] = []
    var events: [[String: Any]] = []
    hub.events = { name, payload in if name == "onWebKitDownload" { events.append(payload) } }
    hub.downloads.decideDestination(source, response: URLResponse(url: source.originalRequest!.url!, mimeType: "text/plain", expectedContentLength: 3, textEncodingName: nil), suggestedFilename: "private.txt") { destinations.append($0) }
    let delayedSettings = try #require(settings)
    hub.endPrivateSession("shared")
    #expect(destinations.count == 1)
    #expect(destinations[0] == nil)
    #expect(source.cancellations.count == 1)
    delayedSettings(FileManager.default.temporaryDirectory, false)
    hub.downloads.command("resume", id: id)
    #expect(destinations.count == 1)
    #expect(events.isEmpty)
  }

  @Test func cancellingOrdinaryProfileCompletesPendingDestinationOnceAndDropsDelayedSettings() throws {
    let hub = WebKitHub()
    let webView = view(hub, profile: "ordinary")
    let source = DownloadSource("https://ordinary.test/pending")
    var settings: ((URL, Bool) -> Void)?
    hub.downloads.destinationSettings = { _, completion in settings = completion }
    let id = try #require(hub.downloads.adopt(source, profile: "ordinary", webView: webView))
    var destinations: [URL?] = []
    var owner: DestinationOwner? = DestinationOwner()
    weak var retainedOwner = owner
    var events: [[String: Any]] = []
    hub.events = { name, payload in if name == "onWebKitDownload" { events.append(payload) } }
    hub.downloads.decideDestination(source, response: URLResponse(url: source.originalRequest!.url!, mimeType: "text/plain", expectedContentLength: 3, textEncodingName: nil), suggestedFilename: "ordinary.txt") { [owner] url in
      withExtendedLifetime(owner) { destinations.append(url) }
    }
    owner = nil
    #expect(retainedOwner != nil)
    let delayedSettings = try #require(settings)
    hub.downloads.cancelAll(profile: "ordinary")
    #expect(destinations.count == 1)
    #expect(destinations.compactMap { $0 }.isEmpty)
    #expect(retainedOwner == nil)
    #expect(source.cancellations.count == 1)
    hub.downloads.command("cancel", id: id)
    delayedSettings(FileManager.default.temporaryDirectory, false)
    delayedSettings(FileManager.default.temporaryDirectory, true)
    #expect(destinations.count == 1)
    #expect(events.count == 1)
    #expect(events.first?["state"] as? String == "cancelled")
  }

  @Test func endingHubSessionDropsPauseCompletionAndRejectsResumingOldDownload() async throws {
    let hub = WebKitHub()
    let webView = view(hub, profile: profile)
    let source = DownloadSource("https://private.test/pause")
    let id = try #require(hub.downloads.adopt(source, profile: profile, webView: webView))
    var restartCount = 0
    hub.downloads.restartDownload = { _, _, _, _, _ in restartCount += 1 }
    hub.downloads.command("pause", id: id)
    let paused = try #require(source.cancellations.first.flatMap { $0 })
    hub.endPrivateSession("shared")
    _ = hub.dataStore(for: profile)
    paused(Data([1, 2, 3]))
    await drainMainQueue()
    hub.downloads.command("resume", id: id)
    #expect(restartCount == 0)
    #expect(source.cancellations.count == 2)
  }

  @Test func endingHubSessionCancelsDownloadReturnedByLateResumeCompletion() async throws {
    let hub = WebKitHub()
    let webView = view(hub, profile: profile)
    let source = DownloadSource("https://private.test/resume")
    let id = try #require(hub.downloads.adopt(source, profile: profile, webView: webView))
    hub.downloads.command("pause", id: id)
    let paused = try #require(source.cancellations.first.flatMap { $0 })
    paused(Data([7]))
    await drainMainQueue()
    var resumed: ((any WebKitDownloadSource) -> Void)?
    hub.downloads.restartDownload = { _, _, _, _, completion in resumed = completion }
    hub.downloads.command("resume", id: id)
    let delayedResume = try #require(resumed)
    hub.endPrivateSession("shared")
    _ = hub.dataStore(for: profile)
    let replacement = DownloadSource("https://private.test/resumed")
    var events = 0
    hub.events = { name, _ in if name == "onWebKitDownload" { events += 1 } }
    delayedResume(replacement)
    await drainMainQueue()
    #expect(replacement.cancellations.count == 1)
    #expect(replacement.delegate == nil)
    #expect(events == 0)
  }

  @Test func endedHubSessionForgetsFinishedAndCanceledDownloadsButKeepsSavedFile() throws {
    let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: folder) }
    let hub = WebKitHub()
    let webView = view(hub, profile: profile)
    hub.downloads.destinationSettings = { _, completion in completion(folder, false) }
    let finished = DownloadSource("https://private.test/finished")
    let finishedId = try #require(hub.downloads.adopt(finished, profile: profile, webView: webView))
    var destination: URL?
    hub.downloads.decideDestination(finished, response: URLResponse(url: finished.originalRequest!.url!, mimeType: nil, expectedContentLength: 3, textEncodingName: nil), suggestedFilename: "saved") { destination = $0 }
    let staging = try #require(destination)
    try Data([1, 2, 3]).write(to: staging)
    hub.downloads.finish(finished)
    let canceled = DownloadSource("https://private.test/canceled")
    let canceledId = try #require(hub.downloads.adopt(canceled, profile: profile, webView: webView))
    hub.downloads.command("cancel", id: canceledId)
    #expect(hub.downloads.retainedDownloadCount == 2)
    hub.endPrivateSession("shared")
    #expect(hub.downloads.retainedDownloadCount == 0)
    #expect(try Data(contentsOf: folder.appendingPathComponent("saved")) == Data([1, 2, 3]))
    hub.downloads.command("pause", id: finishedId)
    hub.downloads.command("resume", id: canceledId)
  }

  @Test func lateExternalApprovalCannotOpenEndedSessionButOrdinaryApprovalStillOpens() throws {
    var opened: [URL] = []
    let hub = WebKitHub(externalApplication: { _ in URL(fileURLWithPath: "/Applications/Fixture.app") }, openExternal: { opened.append($0) })
    let privateView = view(hub, profile: profile)
    let ordinaryView = view(hub, profile: "shared")
    let ended = try #require(hub.externalAppRequest(url: URL(string: "fixture://private")!, origin: "https://private.test", profile: profile, webView: privateView)?["id"] as? String)
    let ordinary = try #require(hub.externalAppRequest(url: URL(string: "fixture://ordinary")!, origin: "https://ordinary.test", profile: "shared", webView: ordinaryView)?["id"] as? String)
    hub.endPrivateSession("shared")
    let nextView = view(hub, profile: profile)
    let replacement = try #require(hub.externalAppRequest(url: URL(string: "fixture://replacement")!, origin: "https://private.test", profile: profile, webView: nextView)?["id"] as? String)
    hub.resolveExternalApp(ended, open: true, remember: true)
    #expect(opened.isEmpty)
    hub.resolveExternalApp(ordinary, open: true, remember: false)
    hub.resolveExternalApp(replacement, open: true, remember: true)
    #expect(opened.map(\.absoluteString) == ["fixture://ordinary", "fixture://replacement"])
    #expect(hub.externalAppAllowances(profile: profile).isEmpty)
  }

  @Test func downloadPayloadKeepsApi34FieldsAndRetiredSourceCannotEmit() throws {
    NativePrivateSessionCleanup.beginWebKitSession("shared", generation: "api34-contract")
    defer { NativePrivateSessionCleanup.endWebKitSession("shared") }
    let hub = WebKitHub()
    let webView = view(hub, profile: profile)
    let source = DownloadSource("https://private.test/contract")
    let id = try #require(hub.downloads.adopt(source, profile: profile, webView: webView))
    var payloads: [[String: Any]] = []
    hub.events = { name, payload in if name == "onWebKitDownload" { payloads.append(payload) } }
    hub.downloads.command("pause", id: id)
    let payload = try #require(payloads.first)
    #expect(Set(payload.keys) == Set(["id", "url", "filename", "path", "state", "paused", "received", "total", "speed", "mimeType", "profile", "offTheRecord", "staging", "destination"]))
    let expected: [String: Any] = [
      "id": id, "url": "https://private.test/contract", "filename": "", "path": "", "state": "downloading",
      "paused": true, "received": Double(0), "total": Double(0), "speed": Double(0), "mimeType": "",
      "profile": profile, "offTheRecord": false, "staging": NSNull(), "destination": NSNull(),
    ]
    #expect(NSDictionary(dictionary: payload).isEqual(to: expected))
    hub.endPrivateSession("shared")
    hub.downloads.fail(source, error: URLError(.cancelled), resumeData: Data([8]))
    #expect(payloads.count == 1)
  }
}
