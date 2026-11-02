import Foundation
import SolaraStore

public struct PageNavigationEntry: Codable, Equatable, Sendable {
  public let url: String
  public let title: String
  public let current: Bool

  public init(url: String, title: String, current: Bool) {
    self.url = url
    self.title = title
    self.current = current
  }
}

public struct PagePicture: Codable, Equatable, Sendable {
  public let data: String
  public let frame: [Double]
}

public struct PageImage: Codable, Equatable, Sendable {
  public let uri: String
  public let width: Double
  public let height: Double
}

public struct PageCertificatePrincipal: Codable, Equatable, Sendable {
  public let commonName: String
  public let displayName: String
  public let organizations: [String]
  public let country: String
}

public struct PageCertificate: Codable, Equatable, Sendable {
  public let subject: PageCertificatePrincipal
  public let issuer: PageCertificatePrincipal
  public let validFrom: Double
  public let validUntil: Double
  public let serialNumber: String?
  public let sha256: String?
  public let chainLength: Int
}

public struct PageSecurityInfo: Codable, Equatable, Sendable {
  public let level: String
  public let url: String
  public let origin: String?
  public let `protocol`: String?
  public let certificate: PageCertificate?
  public let certificateErrors: [String]?
  public let mixedContent: String?
  public let isEV: Bool?
  public let chromium: String?
}

public enum PageCookieRemoval: Codable, Equatable, Sendable {
  case failed
  case count(Int)

  public init(from decoder: any Decoder) throws {
    let container = try decoder.singleValueContainer()
    if let value = try? container.decode(Bool.self), value == false { self = .failed }
    else if let count = try? container.decode(Int.self), count >= 0 { self = .count(count) }
    else { throw PageRegistryError.invalidValue }
  }

  public func encode(to encoder: any Encoder) throws {
    var container = encoder.singleValueContainer()
    switch self {
    case .failed: try container.encode(false)
    case .count(let count): try container.encode(count)
    }
  }
}

public enum PageExtensionAction: String, Codable, Equatable, Sendable {
  case none
  case popup
  case sidePanel
}

public enum PageDiscardOutcome: String, Codable, Equatable, Sendable {
  case discarded
  case already
  case refused
  case unsupported
}

public struct PageSiteDataResult: Codable, Equatable, Sendable {
  public let cookies: PageCookieRemoval
  public let storage: Bool
}

@MainActor
public struct PageRequest<Output> {
  public let command: PageCommand
  public let decode: (PageValue) throws -> Output

  public init(command: PageCommand, decode: @escaping (PageValue) throws -> Output) {
    self.command = command
    self.decode = decode
  }
}

private func pageDecoded<T: Decodable>(_ value: PageValue, as: T.Type = T.self) throws -> T {
  do {
    let data = try JSONSerialization.data(withJSONObject: value.foundation, options: [.fragmentsAllowed])
    return try JSONDecoder().decode(T.self, from: data)
  } catch {
    throw PageRegistryError.invalidValue
  }
}

public extension PageRequest where Output == Void {
  static func void(_ command: PageCommand) -> Self {
    Self(command: command) { value in
      guard value == .null else { throw PageRegistryError.invalidValue }
    }
  }

  static var reload: Self { .void(.reload) }
  static var forceReload: Self { .void(.forceReload) }
  static func goToOffset(_ offset: Int) -> Self { .void(.goToOffset(offset)) }
  static func zoomStep(_ direction: Int) -> Self { .void(.zoomStep(direction)) }
  static func runPageCommand(_ name: String) -> Self { .void(.runPageCommand(name)) }
  static func showDevTools(_ panel: String? = nil) -> Self { .void(.showDevTools(panel)) }
  static func executeJavaScript(_ code: String) -> Self { .void(.executeJavaScript(code)) }
  static func mediaCommand(_ action: String, seconds: Double = 0) -> Self { .void(.mediaCommand(action, seconds)) }
  static var exitPictureInPicture: Self { .void(.exitPictureInPicture) }
  static func openBlockedPopup(_ id: String, always: Bool = false) -> Self { .void(.openBlockedPopup(id, always)) }
  static func resolvePasswordPrompt(_ action: String, username: String? = nil, password: String? = nil) -> Self {
    .void(.resolvePasswordPrompt(action, username, password))
  }
  static func resolveAutofillPrompt(_ id: Int, action: String) -> Self { .void(.resolveAutofillPrompt(id, action)) }
  static func resolveDisplayMedia(_ id: String, sourceID: String?, audio: Bool = false) -> Self { .void(.resolveDisplayMedia(id, sourceID, audio)) }
  static func resolveUnresponsive(_ terminate: Bool) -> Self { .void(.resolveUnresponsive(terminate)) }
  static var stopLoading: Self { .void(.stopLoading) }
  static var goBack: Self { .void(.goBack) }
  static var goForward: Self { .void(.goForward) }
  static var focus: Self { .void(.focus) }
  static var print: Self { .void(.print) }
  static func loadUrl(_ url: String, userInitiated: Bool = false) -> Self { .void(.loadUrl(url, userInitiated)) }
  static func find(_ text: String, forward: Bool, findNext: Bool) -> Self { .void(.find(text, forward, findNext)) }
  static func stopFinding(_ clear: Bool) -> Self { .void(.stopFinding(clear)) }
  static func setMuted(_ muted: Bool) -> Self { .void(.setMuted(muted)) }
  static func setFrozen(_ frozen: Bool) -> Self { .void(.setFrozen(frozen)) }
}

