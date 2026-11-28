import Foundation

public struct PanePasswordPrompt: Equatable, Sendable {
  public var origin: String
  public var username: String
  public var usernames: [String]
  public var update: Bool
  public var passwordLength: Int
  public var federation: String

  public init?(_ payload: [String: Any]) {
    guard let state = payload["state"] as? String, state == "save" || state == "update", let origin = payload["origin"] as? String else { return nil }
    self.origin = origin
    username = payload["username"] as? String ?? ""
    usernames = payload["usernames"] as? [String] ?? []
    update = state == "update"
    passwordLength = (payload["passwordLength"] as? NSNumber)?.intValue ?? 0
    federation = payload["federation"] as? String ?? ""
  }

  public var key: String { "\(origin)|\(username)|\(update ? "update" : "save")" }
}

public struct PaneAutofillPrompt: Equatable, Sendable {
  public struct Change: Equatable, Sendable {
    public var from: String
    public var to: String
  }

  public var id: Int
  public var kind: String
  public var title: String
  public var message: String
  public var accept: String
  public var decline: String
  public var footer: String
  public var lines: [String]
  public var changes: [Change]
  public var newLabel: String?
  public var oldLabel: String?

  public init?(_ payload: [String: Any]) {
    guard payload["closed"] as? Bool != true, let id = (payload["id"] as? NSNumber)?.intValue, let kind = payload["kind"] as? String else { return nil }
    self.id = id
    self.kind = kind
    title = payload["title"] as? String ?? ""
    message = payload["message"] as? String ?? ""
    accept = payload["accept"] as? String ?? ""
    decline = payload["decline"] as? String ?? ""
    footer = payload["footer"] as? String ?? ""
    lines = payload["lines"] as? [String] ?? []
    changes = (payload["changes"] as? [[String: Any]] ?? []).map { Change(from: $0["from"] as? String ?? "", to: $0["to"] as? String ?? "") }
    newLabel = (payload["newLabel"] as? String).flatMap { $0.isEmpty ? nil : $0 }
    oldLabel = payload["oldLabel"] as? String
  }

  public var key: String { String(id) }
}

public struct PaneExternalApp: Equatable, Sendable {
  public var id: String
  public var app: String?
  public var origin: String?
  public var icon: String?
  public var title: String
  public var message: String?
  public var remember: String?

  public init?(_ payload: [String: Any]) {
    guard let id = payload["id"] as? String, let title = payload["title"] as? String else { return nil }
    self.id = id
    self.title = title
    app = payload["app"] as? String
    origin = payload["origin"] as? String
    icon = payload["icon"] as? String
    message = payload["message"] as? String
    remember = payload["remember"] as? String
  }

  public var key: String { id }
}

public struct PaneBlockedPopup: Equatable, Sendable {
  public let id: String
  public let url: String
  public let origin: String

  public init?(_ payload: [String: Any]) {
    guard let id = payload["id"] as? String, let url = payload["url"] as? String,
      let origin = payload["origin"] as? String else { return nil }
    self.id = id
    self.url = url
    self.origin = origin
  }

  public var payload: [String: String] { ["id": id, "url": url, "origin": origin] }
}

public struct PanePromptPage: Equatable, Sendable {
  public var crashed = false
  public var unresponsive = false
  public var pageKey: String?
  public var password: PanePasswordPrompt?
  public var chosenUsername: String?
  public var autofill: PaneAutofillPrompt?
  public var externalApp: PaneExternalApp?
  public var alwaysOpen = false
  public var popups: [PaneBlockedPopup] = []
  public var permissions: [PanePermissionRequest] = []
  public var chooser: PaneDeviceChooser?
  public var chooserSelected: Int?
  public var chooserAnswered = false
  public var selection: PaneSelection?

  public init() {}

  public var sadMode: SadTabMode? { crashed ? .crashed : unresponsive ? .unresponsive : nil }

  public var shown: PanePromptPage {
    var page = self
    page.pageKey = nil
    return page
  }

  public mutating func take(_ name: String, _ payload: [String: Any]) -> Bool {
    let before = self
    switch name {
    case "onPageCreated", "onPageGone": self = PanePromptPage()
    case "onDocumentCommitted", "onDiscarded", "onWindowClose":
      clearPrompts()
    case "onCrashed":
      clearPrompts()
      crashed = true
      unresponsive = false
    case "onUnresponsive": unresponsive = true
    case "onResponsive": unresponsive = false
    case "onPasswordPrompt":
      password = PanePasswordPrompt(payload)
      chosenUsername = nil
    case "onAutofillPrompt":
      if let prompt = PaneAutofillPrompt(payload) {
        autofill = prompt
      } else if let id = (payload["id"] as? NSNumber)?.intValue, autofill?.id == id {
        autofill = nil
      }
    case "onPopupBlocked":
      if let popup = PaneBlockedPopup(payload), !popups.contains(where: { $0.id == popup.id }) {
        popups.append(popup)
      }
    case "onExternalApp":
      if payload["closed"] as? Bool == true {
        if let id = payload["id"] as? String, externalApp?.id == id {
          externalApp = nil
          alwaysOpen = false
        }
      } else {
        externalApp = PaneExternalApp(payload)
        alwaysOpen = false
      }
    case "onPageMessage":
      if payload["kind"] as? String == "selection" { selection = PaneSelection(payload["data"]) }
    case "onNavigationChange":
      guard let reported = payload["url"] as? String else { break }
      let blankInitial = payload["initialDocumentAccessed"] as? Bool == true && payload["committedInitial"] as? Bool == true
      let key = Self.pageKey(blankInitial ? "about:blank" : reported)
      if let pageKey, pageKey != key {
        crashed = false
        password = nil
        chosenUsername = nil
        permissions = []
        popups = []
        selection = nil
        if externalApp != nil, Self.host(key) != Self.host(pageKey) {
          externalApp = nil
          alwaysOpen = false
        }
      }
      pageKey = key
    default: break
    }
    return self != before
  }

  private mutating func clearPrompts() {
    popups = []
    permissions = []
  }

  public static func pageKey(_ url: String) -> String {
    url.firstIndex(of: "#").map { String(url[..<$0]) } ?? url
  }

  static func host(_ url: String) -> String {
    guard let scheme = url.range(of: "://"), url[..<scheme.lowerBound].first?.isLetter == true else { return "" }
    let rest = url[scheme.upperBound...]
    return String(rest.prefix { !"/?#".contains($0) }).lowercased()
  }
}
