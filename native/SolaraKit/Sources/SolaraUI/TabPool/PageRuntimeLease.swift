import Foundation

@MainActor
public final class PageRuntimeLease {
  public static let shared = PageRuntimeLease()
  private weak var holder: AnyObject?

  public init() {}

  public func begin(_ owner: AnyObject, _ id: UUID, start: (UUID) -> Void) {
    holder = owner
    start(id)
  }

  public func end(_ owner: AnyObject, _ id: UUID?, stop: (UUID) -> Void) {
    guard let id, holder === owner else { return }
    holder = nil
    stop(id)
  }
}