public extension PageRequest where Output == PageValue {
  static func evaluate(_ code: String) -> Self {
    Self(command: .evaluate(code)) { value in
      guard value != .null else { return .null }
      guard case .string(let string) = value, let data = string.data(using: .utf8) else { throw PageRegistryError.invalidValue }
      do { return try PageValue(any: JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed])) }
      catch { throw PageRegistryError.invalidValue }
    }
  }

  static var livePage: Self { Self(command: .livePage) { $0 } }
  static func pageCookies(_ urls: [String]) -> Self { Self(command: .pageCookies(urls)) { $0 } }
}

public extension PageRequest where Output == [PageNavigationEntry] {
  static var navigationEntries: Self { Self(command: .navigationEntries) { try pageDecoded($0) } }
}

public extension PageRequest where Output == PagePicture? {
  static func capturePicture(_ scale: Double) -> Self {
    Self(command: .capturePicture(scale)) { value in
      guard value != .null else { return nil }
      let picture: PagePicture = try pageDecoded(value)
      guard picture.frame.count == 4, picture.frame.allSatisfy(\.isFinite) else { throw PageRegistryError.invalidValue }
      return picture
    }
  }
}

public extension PageRequest where Output == PageImage? {
  static func downloadImage(_ url: String, maxPixels: Int) -> Self {
    Self(command: .downloadImage(url, maxPixels)) { value in value == .null ? nil : try pageDecoded(value) }
  }

  static func downloadFavicon(_ url: String) -> Self {
    Self(command: .downloadFavicon(url)) { value in value == .null ? nil : try pageDecoded(value) }
  }
}

public extension PageRequest where Output == PageSecurityInfo? {
  static var getSecurityInfo: Self { Self(command: .getSecurityInfo) { value in value == .null ? nil : try pageDecoded(value) } }
}

public extension PageRequest where Output == PageSiteDataResult {
  static var clearSiteData: Self { Self(command: .clearSiteData) { try pageDecoded($0) } }
}

public extension PageRequest where Output == Bool {
  static func finishPageIssue(_ guardValue: PageIssueGuard) -> Self {
    Self(command: .finishPageIssue(guardValue)) { value in
      guard case .object(let fields) = value, let raw = fields["accepted"], case .bool(let accepted) = raw else { throw PageRegistryError.invalidValue }
      return accepted
    }
  }

  static func requestPictureInPicture(_ clickAt: Double = 0, control: Int = 0) -> Self {
    Self(command: .requestPictureInPicture(clickAt, control)) { try pageDecoded($0) }
  }

  static func takeControlPress(_ clickAt: Double = 0, control: Int = 0) -> Self {
    Self(command: .takeControlPress(clickAt, control)) { try pageDecoded($0) }
  }
}

public extension PageRequest where Output == Int? {
  static var nativeTag: Self { Self(command: .nativeTag) { value in value == .null ? nil : try pageDecoded(value) } }
}

public extension PageRequest where Output == String? {
  static var mediaCaptureSourceId: Self { Self(command: .mediaCaptureSourceId) { value in value == .null ? nil : try pageDecoded(value) } }
}

public extension PageRequest where Output == PageExtensionAction? {
  static func executeExtensionAction(_ id: String) -> Self {
    Self(command: .executeExtensionAction(id)) { value in value == .null ? nil : try pageDecoded(value) }
  }
}

public extension PageRequest where Output == PageDiscardOutcome {
  static func discard(_ unload: Bool = false) -> Self { Self(command: .discard(unload)) { try pageDecoded($0) } }
}
