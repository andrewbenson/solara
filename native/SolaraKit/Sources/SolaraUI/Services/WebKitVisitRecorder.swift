import Foundation

public struct WebKitVisitRecorder {
  public struct Visit: Equatable, Sendable {
    public let profile: String
    public let url: String
    public let time: Double
    public fileprivate(set) var title: String
  }

  private struct Pending {
    let id = UUID()
    var visit: Visit
    let previousTitle: String
    var settling = false
  }

  private var pending: [String: Pending] = [:]
  private var recorded: [String: String] = [:]

  public init() {}

  public mutating func note(tabId: String, profile: String?, url: String, committedURL: String?, title: String,
    loading: Bool, now: Double) -> (writes: [Visit], timer: UUID?) {
    guard EngineCommand.site(url) != nil, committedURL == url else { return ([], nil) }
    var writes: [Visit] = []
    if let old = pending[tabId], old.visit.url != url, let visit = finish(tabId: tabId) { writes.append(visit) }
    guard let profile else { return (writes, nil) }
    if pending[tabId] == nil {
      guard recorded[tabId] != url else { return (writes, nil) }
      recorded[tabId] = nil
      pending[tabId] = Pending(visit: Visit(profile: profile, url: url, time: now, title: title), previousTitle: title)
    }
    guard var entry = pending[tabId] else { return (writes, nil) }
    if !title.isEmpty { entry.visit.title = title }
    if !title.isEmpty, title != entry.previousTitle {
      pending[tabId] = entry
      if let visit = finish(tabId: tabId) { writes.append(visit) }
      return (writes, nil)
    }
    let timer = !loading && !entry.settling ? entry.id : nil
    if timer != nil { entry.settling = true }
    pending[tabId] = entry
    return (writes, timer)
  }

  public mutating func settle(tabId: String, timer: UUID) -> Visit? {
    guard pending[tabId]?.id == timer else { return nil }
    return finish(tabId: tabId)
  }

  public mutating func closeMissing(known: Set<String>) -> [Visit] {
    Set(pending.keys).union(recorded.keys).subtracting(known).compactMap { id in
      let visit = finish(tabId: id)
      recorded[id] = nil
      return visit
    }
  }

  private mutating func finish(tabId: String) -> Visit? {
    guard let entry = pending.removeValue(forKey: tabId) else { return nil }
    recorded[tabId] = entry.visit.url
    return entry.visit
  }
}
