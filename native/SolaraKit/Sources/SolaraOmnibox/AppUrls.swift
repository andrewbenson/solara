import Foundation
import Synchronization

public let upstreamAppScheme = "solara"

public enum AppPageHost: String, Sendable, Equatable, CaseIterable {
  case history, bookmarks, downloads

  public var title: String { rawValue.capitalized }
}

public enum AppUrlRoute: Sendable, Equatable {
  case page(AppPageHost)
  case settings(section: String?)
  case newTab
  case engine(url: String)
}

public enum AppScheme {
  private static let current = Mutex<String>(upstreamAppScheme)

  @TaskLocal static var scoped: String?

  public static var value: String { scoped ?? current.withLock { $0 } }

  @discardableResult
  public static func set(productName: String?) -> String {
    let scheme = appSchemeFor(productName)
    current.withLock { $0 = scheme }
    return scheme
  }

  public static func withScheme<T>(productName: String?, _ body: () throws -> T) rethrows -> T {
    try $scoped.withValue(appSchemeFor(productName), operation: body)
  }
}

private let reservedSchemes: Set<String> = ["http", "https", "file", "about", "data", "blob", "javascript", "view-source", "chrome", "chrome-extension", "devtools"]

public func appSchemeFor(_ productName: String?) -> String {
  let lowered = JS.lower(JS.trim((productName ?? "").units))
  let scheme = lowered.filter { Unit.isLowerAlnum($0) || $0 == Unit.plus || $0 == Unit.dot || $0 == Unit.dash }
  guard let first = scheme.first, Unit.isLowerAlpha(first) else { return upstreamAppScheme }
  let text = scheme.string
  return reservedSchemes.contains(text) ? upstreamAppScheme : text
}

@discardableResult
public func setAppScheme(_ productName: String?) -> String { AppScheme.set(productName: productName) }

public func appScheme() -> String { AppScheme.value }

public func isAppScheme(_ scheme: String) -> Bool {
  let lower = JS.lower(scheme)
  return lower.sameUnits(upstreamAppScheme) || lower.sameUnits(AppScheme.value)
}

private func appSchemes() -> [String] {
  let scheme = AppScheme.value
  return scheme == upstreamAppScheme ? [upstreamAppScheme] : [upstreamAppScheme, scheme]
}

private struct SplitUrl {
  var viewSource: Bool
  var host: Units
  var rest: Units
}

private func matchPrefix(_ url: Units, schemes: [String]) -> (viewSource: Bool, end: Int)? {
  var at = 0
  var viewSource = false
  if url.asciiCaseInsensitivePrefix("view-source:") {
    for scheme in schemes where url.asciiCaseInsensitivePrefix(scheme + ":", at: 12) {
      viewSource = true
      at = 12
      break
    }
  }
  for scheme in schemes where url.asciiCaseInsensitivePrefix(scheme + ":", at: at) {
    var end = at + scheme.utf16.count + 1
    if url.hasPrefix([Unit.slash, Unit.slash], at: end) { end += 2 }
    return (viewSource, end)
  }
  return nil
}

private func split(_ url: Units, schemes: [String]) -> SplitUrl? {
  guard let (viewSource, end) = matchPrefix(url, schemes: schemes) else { return nil }
  var hostEnd = end
  while hostEnd < url.count, url[hostEnd] != Unit.slash, url[hostEnd] != Unit.question, url[hostEnd] != Unit.hash { hostEnd += 1 }
  return SplitUrl(viewSource: viewSource, host: JS.lower(Array(url[end..<hostEnd])), rest: Array(url[hostEnd...]))
}

private func isAboutPage(_ url: Units) -> Bool {
  for name in ["blank", "srcdoc"] where url.asciiCaseInsensitivePrefix("about:" + name) {
    let at = 6 + name.utf16.count
    if at == url.count || url[at] == Unit.question || url[at] == Unit.hash { return true }
  }
  return false
}

