import Foundation
import CoreFoundation
import SolaraModel
import SolaraStore

public indirect enum PageValue: Equatable, Sendable {
  case null
  case bool(Bool)
  case number(Double)
  case string(String)
  case array([PageValue])
  case object([String: PageValue])

  public init(any: Any?) throws {
    switch Self.unboxed(any) {
    case nil, is NSNull: self = .null
    case let value as String: self = .string(value)
    case let value as NSNumber:
      if CFGetTypeID(value) == CFBooleanGetTypeID() { self = .bool(value.boolValue) }
      else if value.doubleValue.isFinite { self = .number(value.doubleValue) }
      else { throw PageRegistryError.invalidValue }
    case let value as [Any]: self = .array(try value.map { try PageValue(any: $0) })
    case let value as [String: Any]: self = .object(try value.mapValues { try PageValue(any: $0) })
    default: throw PageRegistryError.invalidValue
    }
  }

  private static func unboxed(_ value: Any?) -> Any? {
    guard let value else { return nil }
    let mirror = Mirror(reflecting: value)
    guard mirror.displayStyle == .optional else { return value }
    return unboxed(mirror.children.first?.value)
  }

  public var foundation: Any {
    switch self {
    case .null: NSNull()
    case .bool(let value): value
    case .number(let value): value
    case .string(let value): value
    case .array(let value): value.map(\.foundation)
    case .object(let value): value.mapValues(\.foundation)
    }
  }
}

public extension PageValue {
  init(json: JSONValue) {
    switch json {
    case .null: self = .null
    case .bool(let value): self = .bool(value)
    case .number(let value): self = .number(value)
    case .string(let value): self = .string(value)
    case .array(let values): self = .array(values.map(PageValue.init(json:)))
    case .object(let values): self = .object(Dictionary(uniqueKeysWithValues: values.map { ($0.key, PageValue(json: $0.value)) }))
    }
  }

  var json: JSONValue {
    switch self {
    case .null: .null
    case .bool(let value): .bool(value)
    case .number(let value): .number(value)
    case .string(let value): .string(value)
    case .array(let values): .array(values.map(\.json))
    case .object(let values): .object(JSONObject(values.map { ($0.key, $0.value.json) }))
    }
  }
}

public enum PageEngine: String, Sendable {
  case chromium
  case webKit = "webkit"
}
public enum PageHost: String, Sendable { case pooled, reactNative }

public enum PageResultKind: Sendable {
  case none, any, boolean, string, optionalString, object, optionalObject, array, optionalInteger

  public func accepts(_ value: PageValue) -> Bool {
    switch (self, value) {
    case (.any, _), (.none, .null), (.boolean, .bool), (.string, .string), (.optionalString, .null),
      (.optionalString, .string), (.object, .object), (.optionalObject, .object), (.optionalObject, .null),
      (.array, .array), (.optionalInteger, .null): true
    case (.optionalInteger, .number(let value)): value.isFinite && value.rounded() == value && Int(exactly: value) != nil
    default: false
    }
  }
}

public enum PageCommand: Equatable, Sendable {
  case loadUrl(String, Bool)
  case goBack
  case goForward
  case goToOffset(Int)
  case reload
  case forceReload
  case stopLoading
  case focus
  case setMuted(Bool)
  case zoomStep(Int)
  case find(String, Bool, Bool)
  case stopFinding(Bool)
  case print
  case runPageCommand(String)
  case showDevTools(String?)
  case executeJavaScript(String)
  case evaluate(String)
  case navigationEntries
  case capturePicture(Double)
  case downloadFavicon(String)
  case downloadImage(String, Int)
  case mediaCommand(String, Double)
  case requestPictureInPicture(Double, Int)
  case takeControlPress(Double, Int)
  case exitPictureInPicture
  case getSecurityInfo
  case pageCookies([String])
  case openBlockedPopup(String, Bool)
  case clearSiteData
  case resolvePasswordPrompt(String, String?, String?)
  case resolveAutofillPrompt(Int, String)
  case executeExtensionAction(String)
  case resolveDisplayMedia(String, String?, Bool)
  case mediaCaptureSourceId
  case resolveUnresponsive(Bool)
  case discard(Bool)
  case setFrozen(Bool)
  case nativeTag
  case livePage
  case finishPageIssue(PageIssueGuard)

