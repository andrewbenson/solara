import Foundation

@MainActor
public enum LaunchAdmission {
  public private(set) static var chromeCommittedAt: Double?
  private static var admitted = false
  private static var observers: [UUID: (Bool) -> Void] = [:]
  public static var schedule: ((UUID, @escaping (Bool) -> Void) -> Void)? {
    didSet {
      guard let schedule else { return }
      let waiting = pending
      pending = [:]
      for (token, action) in waiting { schedule(token, action) }
    }
  }
  public static var cancelScheduled: ((UUID) -> Void)?
  private static var pending: [UUID: (Bool) -> Void] = [:]
  private static var namedJobs: [String: UUID] = [:]

  @discardableResult
  public static func observe(_ handler: @escaping (Bool) -> Void) -> UUID {
    let token = UUID()
    observers[token] = handler
    handler(admitted)
    return token
  }

  public static func cancel(_ token: UUID) { observers[token] = nil }

  public static func recordChromeCommit(_ epochMs: Double) {
    guard chromeCommittedAt == nil, epochMs.isFinite, epochMs > 0 else { return }
    chromeCommittedAt = epochMs
  }

  public static func setAdmitted(_ value: Bool) {
    guard value != admitted else { return }
    admitted = value
    for token in Array(observers.keys) {
      guard admitted == value else { break }
      observers[token]?(value)
    }
  }

  public static func whenIdle(_ token: UUID, _ action: @escaping (Bool) -> Void) {
    if let schedule { schedule(token, action) } else { pending[token] = action }
  }

  public static func cancelWork(_ token: UUID) {
    if let action = pending.removeValue(forKey: token) { action(false) }
    cancelScheduled?(token)
  }

  public static func whenIdle(_ id: String, _ action: @escaping (Bool) -> Void) {
    cancelWork(id)
    let token = UUID()
    namedJobs[id] = token
    whenIdle(token) { admitted in
      guard namedJobs[id] == token else { return }
      namedJobs[id] = nil
      action(admitted)
    }
  }

  public static func cancelWork(_ id: String) {
    guard let token = namedJobs[id] else { return }
    cancelWork(token)
  }
}
