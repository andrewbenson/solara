import Foundation
import SolaraModel

public struct AppVersionDecision: Sendable, Equatable {
  public let updated: Bool
  public let pending: JSONValue
  public let document: JSONObject?
}

public enum AppOnboardingDecision: String, Sendable {
  case none, start, resume, complete
}

public enum AppDefaultOfferEligibility: String, Sendable {
  case none, testInstance, eligible
}

public enum AppDefaultOfferOutcome: String, Sendable {
  case onboarding, alreadyDefault, asked
}

public struct AppDefaultOfferDecision: Sendable, Equatable {
  public let document: JSONObject
  public let outcome: AppDefaultOfferOutcome
  public var requestDefault: Bool { outcome == .asked }
}

public enum AppNotificationTarget: Sendable, Equatable {
  case none
  case tab(String)
  case window(String)
}

public enum AppStartupPolicy {
  public static func version(
    current: String, saved: JSONValue?, hasSession: Bool, refused: Bool, safeMode: Bool,
    development: Bool, forcePostcard: Bool, now: Double, knownVersions: Set<String> = ["1.0"]
  ) -> AppVersionDecision {
    guard !current.isEmpty, !refused else { return AppVersionDecision(updated: false, pending: .null, document: nil) }
    let updated = saved?.truthy == true ? saved?["lastVersion"] != .string(current) : hasSession
    let existing = saved?["pending"] ?? .null
    var pending = existing.isNull ? .null : existing
    if development {
      if forcePostcard { pending = ["version": .string(current), "since": .number(now)] }
    } else if updated {
      pending = knownVersions.contains(where: { $0.jsEquals(current) }) ? ["version": .string(current), "since": .number(now)] : .null
    }
    if pending.truthy && now - number(pending["since"]) > 86_400_000 { pending = .null }
    let document: JSONObject? = safeMode ? nil : ["version": 1, "lastVersion": .string(current), "pending": pending]
    return AppVersionDecision(updated: updated, pending: pending, document: document)
  }

  public static func onboarding(
    saved: JSONValue?, hasSession: Bool, refused: Bool, safeMode: Bool,
    hosted: Bool, development: Bool, force: Bool, committedJoinToken: String? = nil
  ) -> AppOnboardingDecision {
    guard !safeMode, hosted else { return .none }
    if let token = committedJoinToken {
      let completion = saved?["joinedCompletionToken"]?.string
      let entered = saved?["joinedEnteredBrowser"]?.bool == true && (completion == nil || completion == token)
      return entered ? .none : .resume
    }
    guard saved?["completedAt"]?.truthy != true else { return .none }
    if saved?["startedAt"]?.truthy == true { return .resume }
    guard !refused else { return .none }
    if hasSession { return .complete }
    if development && !force { return .none }
    return .start
  }

  public static func onboardingDocument(saved: JSONValue?, patch: JSONObject) -> JSONObject {
    var document: JSONObject = ["version": 1, "completedAt": nil]
    for (key, value) in spread(saved) { document[key] = value }
    for (key, value) in patch { document[key] = value }
    return document
  }

  public static func defaultOffer(saved: JSONValue?, testInstance: Bool) -> AppDefaultOfferEligibility {
    guard saved?.truthy == true, saved?["askedAt"]?.truthy != true else { return .none }
    return testInstance ? .testInstance : .eligible
  }

  public static func completeDefaultOffer(saved: JSONValue, onboarding: Bool, isDefault: Bool, now: Double) -> AppDefaultOfferDecision {
    var document = spread(saved)
    document["askedAt"] = .number(now)
    let outcome: AppDefaultOfferOutcome = onboarding ? .onboarding : isDefault ? .alreadyDefault : .asked
    return AppDefaultOfferDecision(document: document, outcome: outcome)
  }

  public static func releaseNotesURL(page: String?, version: String) -> String? {
    guard let page = videoURL(page: page) else { return nil }
    return version.isEmpty ? page : "\(page)#\(version)"
  }

  public static func videoURL(page: String?) -> String? {
    guard let page, page.range(of: "^https?://", options: [.regularExpression, .caseInsensitive]) != nil else { return nil }
    return page
  }

  public static func shouldOpenAfterUpdate(development: Bool, isolated: Bool, force: Bool) -> Bool {
    force || (!development && !isolated)
  }

  public static func opensReleaseNotes(updated: Bool, development: Bool, isolated: Bool, force: Bool) -> Bool {
    updated && shouldOpenAfterUpdate(development: development, isolated: isolated, force: force)
  }

  public static func notificationTarget(state: BrowserState, action: String, tabId: String?, windowId: String?) -> AppNotificationTarget {
    guard action == "click" else { return .none }
    if let tabId, !tabId.isEmpty, state.tabs[tabId] != nil { return .tab(tabId) }
    if let windowId, !windowId.isEmpty, state.windows[windowId] != nil { return .window(windowId) }
    return .none
  }

  private static func spread(_ value: JSONValue?) -> JSONObject {
    switch value {
    case .object(let object): return object
    case .array(let array): return JSONObject(array.enumerated().map { (String($0.offset), $0.element) })
    case .string(let string): return JSONObject(string.utf16.enumerated().map { (String($0.offset), .string(String(utf16Units: [$0.element]))) })
    default: return [:]
    }
  }

  private static func number(_ value: JSONValue?) -> Double {
    switch value {
    case .null: return 0
    case .bool(let value): return value ? 1 : 0
    case .number(let value): return value
    case .string(let value): return numericString(value)
    case .array(let values): return numericString(values.map(arrayElementString).joined(separator: ","))
    default: return .nan
    }
  }

  private static func arrayElementString(_ value: JSONValue) -> String {
    switch value {
    case .null: return ""
    case .bool(let value): return value ? "true" : "false"
    case .number(let value): return jsNumberText(value)
    case .string(let value): return value
    case .array(let values): return values.map(arrayElementString).joined(separator: ",")
    case .object: return "[object Object]"
    }
  }

  private static func numericString(_ value: String) -> Double {
    let text = value.jsTrim()
    if text.isEmpty { return 0 }
    if text == "Infinity" || text == "+Infinity" { return .infinity }
    if text == "-Infinity" { return -.infinity }
    let units = Array(text.utf8)
    if units.count > 2, units[0] == 48 {
      let radix: Int
      switch units[1] {
      case 88, 120: radix = 16
      case 66, 98: radix = 2
      case 79, 111: radix = 8
      default: radix = 0
      }
      if radix != 0 {
        var result = 0.0
        for unit in units.dropFirst(2) {
          let digit: Int
          switch unit {
          case 48...57: digit = Int(unit - 48)
          case 65...70: digit = Int(unit - 65) + 10
          case 97...102: digit = Int(unit - 97) + 10
          default: return .nan
          }
          guard digit < radix else { return .nan }
          result = result * Double(radix) + Double(digit)
        }
        return result
      }
    }
    guard text.range(of: "^[+-]?(?:[0-9]+(?:\\.[0-9]*)?|\\.[0-9]+)(?:[eE][+-]?[0-9]+)?$", options: .regularExpression) != nil else { return .nan }
    return Double(text) ?? .nan
  }
}