  public var method: String {
    switch self {
    case .loadUrl: "loadUrl"
    case .goBack: "goBack"
    case .goForward: "goForward"
    case .goToOffset: "goToOffset"
    case .reload: "reload"
    case .forceReload: "forceReload"
    case .stopLoading: "stopLoading"
    case .focus: "focus"
    case .setMuted: "setMuted"
    case .zoomStep: "zoomStep"
    case .find: "find"
    case .stopFinding: "stopFinding"
    case .print: "print"
    case .runPageCommand: "runPageCommand"
    case .showDevTools: "showDevTools"
    case .executeJavaScript: "executeJavaScript"
    case .evaluate: "evaluate"
    case .navigationEntries: "navigationEntries"
    case .capturePicture: "capturePicture"
    case .downloadFavicon: "downloadFavicon"
    case .downloadImage: "downloadImage"
    case .mediaCommand: "mediaCommand"
    case .requestPictureInPicture: "requestPictureInPicture"
    case .takeControlPress: "takeControlPress"
    case .exitPictureInPicture: "exitPictureInPicture"
    case .getSecurityInfo: "getSecurityInfo"
    case .pageCookies: "pageCookies"
    case .openBlockedPopup: "openBlockedPopup"
    case .clearSiteData: "clearSiteData"
    case .resolvePasswordPrompt: "resolvePasswordPrompt"
    case .resolveAutofillPrompt: "resolveAutofillPrompt"
    case .executeExtensionAction: "executeExtensionAction"
    case .resolveDisplayMedia: "resolveDisplayMedia"
    case .mediaCaptureSourceId: "mediaCaptureSourceId"
    case .resolveUnresponsive: "resolveUnresponsive"
    case .discard: "discard"
    case .setFrozen: "setFrozen"
    case .nativeTag: "nativeTag"
    case .livePage: "livePage"
    case .finishPageIssue: "finishPageIssue"
    }
  }

  public var arguments: [PageValue] {
    switch self {
    case .loadUrl(let url, let user): [.string(url), .bool(user)]
    case .goToOffset(let value), .zoomStep(let value): [.number(Double(value))]
    case .setMuted(let value), .stopFinding(let value), .resolveUnresponsive(let value), .discard(let value), .setFrozen(let value): [.bool(value)]
    case .find(let text, let forward, let next): [.string(text), .bool(forward), .bool(next)]
    case .runPageCommand(let value), .executeJavaScript(let value), .evaluate(let value), .downloadFavicon(let value),
      .executeExtensionAction(let value): [.string(value)]
    case .showDevTools(let value): [value.map(PageValue.string) ?? .null]
    case .capturePicture(let value): [.number(value)]
    case .downloadImage(let url, let pixels): [.string(url), .number(Double(pixels))]
    case .mediaCommand(let command, let seconds): [.string(command), .number(seconds)]
    case .requestPictureInPicture(let time, let control), .takeControlPress(let time, let control): [.number(time), .number(Double(control))]
    case .pageCookies(let urls): [.array(urls.map(PageValue.string))]
    case .openBlockedPopup(let id, let always): [.string(id), .bool(always)]
    case .resolvePasswordPrompt(let action, let username, let password): [.string(action), username.map(PageValue.string) ?? .null, password.map(PageValue.string) ?? .null]
    case .resolveAutofillPrompt(let id, let action): [.number(Double(id)), .string(action)]
    case .resolveDisplayMedia(let request, let source, let audio): [.string(request), source.map(PageValue.string) ?? .null, .bool(audio)]
    case .finishPageIssue(let guardValue): [PageValue(json: guardValue.json)]
    default: []
    }
  }

  public var waitsForTheUser: Bool {
    switch self {
    case .print, .runPageCommand, .evaluate, .executeJavaScript: true
    default: false
    }
  }

