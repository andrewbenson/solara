import Foundation

@MainActor
public final class OnboardingPreviewQueue {
  private var pending: [@MainActor () async throws -> Void] = []
  private var tail: Task<Void, Error>?

  public init() {}

  public func enqueue(_ action: @escaping @MainActor () async throws -> Void) {
    pending.append(action)
    _ = schedule()
  }

  public func drain() async throws {
    try await schedule().value
  }

  private func schedule() -> Task<Void, Error> {
    let previous = tail
    let task = Task { @MainActor in
      _ = try? await previous?.value
      while let action = pending.first {
        try await action()
        pending.removeFirst()
      }
    }
    tail = task
    return task
  }
}
