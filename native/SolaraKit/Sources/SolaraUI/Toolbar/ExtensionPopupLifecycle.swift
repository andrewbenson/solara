import Foundation
import SolaraStore

public struct ExtensionPopupLifecycle {
  public struct Source: Equatable {
    public let windowId: String
    public let tabId: String?
    public let profile: String
    public let url: String?
    public let sequence: Double?
    public let browserId: Int
    public let generation: Int
    public let registration: PageRegistration?

    public init(windowId: String, tabId: String?, profile: String, url: String?, sequence: Double?, browserId: Int, generation: Int, registration: PageRegistration? = nil) {
      self.windowId = windowId
      self.tabId = tabId
      self.profile = profile
      self.url = url
      self.sequence = sequence
      self.browserId = browserId
      self.generation = generation
      self.registration = registration
    }
  }

  public struct Request: Equatable {
    public let token: UUID
    public let source: Source
    public let extensionId: String
    public let revision: Int
  }

  public private(set) var pending: Request?
  public private(set) var open: Request?

  public init() {}

  public func matches(windowId: String, extensionId: String) -> Bool {
    [pending, open].contains { $0?.source.windowId == windowId && $0?.extensionId == extensionId }
  }

  public mutating func begin(_ source: Source, extensionId: String, revision: Int = 0) -> Request {
    let request = Request(token: UUID(), source: source, extensionId: extensionId, revision: revision)
    pending = request
    return request
  }

  @discardableResult
  public mutating func finish(_ request: Request, source: Source?, eligible: Bool) -> Bool {
    guard pending == request else { return false }
    pending = nil
    guard request.source == source, eligible else { return false }
    open = request
    return true
  }

  public mutating func close(windowId: String? = nil, replacement: Bool = false) {
    if !replacement, windowId == nil || pending?.source.windowId == windowId { pending = nil }
    if windowId == nil || open?.source.windowId == windowId { open = nil }
  }

  public mutating func cancel(_ request: Request) {
    if pending == request { pending = nil }
    if open == request { open = nil }
  }

  public mutating func completeWithoutPopup(_ request: Request) -> Bool {
    guard pending == request else { return false }
    close(windowId: request.source.windowId)
    return true
  }

  public mutating func reconcileContext(_ commit: Commit) {
    for request in [pending, open].compactMap({ $0 }) where commit.rev > request.revision {
      let windowId = request.source.windowId
      let shownTab = commit.state.peeks[windowId]?.tabId ?? commit.state.activeTabId(windowId)
      if commit.state.windows[windowId]?.profileId != request.source.profile || shownTab != request.source.tabId {
        cancel(request)
      }
    }
  }

  public mutating func reconcile(sources: [String: Source], eligible: [String: Set<String>]) {
    for request in [pending, open].compactMap({ $0 }) {
      if sources[request.source.windowId] != request.source || eligible[request.source.windowId]?.contains(request.extensionId) != true {
        cancel(request)
      }
    }
  }

  public mutating func invalidate() { self = Self() }

  public static func admits(requiresActive: Bool, key: Bool, active: Bool) -> Bool {
    !requiresActive || (key && active)
  }

  public static func validURL(_ text: String, extensionId: String) -> Bool {
    guard let url = URLComponents(string: text) else { return false }
    return url.scheme == "chrome-extension" && url.host == extensionId
  }
}
