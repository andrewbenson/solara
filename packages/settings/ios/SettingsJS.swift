import Foundation

public struct SettingsJSError: Error, CustomStringConvertible {
  public let description: String
}

@MainActor
public final class SettingsJS {
  public static let shared = SettingsJS()

  var send: ((_ id: Int, _ name: String, _ argsJSON: String) -> Void)? {
    didSet { if send != nil { for listener in connectListeners { listener() } } }
  }
  private var connectListeners: [() -> Void] = []
  private var pending: [Int: CheckedContinuation<Any?, Error>] = [:]
  private var nextId = 0
  #if DEBUG
  private var importReplyNames: [Int: String] = [:]
  private var heldImportReply: (Int, String?, String?)?
  private var releasingImportReply = false
  var devImportReplyHeld: Bool { heldImportReply != nil }

  func devReleaseImportReply() {
    guard let (id, result, error) = heldImportReply else { return }
    heldImportReply = nil
    releasingImportReply = true
    reply(id, resultJSON: result, error: error)
    releasingImportReply = false
  }
  #endif
  private var topics: [String: [UUID: (Any?) -> Void]] = [:]
  private(set) var latest: [String: Any] = [:]

  var connected: Bool { send != nil }

  public func onConnect(_ listener: @escaping () -> Void) {
    connectListeners.append(listener)
  }

  public func call(_ name: String, _ args: Any...) async throws -> Any? {
    try await invoke(name, args)
  }

  public func fire(_ name: String, _ args: Any...) {
    Task { _ = try? await invoke(name, args) }
  }

  func invoke(_ name: String, _ args: [Any], timeout: TimeInterval? = nil) async throws -> Any? {
    guard let send else { throw SettingsJSError(description: "JS isn't listening for Settings calls") }
    let payload = try JSONSerialization.data(withJSONObject: args.map { $0 is NSNull ? NSNull() : $0 }, options: [.fragmentsAllowed])
    nextId += 1
    let id = nextId
    let deadline = timeout.map { timeout in
      let work = DispatchWorkItem { [weak self] in
        self?.reply(id, resultJSON: nil, error: "Settings call \(name) timed out")
      }
      DispatchQueue.main.asyncAfter(deadline: .now() + timeout, execute: work)
      return work
    }
    defer { deadline?.cancel() }
    return try await withCheckedThrowingContinuation { continuation in
      pending[id] = continuation
      #if DEBUG
      if !(ProcessInfo.processInfo.environment["SOLARA_DATA_DIR"] ?? "").isEmpty { importReplyNames[id] = name }
      #endif
      send(id, name, String(decoding: payload, as: UTF8.self))
    }
  }

  func reply(_ id: Int, resultJSON: String?, error: String?) {
    #if DEBUG
    let environment = ProcessInfo.processInfo.environment
    if !releasingImportReply, !(environment["SOLARA_DATA_DIR"] ?? "").isEmpty {
      let name = importReplyNames[id]
      if environment["SOLARA_IMPORT_TEST_ACK"] == "holdAdoption", name == "replica.adoptFavicons" {
        heldImportReply = (id, resultJSON, error)
        return
      }
      if environment["SOLARA_IMPORT_TEST_ACK"] == "rejectTheme", name == "import.adoptProfileTheme" {
        importReplyNames[id] = nil
        pending.removeValue(forKey: id)?.resume(returning: false)
        return
      }
    }
    importReplyNames[id] = nil
    #endif
    guard let continuation = pending.removeValue(forKey: id) else { return }
    if let error { return continuation.resume(throwing: SettingsJSError(description: error)) }
    guard let resultJSON, let data = resultJSON.data(using: .utf8) else { return continuation.resume(returning: nil) }
    let value = try? JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed])
    continuation.resume(returning: value is NSNull ? nil : value)
  }

  func failAll(_ reason: String) {
    let waiting = pending
    pending = [:]
    #if DEBUG
    importReplyNames = [:]
    heldImportReply = nil
    #endif
    for continuation in waiting.values { continuation.resume(throwing: SettingsJSError(description: reason)) }
  }

  func publish(_ topic: String, json: String) {
    let value = json.data(using: .utf8).flatMap { try? JSONSerialization.jsonObject(with: $0, options: [.fragmentsAllowed]) }
    latest[topic] = value
    for listener in topics[topic, default: [:]].values { listener(value) }
  }

  public func latestValue(_ topic: String) -> Any? { latest[topic] }

  public func observe(_ topic: String, _ listener: @escaping (Any?) -> Void) -> UUID {
    let id = UUID()
    topics[topic, default: [:]][id] = listener
    return id
  }

  public func stopObserving(_ topic: String, _ id: UUID) {
    topics[topic]?[id] = nil
  }

  public func stream<T: Sendable>(_ topic: String, _ transform: @escaping (Any?) -> T?) -> AsyncStream<T> {
    AsyncStream { continuation in
      let id = observe(topic) { value in
        if let mapped = transform(value) { continuation.yield(mapped) }
      }
      continuation.onTermination = { _ in
        Task { @MainActor in SettingsJS.shared.stopObserving(topic, id) }
      }
    }
  }
}
