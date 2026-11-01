import SolaraModel

public struct PageExecutionMemory: Sendable {
  private struct Request: Sendable {
    let seq: Int?
    let url: String
  }

  private var initial: Request?
  private var staged: Request?
  private var requested: Request?
  private var capturedConstructor: Request?

  public init(initial: TabNavigationRequest?) {
    self.initial = initial.map { Request(seq: Self.safeSequence($0.seq), url: $0.url) }
  }

  public mutating func stage(navigation: TabNavigationRequest?, url: String, userInitiated: Bool) {
    let seq = navigation.flatMap { request in
      request.url == url && request.userInitiated == userInitiated ? Self.safeSequence(request.seq) : nil
    }
    staged = Request(seq: seq, url: url)
  }

  public mutating func finishStaging() { staged = nil }

  public mutating func accepted(url: String) {
    initial = nil
    requested = Request(seq: staged.flatMap { $0.url == url ? $0.seq : nil }, url: url)
    staged = nil
  }

  public mutating func constructorCaptured(url: String) {
    let candidate = requested ?? initial
    capturedConstructor = Request(seq: candidate.flatMap { $0.url == url ? $0.seq : nil }, url: url)
  }

  public mutating func executed(url: String, constructor: Bool) -> Int? {
    let candidate = constructor ? capturedConstructor : requested
    return candidate.flatMap { $0.url == url ? $0.seq : nil }
  }

  private static func safeSequence(_ sequence: Int) -> Int? {
    sequence >= 0 && sequence <= 9_007_199_254_740_991 ? sequence : nil
  }
}
