import AppKit
import Foundation

public enum ExtensionSiteAccess: String, CaseIterable, Hashable, Sendable {
  case allSites
  case specificSites
  case onClick

  public init(engineValue: String) {
    switch engineValue {
    case "ON_CLICK": self = .onClick
    case "ON_SPECIFIC_SITES": self = .specificSites
    default: self = .allSites
    }
  }

  var title: String {
    switch self {
    case .allSites: "On all sites"
    case .specificSites: "On specific sites"
    case .onClick: "On click"
    }
  }
}

public struct InstalledExtension: Hashable, Sendable, Identifiable {
  public var id: String
  public var name: String
  public var version: String
  public var description: String
  public var enabled: Bool
  public var state: String
  public var icon: String
  public var permissions: [String]
  public var siteAccess: ExtensionSiteAccess?
  public var optionsUrl: String?
  public var pinned: Bool
  public var incognito: Bool
  public var mayModify: Bool
  public var errors: [String]
  public var path: String?
  public var fromWebStore: Bool
  public var webStoreUrl: String?

  public init(
    id: String,
    name: String,
    version: String,
    description: String = "",
    enabled: Bool = true,
    state: String? = nil,
    icon: String = "",
    permissions: [String] = [],
    siteAccess: ExtensionSiteAccess? = nil,
    optionsUrl: String? = nil,
    pinned: Bool = false,
    incognito: Bool = false,
    mayModify: Bool = true,
    errors: [String] = [],
    path: String? = nil,
    fromWebStore: Bool = true,
    webStoreUrl: String? = nil
  ) {
    self.id = id
    self.name = name
    self.version = version
    self.description = description
    self.enabled = enabled
    self.state = state ?? (enabled ? "ENABLED" : "DISABLED")
    self.icon = icon
    self.permissions = permissions
    self.siteAccess = siteAccess
    self.optionsUrl = optionsUrl
    self.pinned = pinned
    self.incognito = incognito
    self.mayModify = mayModify
    self.errors = errors
    self.path = path
    self.fromWebStore = fromWebStore
    self.webStoreUrl = webStoreUrl
  }
}

public struct ExtensionPackage: Hashable, Sendable {
  public var name: String
  public var version: String
  public var icon: String?
  public var permissions: [String]
  public var hostPermissions: [String]
  public var path: String

  public init(name: String, version: String, icon: String? = nil, permissions: [String] = [], hostPermissions: [String] = [], path: String) {
    self.name = name
    self.version = version
    self.icon = icon
    self.permissions = permissions
    self.hostPermissions = hostPermissions
    self.path = path
  }
}

public struct ExtensionConfiguration: Hashable, Sendable {
  public var pinned: Bool?
  public var incognito: Bool?
  public var siteAccess: ExtensionSiteAccess?

  public init(pinned: Bool? = nil, incognito: Bool? = nil, siteAccess: ExtensionSiteAccess? = nil) {
    self.pinned = pinned
    self.incognito = incognito
    self.siteAccess = siteAccess
  }
}

public struct ExtensionsChange: Hashable, Sendable {
  public enum Event: String, Sendable {
    case installed
    case uninstalled
    case enabled
    case disabled
    case configured
    case reloaded
  }

  public var profile: String
  public var id: String
  public var event: Event

  public init(profile: String, id: String, event: Event) {
    self.profile = profile
    self.id = id
    self.event = event
  }
}

public struct ExtensionServiceError: Error, Sendable {
  public let message: String

  public init(_ message: String) {
    self.message = message
  }

  static func message(_ error: Error) -> String {
    (error as? ExtensionServiceError)?.message ?? error.localizedDescription
  }
}

struct ExtensionInstallRequest: Identifiable, Equatable {
  enum Source: Equatable {
    case webStore
    case unpacked
  }

  enum Status: Equatable {
    case ready
    case installing
    case error(String)
  }

  let id = UUID()
  let profile: String
  let source: Source
  var status: Status
  var package: ExtensionPackage?

  var name: String { package?.name ?? "Extension" }
  var title: String { "Add “\(name)”?" }
  var warnings: [String] { package.map(ExtensionPermissions.warnings) ?? [] }
  var busy: Bool { status == .installing }
}

public enum ExtensionWebStore {
  static let categoryURL = "https://chromewebstore.google.com/category/extensions"
  static let invalidLinkMessage = "That isn't a link to an extension in the Chrome Web Store."

  static func isExtensionId(_ text: some StringProtocol) -> Bool {
    text.count == 32 && text.unicodeScalars.allSatisfy { ("a"..."p").contains($0) }
  }

  public static func extensionId(_ urlOrId: String) -> String? {
    let text = urlOrId.trimmingCharacters(in: .whitespacesAndNewlines)
    if isExtensionId(text) { return text }
    guard let url = URLComponents(string: text), let scheme = url.scheme, !scheme.isEmpty, let host = url.host?.lowercased() else { return nil }
    let store = host == "chromewebstore.google.com" || (host == "chrome.google.com" && url.path.hasPrefix("/webstore/"))
    guard store else { return nil }
    return url.path.split(separator: "/", omittingEmptySubsequences: false).first(where: { isExtensionId($0) }).map(String.init)
  }