  public var resultKind: PageResultKind {
    switch self {
    case .loadUrl: .none
    case .goBack: .none
    case .goForward: .none
    case .goToOffset: .none
    case .reload: .none
    case .forceReload: .none
    case .stopLoading: .none
    case .focus: .none
    case .setMuted: .none
    case .zoomStep: .none
    case .find: .none
    case .stopFinding: .none
    case .print: .none
    case .runPageCommand: .none
    case .showDevTools: .none
    case .executeJavaScript: .none
    case .evaluate: .optionalString
    case .navigationEntries: .array
    case .capturePicture: .optionalObject
    case .downloadFavicon: .optionalObject
    case .downloadImage: .optionalObject
    case .mediaCommand: .none
    case .requestPictureInPicture: .boolean
    case .takeControlPress: .boolean
    case .exitPictureInPicture: .none
    case .getSecurityInfo: .optionalObject
    case .pageCookies: .array
    case .openBlockedPopup: .none
    case .clearSiteData: .object
    case .resolvePasswordPrompt: .none
    case .resolveAutofillPrompt: .none
    case .executeExtensionAction: .optionalString
    case .resolveDisplayMedia: .none
    case .mediaCaptureSourceId: .optionalString
    case .resolveUnresponsive: .none
    case .discard: .string
    case .setFrozen: .none
    case .nativeTag: .optionalInteger
    case .livePage: .optionalObject
    case .finishPageIssue: .object
    }
  }

  public var carriesPageData: Bool {
    switch self {
    case .evaluate, .navigationEntries, .capturePicture, .downloadFavicon, .downloadImage, .getSecurityInfo, .pageCookies,
      .executeExtensionAction, .mediaCaptureSourceId, .livePage: true
    case .loadUrl, .goBack, .goForward, .goToOffset, .reload, .forceReload, .stopLoading, .focus, .setMuted, .zoomStep,
      .find, .stopFinding, .print, .runPageCommand, .showDevTools, .executeJavaScript, .mediaCommand,
      .requestPictureInPicture, .takeControlPress, .exitPictureInPicture, .openBlockedPopup, .clearSiteData,
      .resolvePasswordPrompt, .resolveAutofillPrompt, .resolveDisplayMedia, .resolveUnresponsive,
      .discard, .setFrozen, .nativeTag, .finishPageIssue: false
    }
  }

  public func supports(engine: PageEngine) -> Bool {
    guard engine == .webKit else { return true }
    return switch self {
    case .showDevTools, .pageCookies, .openBlockedPopup, .resolvePasswordPrompt, .resolveAutofillPrompt,
      .executeExtensionAction, .resolveDisplayMedia, .mediaCaptureSourceId,
      .resolveUnresponsive, .discard, .setFrozen, .downloadImage: false
    default: true
    }
  }

