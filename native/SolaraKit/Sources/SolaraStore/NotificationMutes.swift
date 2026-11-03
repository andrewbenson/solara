import Foundation
import SolaraModel

extension Store {
  public func silencesNotifications(profileDirectory: String, origin: String) -> Bool {
    guard let engine = Self.engineProfileName(directory: profileDirectory) else { return false }
    let host = Self.siteHost(origin, env)
    guard !host.isEmpty else { return false }
    let s = state
    let profiles = Set(s.profileOrder.filter { s.profiles[$0] != nil && !Ids.isIncognitoProfile($0) && s.engineProfile($0) == engine })
    guard !profiles.isEmpty else { return false }
    if (s.settings.strings("mutedSites") ?? []).contains(host) { return true }
    return s.tabs.values.contains { profiles.contains($0.profileId) && $0.muted && Self.siteHost($0.url, env) == host }
  }

  static func engineProfileName(directory: String) -> String? {
    let name = URL(fileURLWithPath: directory).lastPathComponent
    if name == "Default" { return "" }
    let prefix = "Profile "
    guard name.hasPrefix(prefix), name.count > prefix.count else { return nil }
    return String(name.dropFirst(prefix.count))
  }

  static func siteHost(_ url: String, _ env: WebAddressing) -> String {
    guard let host = env.parseURL(url)?.hostname else { return "" }
    return host.hasPrefix("www.") ? String(host.dropFirst(4)) : host
  }
}
