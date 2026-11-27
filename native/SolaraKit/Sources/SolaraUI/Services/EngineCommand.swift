import Foundation
import SolaraModel
import SolaraOmnibox
import SolaraStore

public enum EngineCommand {
  public struct Plan: Equatable, Sendable {
    public let tab: Tab
    public let source: String
    public let engine: String
    public var url: String { tab.url.isEmpty ? tab.navigation?.url ?? "" : tab.url }
    public var replacesPage: Bool { source != engine }
    public var canRemember: Bool { !Ids.isIncognitoProfile(tab.profileId) }
    public func current(tab: Tab?, engine: String) -> Bool {
      guard let tab else { return false }
      return tab.id == self.tab.id && tab.windowId == self.tab.windowId && tab.profileId == self.tab.profileId
        && tab.url == self.tab.url && tab.navigation == self.tab.navigation && tab.adoptId == self.tab.adoptId && engine == source
    }
  }

  public static func differentSite(from previous: String, to next: String) -> Bool {
    guard let next = site(next) else { return false }
    return next != site(previous)
  }

  public static func site(_ address: String) -> String? {
    guard let url = WhatwgURL(address), ["http:", "https:"].contains(url.protocol), !url.hostname.isEmpty else { return nil }
    return url.protocol + "//" + url.host
  }

  public static func plan(tab: Tab, currentEngine: String, destination: String) -> Plan? {
    let url = tab.url.isEmpty ? tab.navigation?.url ?? "" : tab.url
    guard ["chromium", "webkit"].contains(destination), url.range(of: "^(https?|file):", options: [.regularExpression, .caseInsensitive]) != nil else { return nil }
    return Plan(tab: tab, source: currentEngine, engine: destination)
  }

  public static let unsavedWork = #"(() => { const fields = Array.from(document.querySelectorAll('input:not([type=hidden]):not([type=password]):not([type=submit]):not([type=button]), textarea, select')); const changed = f => f.type === 'checkbox' || f.type === 'radio' ? f.checked !== f.defaultChecked : f.tagName === 'SELECT' ? Array.from(f.options).some(o => o.selected !== o.defaultSelected) : f.value !== f.defaultValue; post('result', JSON.stringify(fields.some(changed) || !!(document.activeElement && document.activeElement.isContentEditable))); })()"#
}

public struct EngineOfferThrottle: Sendable {
  private var started: [String: TimeInterval] = [:]

  public init() {}

  public mutating func begin(tabId: String, now: TimeInterval) -> Bool {
    if let last = started[tabId], now - last < 10 { return false }
    started[tabId] = now
    return true
  }

  public mutating func remove(tabId: String) { started[tabId] = nil }
}

public struct PageActionScope: Equatable, Sendable {
  public let identity: PageIdentity
  public let documentRevision: Int
  public let tab: Tab

  public init(identity: PageIdentity, documentRevision: Int, tab: Tab) {
    self.identity = identity
    self.documentRevision = documentRevision
    self.tab = tab
  }

  public static func == (lhs: Self, rhs: Self) -> Bool {
    lhs.identity == rhs.identity && lhs.documentRevision == rhs.documentRevision &&
      lhs.tab.windowId == rhs.tab.windowId && lhs.tab.profileId == rhs.tab.profileId &&
      lhs.tab.createdAt == rhs.tab.createdAt && lhs.tab.url == rhs.tab.url && lhs.tab.navigation == rhs.tab.navigation && lhs.tab.adoptId == rhs.tab.adoptId
  }
}