  public static func detailURL(_ id: String) -> String { "https://chromewebstore.google.com/detail/\(id)" }
}

enum ExtensionPermissions {
  static let messages: [(String, String)] = [
    ("bookmarks", "Read and change your bookmarks"),
    ("clipboardRead", "Read data you copy and paste"),
    ("clipboardWrite", "Modify data you copy and paste"),
    ("contentSettings", "Change your settings that control websites' access to features such as cookies, JavaScript, plugins, geolocation, microphone, camera etc."),
    ("desktopCapture", "Capture content of your screen"),
    ("downloads", "Manage your downloads"),
    ("downloads.open", "Open downloaded files"),
    ("geolocation", "Detect your physical location"),
    ("management", "Manage your apps, extensions, and themes"),
    ("nativeMessaging", "Communicate with cooperating native applications"),
    ("notifications", "Display notifications"),
    ("privacy", "Change your privacy-related settings"),
    ("readingList", "Read and change entries in the reading list"),
    ("sessions", "Read your browsing history on all your signed-in devices"),
    ("system.storage", "Identify and eject storage devices"),
    ("tabCapture", "Capture content of your screen"),
    ("tabGroups", "View and manage your tab groups"),
    ("topSites", "Read a list of your most frequently visited websites"),
    ("ttsEngine", "Read all text spoken using synthesized speech"),
    ("webAuthenticationProxy", "Read and change all your data on all websites"),
  ]

  static func warnings(_ package: ExtensionPackage) -> [String] {
    var warnings: [String] = []
    let perms = Set(package.permissions)
    let hosts = package.hostPermissions.filter { $0.range(of: "^(chrome|chrome-extension|about|data):", options: .regularExpression) == nil }
    let allHosts = hosts.contains { $0 == "<all_urls>" || $0.range(of: "^(\\*|https?|wss?)://\\*/", options: .regularExpression) != nil } || perms.contains("debugger")
    if allHosts || perms.contains("proxy") || perms.contains("pageCapture") || perms.contains("debugger") {
      warnings.append("Read and change all your data on all websites")
    } else if !hosts.isEmpty {
      var names: [String] = []
      for label in hosts.compactMap(hostLabel) where !names.contains(label) { names.append(label) }
      switch names.count {
      case 1: warnings.append("Read and change your data on \(names[0])")
      case 2: warnings.append("Read and change your data on \(names[0]) and \(names[1])")
      case 3: warnings.append("Read and change your data on \(names[0]), \(names[1]), and \(names[2])")
      case 4...: warnings.append("Read and change your data on a number of websites")
      default: break
      }
    }
    let clipboard = perms.contains("clipboardRead") && perms.contains("clipboardWrite")
    if clipboard { warnings.append("Read and modify data you copy and paste") }
    for (permission, message) in messages {
      if clipboard && permission.hasPrefix("clipboard") { continue }
      if perms.contains(permission) { warnings.append(message) }
    }
    if perms.contains("declarativeNetRequest") && !allHosts && !perms.contains("declarativeNetRequestWithHostAccess") {
      warnings.append("Block content on any page")
    }
    let browsing = perms.contains("history") ? "Read and change your browsing history on all your signed-in devices" : nil
    if browsing == nil && (perms.contains("tabs") || perms.contains("webNavigation")) && !allHosts {
      warnings.append("Read your browsing history")
    }
    if let browsing { warnings.append(browsing) }
    var unique: [String] = []
    for warning in warnings where !unique.contains(warning) { unique.append(warning) }
    return unique
  }

  static func hostLabel(_ pattern: String) -> String? {
    guard let schemeEnd = pattern.range(of: "://"), !pattern[..<schemeEnd.lowerBound].isEmpty, !pattern[..<schemeEnd.lowerBound].contains(":") else { return nil }
    var rest = pattern[schemeEnd.upperBound...]
    let wildcard = rest.hasPrefix("*.")
    if wildcard { rest = rest.dropFirst(2) }
    let host = rest.prefix { $0 != "/" }
    guard !host.isEmpty else { return nil }
    return wildcard ? "all \(host) sites" : String(host)
  }
}

@MainActor
enum ExtensionIconCache {
  private static var images: [String: NSImage] = [:]

  static func image(_ uri: String) -> NSImage? {
    guard !uri.isEmpty else { return nil }
    if let cached = images[uri] { return cached }
    guard uri.hasPrefix("data:"), let comma = uri.firstIndex(of: ","), uri[..<comma].hasSuffix(";base64"),
      let data = Data(base64Encoded: String(uri[uri.index(after: comma)...])), let image = NSImage(data: data)
    else { return nil }
    images[uri] = image
    return image
  }
}
