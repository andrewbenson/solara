import Foundation

public struct StoreUnavailable: Equatable, Sendable {
  public enum Cause: Equatable, Sendable {
    case refused
    case openFailed
  }

  public let cause: Cause
  public let detail: String
  public let dataFolder: URL?
  public let offersSafeMode: Bool
  public let errorType: String
  public let launchWasSafeMode: Bool

  public init(
    cause: Cause, detail: String, dataFolder: URL?, offersSafeMode: Bool = false, errorType: String = "", launchWasSafeMode: Bool = false
  ) {
    self.cause = cause
    self.detail = detail
    self.dataFolder = dataFolder
    self.offersSafeMode = offersSafeMode
    self.errorType = errorType
    self.launchWasSafeMode = launchWasSafeMode
  }

  public var firstDetailLine: String {
    detail.split(whereSeparator: \.isNewline).first.map(String.init) ?? ""
  }

  public var causeName: String {
    switch cause {
    case .refused: "refused"
    case .openFailed: "openFailed"
    }
  }
}