private func aboutAlias(_ url: Units) -> Int? {
  guard url.asciiCaseInsensitivePrefix("about:"), url.count > 6, Unit.isAlpha(url[6]) else { return nil }
  var end = 7
  while end < url.count, Unit.isAlnum(url[end]) || url[end] == Unit.dash { end += 1 }
  return end
}

private let viewSourcePrefix = Units("view-source:")

func toAppUrl(_ url: Units) -> Units {
  let scheme = AppScheme.value
  if let parts = split(url, schemes: appSchemes()) ?? split(url, schemes: ["chrome"]) {
    if parts.host.isEmpty { return url }
    return (parts.viewSource ? viewSourcePrefix : []) + Units(scheme + "://") + parts.host + parts.rest
  }
  if isAboutPage(url) { return url }
  if let end = aboutAlias(url) {
    return Units(scheme + "://") + JS.lower(Array(url[6..<end])) + Array(url[end...])
  }
  return url
}

public func toAppUrl(_ url: String) -> String { toAppUrl(url.units).string }

public func toEngineUrl(_ url: String) -> String {
  let u = url.units
  guard let parts = split(u, schemes: appSchemes()), !parts.host.isEmpty else { return url }
  return ((parts.viewSource ? viewSourcePrefix : []) + Units("chrome://") + parts.host + parts.rest).string
}

private func isAppUrl(_ url: Units) -> Bool {
  for scheme in appSchemes() where url.asciiCaseInsensitivePrefix(scheme + "://") {
    let at = scheme.utf16.count + 3
    return at < url.count && url[at] != Unit.slash && url[at] != Unit.question && url[at] != Unit.hash
  }
  return false
}

private struct AppUrlParts {
  var host: Units
  var path: Units
}

private func appUrlParts(_ url: Units) -> AppUrlParts? {
  guard isAppUrl(url), let parts = split(url, schemes: appSchemes()) else { return nil }
  let pathEnd = parts.rest.firstIndex { $0 == Unit.question || $0 == Unit.hash } ?? parts.rest.count
  return AppUrlParts(host: parts.host, path: Array(parts.rest[..<pathEnd]))
}

func appUrlOrigin(_ url: Units) -> Units? {
  guard let parts = appUrlParts(toAppUrl(url)) else { return nil }
  return Units(AppScheme.value + "://") + parts.host
}

public func appUrlOrigin(_ url: String) -> String? { appUrlOrigin(url.units)?.string }

public func appUrlRoute(_ url: String) -> AppUrlRoute? {
  guard let parts = appUrlParts(url.units) else { return nil }
  let host = parts.host.string
  if let page = AppPageHost.allCases.first(where: { $0.rawValue.sameUnits(host) }) { return .page(page) }
  if host.sameUnits("newtab") { return .newTab }
  if host.sameUnits("settings") {
    let section = parts.path.split(separator: Unit.slash).first.map { String(units: $0) }
    return .settings(section: section)
  }
  return .engine(url: toEngineUrl(url))
}

public enum AppURLAction: Sendable, Equatable {
  case newTab
  case settings(pane: String?)

  private static let settingsPanes: [String: String] = [
    "general": "general", "profiles": "profiles", "people": "profiles", "manageprofile": "profiles",
    "sync": "sync", "syncsetup": "sync", "tabs": "tabs", "appearance": "appearance", "privacy": "privacy",
    "passwords": "passwords", "autofill": "autofill", "addresses": "autofill", "payments": "autofill",
    "extensions": "extensions", "search": "search", "searchengines": "search", "engines": "engines",
    "shortcuts": "shortcuts", "livefolders": "liveFolders", "calendar": "calendar", "advanced": "advanced",
  ]

  public init?(url: String) {
    switch appUrlRoute(toAppUrl(url)) {
    case .newTab?: self = .newTab
    case .settings(let section)?:
      if let section {
        guard let pane = Self.settingsPanes[section.lowercased()] else { return nil }
        self = .settings(pane: pane)
      } else {
        self = .settings(pane: nil)
      }
    default: return nil
    }
  }
}
