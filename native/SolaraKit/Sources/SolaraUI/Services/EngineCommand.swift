import Foundation
import SolaraModel
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

  private static func site(_ address: String) -> String? {
    guard let url = URL(string: address), let scheme = url.scheme?.lowercased(),
      ["http", "https"].contains(scheme), let host = url.host?.lowercased(), !host.isEmpty, url.port.map({ (0...65535).contains($0) }) ?? true else { return nil }
    let port = url.port.flatMap { ($0 == 80 && scheme == "http") || ($0 == 443 && scheme == "https") ? nil : $0 }
    return "\(scheme)://\(host)\(port.map { ":\($0)" } ?? "")"
  }

  public static func plan(tab: Tab, currentEngine: String, destination: String) -> Plan? {
    let url = tab.url.isEmpty ? tab.navigation?.url ?? "" : tab.url
    guard ["chromium", "webkit"].contains(destination), url.range(of: "^(https?|file):", options: [.regularExpression, .caseInsensitive]) != nil else { return nil }
    return Plan(tab: tab, source: currentEngine, engine: destination)
  }

  public static let unsavedWork = #"(() => { const fields = Array.from(document.querySelectorAll('input:not([type=hidden]):not([type=password]):not([type=submit]):not([type=button]), textarea, select')); const changed = f => f.type === 'checkbox' || f.type === 'radio' ? f.checked !== f.defaultChecked : f.tagName === 'SELECT' ? Array.from(f.options).some(o => o.selected !== o.defaultSelected) : f.value !== f.defaultValue; post('result', JSON.stringify(fields.some(changed) || !!(document.activeElement && document.activeElement.isContentEditable))); })()"#
}