  public static func decode(method: String, args: [PageValue]) throws -> PageCommand {
    let a = PageCommandArguments(method: method, values: args)
    switch method {
    case "loadUrl":
      try a.limit(2)
      return .loadUrl(try a.string(0), try a.bool(1, default: false))
    case "goBack":
      try a.limit(0)
      return .goBack
    case "goForward":
      try a.limit(0)
      return .goForward
    case "goToOffset":
      try a.limit(1)
      return .goToOffset(try a.int(0))
    case "reload":
      try a.limit(0)
      return .reload
    case "forceReload":
      try a.limit(0)
      return .forceReload
    case "stopLoading":
      try a.limit(0)
      return .stopLoading
    case "focus":
      try a.limit(0)
      return .focus
    case "setMuted":
      try a.limit(1)
      return .setMuted(try a.bool(0))
    case "zoomStep":
      try a.limit(1)
      return .zoomStep(try a.int(0))
    case "find":
      try a.limit(3)
      return .find(try a.string(0), try a.bool(1), try a.bool(2))
    case "stopFinding":
      try a.limit(1)
      return .stopFinding(try a.bool(0))
    case "print":
      try a.limit(0)
      return .print
    case "runPageCommand":
      try a.limit(1)
      return .runPageCommand(try a.string(0))
    case "showDevTools":
      try a.limit(1)
      return .showDevTools(try a.optionalString(0))
    case "executeJavaScript":
      try a.limit(1)
      return .executeJavaScript(try a.string(0))
    case "evaluate":
      try a.limit(1)
      return .evaluate(try a.string(0))
    case "navigationEntries":
      try a.limit(0)
      return .navigationEntries
    case "capturePicture":
      try a.limit(1)
      return .capturePicture(try a.double(0))
    case "downloadFavicon":
      try a.limit(1)
      return .downloadFavicon(try a.string(0))
    case "downloadImage":
      try a.limit(2)
      return .downloadImage(try a.string(0), try a.int(1))
    case "mediaCommand":
      try a.limit(2)
      return .mediaCommand(try a.string(0), try a.double(1, default: 0))
    case "requestPictureInPicture":
      try a.limit(2)
      return .requestPictureInPicture(try a.double(0, default: 0), try a.int(1, default: 0))
    case "takeControlPress":
      try a.limit(2)
      return .takeControlPress(try a.double(0, default: 0), try a.int(1, default: 0))
    case "exitPictureInPicture":
      try a.limit(0)
      return .exitPictureInPicture
    case "getSecurityInfo":
      try a.limit(0)
      return .getSecurityInfo
    case "pageCookies":
      try a.limit(1)
      return .pageCookies(try a.strings(0))
    case "openBlockedPopup":
      try a.limit(2)
      return .openBlockedPopup(try a.string(0), try a.bool(1, default: false))
    case "clearSiteData":
      try a.limit(0)
      return .clearSiteData
    case "resolvePasswordPrompt":
      try a.limit(3)
      return .resolvePasswordPrompt(try a.string(0), try a.optionalString(1), try a.optionalString(2))
    case "resolveAutofillPrompt":
      try a.limit(2)
      return .resolveAutofillPrompt(try a.int(0), try a.string(1))
    case "executeExtensionAction":
      try a.limit(1)
      return .executeExtensionAction(try a.string(0))
    case "resolveDisplayMedia":
      try a.limit(3)
      return .resolveDisplayMedia(try a.string(0), try a.optionalString(1), try a.bool(2, default: false))
    case "mediaCaptureSourceId":
      try a.limit(0)
      return .mediaCaptureSourceId
    case "resolveUnresponsive":
      try a.limit(1)
      return .resolveUnresponsive(try a.bool(0))
    case "discard":
      try a.limit(1)
      return .discard(try a.bool(0, default: false))
    case "setFrozen":
      try a.limit(1)
      return .setFrozen(try a.bool(0))
    case "nativeTag":
      try a.limit(0)
      return .nativeTag
    case "finishPageIssue":
      try a.limit(1)
      do { return .finishPageIssue(try PageIssueGuard(json: a.value(0).json)) }
      catch { throw PageRegistryError.invalidArguments(method, 0) }
    case "livePage":
      try a.limit(0)
      return .livePage
    default: throw PageRegistryError.unknownCommand(method)
    }
  }
}

private struct PageCommandArguments {
  let method: String
  let values: [PageValue]

  func limit(_ count: Int) throws {
    if values.count > count { throw PageRegistryError.invalidArguments(method, count) }
  }

  func value(_ index: Int) -> PageValue { index < values.count ? values[index] : .null }
  func invalid(_ index: Int) -> PageRegistryError { .invalidArguments(method, index) }

  func string(_ index: Int) throws -> String {
    guard case .string(let value) = value(index) else { throw invalid(index) }
    return value
  }

  func optionalString(_ index: Int) throws -> String? {
    if value(index) == .null { return nil }
    return try string(index)
  }

  func bool(_ index: Int, default fallback: Bool? = nil) throws -> Bool {
    if value(index) == .null, let fallback { return fallback }
    guard case .bool(let value) = value(index) else { throw invalid(index) }
    return value
  }

  func double(_ index: Int, default fallback: Double? = nil) throws -> Double {
    if value(index) == .null, let fallback { return fallback }
    guard case .number(let value) = value(index), value.isFinite else { throw invalid(index) }
    return value
  }

  func int(_ index: Int, default fallback: Int? = nil) throws -> Int {
    if value(index) == .null, let fallback { return fallback }
    guard case .number(let value) = value(index), let result = Int(exactly: value) else { throw invalid(index) }
    return result
  }

  func strings(_ index: Int) throws -> [String] {
    guard case .array(let values) = value(index) else { throw invalid(index) }
    return try values.map {
      guard case .string(let text) = $0 else { throw invalid(index) }
      return text
    }
  }
}
