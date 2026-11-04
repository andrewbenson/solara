import AppKit
import Foundation

public final class RNPageAttachment {
  public let value: AnyObject
  public var allowsStart: Bool

  public init(_ value: AnyObject, allowsStart: Bool = true) {
    self.value = value
    self.allowsStart = allowsStart
  }
}

public enum RNPageReportDisposition {
  case fallback
  case reserved(sessionGeneration: String, registrationGeneration: UInt64, eventSeq: Int? = nil)
  case rejected(sessionGeneration: String?, registrationGeneration: UInt64?)

  public var envelope: [String: Any] {
    switch self {
    case .fallback: return ["kind": "fallback"]
    case .reserved(let session, let registration, let eventSeq):
      var value: [String: Any] = ["kind": "reserved", "sessionGeneration": session, "registrationGeneration": registration]
      if let eventSeq { value["eventSeq"] = eventSeq }
      return value
    case .rejected(let session, let registration):
      var value: [String: Any] = ["kind": "rejected"]
      if let session { value["sessionGeneration"] = session }
      if let registration { value["registrationGeneration"] = registration }
      return value
    }
  }
}

public struct RNPageHostHooks {
  public let attach: @MainActor (NSView, NSView, String?, String, String, [String: Any], RNPageAttachment?, @escaping @MainActor @Sendable (String, [String: Any]) -> Void) -> RNPageAttachment?
  public let start: @MainActor (RNPageAttachment, @escaping @MainActor @Sendable () -> Void) -> Void
  public let detach: @MainActor (RNPageAttachment) -> Void
  public let reserve: @MainActor (RNPageAttachment, String, [String: Any]) -> RNPageReportDisposition
  public let call: @MainActor (RNPageAttachment?, NSView, String?, Bool, String, [Any], @escaping @MainActor @Sendable (Any?) -> Void, @escaping @MainActor @Sendable (String, String) -> Void) -> Void
  public let deliver: @MainActor (@escaping @MainActor @Sendable () -> Void) -> Void

  public init(
    attach: @escaping @MainActor (NSView, NSView, String?, String, String, [String: Any], RNPageAttachment?, @escaping @MainActor @Sendable (String, [String: Any]) -> Void) -> RNPageAttachment?,
    start: @escaping @MainActor (RNPageAttachment, @escaping @MainActor @Sendable () -> Void) -> Void,
    detach: @escaping @MainActor (RNPageAttachment) -> Void,
    reserve: @escaping @MainActor (RNPageAttachment, String, [String: Any]) -> RNPageReportDisposition,
    call: @escaping @MainActor (RNPageAttachment?, NSView, String?, Bool, String, [Any], @escaping @MainActor @Sendable (Any?) -> Void, @escaping @MainActor @Sendable (String, String) -> Void) -> Void,
    deliver: @escaping @MainActor (@escaping @MainActor @Sendable () -> Void) -> Void
  ) {
    self.attach = attach
    self.start = start
    self.detach = detach
    self.reserve = reserve
    self.call = call
    self.deliver = deliver
  }
}

public enum RNPageEventTap {
  private static let lock = NSLock()
  nonisolated(unsafe) private static var hooks: RNPageHostHooks?

  public static func install(_ value: RNPageHostHooks) {
    lock.lock()
    hooks = value
    lock.unlock()
  }

  private static func current() -> RNPageHostHooks? {
    lock.lock()
    defer { lock.unlock() }
    return hooks
  }

  @MainActor
  public static func attach(owner: NSView, page: NSView, tabId: String?, engine: String, profile: String,
    context: [String: Any] = [:], previous: RNPageAttachment?, emit: @escaping @MainActor (String, [String: Any]) -> Void) -> RNPageAttachment? {
    current()?.attach(owner, page, tabId, engine, profile, context, previous, emit)
  }

  @MainActor
  public static func start(attachment: RNPageAttachment?, action: @escaping @MainActor () -> Void) {
    if let attachment, let hooks = current() { hooks.start(attachment, action) }
    else { action() }
  }

  @MainActor
  public static func detach(_ attachment: RNPageAttachment?) {
    guard let attachment else { return }
    current()?.detach(attachment)
  }

  @MainActor
  public static func reserve(attachment: RNPageAttachment?, name: String, payload: [String: Any]) -> RNPageReportDisposition {
    guard let hooks = current(), let attachment else { return .fallback }
    return hooks.reserve(attachment, name, payload)
  }

  @MainActor
  public static func forward(attachment: RNPageAttachment?, name: String, payload: [String: Any], emit: @escaping @MainActor ([String: Any]) -> Void) {
    let disposition = reserve(attachment: attachment, name: name, payload: payload)
    guard name != "onPagePhysical", name != "onPageExecution", name != "onPageRequestAccepted", name != "onPageConstructorCaptured" else { return }
    var body = payload
    body["storeReport"] = disposition.envelope
    if let hooks = current() { hooks.deliver { emit(body) } }
    else { emit(body) }
  }

  @MainActor
  public static func call(attachment: RNPageAttachment?, page: NSView, transferKey: String?, propsReady: Bool,
    method: String, args: [Any], resolve: @escaping @MainActor @Sendable (Any?) -> Void,
    reject: @escaping @MainActor @Sendable (String, String) -> Void) {
    guard let hooks = current() else {
      reject("ERR_PAGE_UNATTACHED", "The native page host is unavailable")
      return
    }
    hooks.call(attachment, page, transferKey, propsReady, method, args, resolve, reject)
  }
}
