import Foundation

public enum ImportKind: String, CaseIterable, Sendable, Hashable {
  case bookmarks
  case history
  case passwords
  case cookies
  case autofill
  case tabs
  case spaces
  case pinnedTabs
  case favorites

  public var title: String {
    switch self {
    case .bookmarks: "Bookmarks"
    case .history: "History"
    case .passwords: "Passwords"
    case .cookies: "Cookies (stay signed in)"
    case .autofill: "Addresses and cards"
    case .tabs: "Tabs"
    case .spaces: "Spaces"
    case .pinnedTabs: "Pinned tabs"
    case .favorites: "Favorites"
    }
  }

  public var symbol: String {
    switch self {
    case .bookmarks: "bookmark"
    case .history: "clock"
    case .passwords: "key"
    case .cookies: "person.badge.key"
    case .autofill: "creditcard"
    case .tabs: "square.on.square"
    case .spaces: "square.stack"
    case .pinnedTabs: "pin"
    case .favorites: "star"
    }
  }

  static let encrypted: [ImportKind] = [.passwords, .cookies, .autofill]
}

public enum ImportBrowserFamily: String, Sendable {
  case chromium
  case firefox
  case safari
  case arc
  case automation
}

public enum ImportSidebar: String, Sendable {
  case arc
  case zen
}

public struct ImportSpace: Sendable, Equatable, Identifiable {
  public let id: String
  public let name: String
  public let color: String?
  public let emoji: String?
  public let pinnedCount: Int
  public let tabCount: Int

  public init(id: String, name: String, color: String? = nil, emoji: String? = nil, pinnedCount: Int, tabCount: Int) {
    self.id = id
    self.name = name
    self.color = color
    self.emoji = emoji
    self.pinnedCount = pinnedCount
    self.tabCount = tabCount
  }
}

public struct ImportSourceProfile: Sendable, Equatable, Identifiable {
  public let id: String
  public let name: String
  public let email: String?
  public let avatarPath: String?
  public let color: String?
  public let isDefault: Bool
  public let available: [ImportKind]
  public let spaces: [ImportSpace]
  public let tabsNeedKey: Bool

  public init(
    id: String,
    name: String,
    email: String? = nil,
    avatarPath: String? = nil,
    color: String? = nil,
    isDefault: Bool,
    available: [ImportKind],
    spaces: [ImportSpace] = [],
    tabsNeedKey: Bool = false
  ) {
    self.id = id
    self.name = name
    self.email = email
    self.avatarPath = avatarPath
    self.color = color
    self.isDefault = isDefault
    self.available = available
    self.spaces = spaces
    self.tabsNeedKey = tabsNeedKey
  }
}

public struct ImportBrowser: Sendable, Equatable, Identifiable {
  public let id: String
  public let name: String
  public let family: ImportBrowserFamily
  public let iconPath: String?
  public let requiresExport: Bool
  public let needsKeychain: Bool
  public let needsFullDiskAccess: Bool
  public let keychainService: String?
  public var profiles: [ImportSourceProfile]
  public let sidebar: ImportSidebar?

  public init(
    id: String,
    name: String,
    family: ImportBrowserFamily,
    iconPath: String? = nil,
    requiresExport: Bool = false,
    needsKeychain: Bool = false,
    needsFullDiskAccess: Bool = false,
    keychainService: String? = nil,
    profiles: [ImportSourceProfile],
    sidebar: ImportSidebar? = nil
  ) {
    self.id = id
    self.name = name
    self.family = family
    self.iconPath = iconPath
    self.requiresExport = requiresExport
    self.needsKeychain = needsKeychain
    self.needsFullDiskAccess = needsFullDiskAccess
    self.keychainService = keychainService
    self.profiles = profiles
    self.sidebar = sidebar
  }
}

public struct ImportTarget: Sendable, Equatable, Identifiable {
  public let id: String
  public let name: String

  public init(id: String, name: String) {
    self.id = id
    self.name = name
  }
}

public struct ImportOpening: Sendable, Equatable {
  public let available: Bool
  public let preferredSource: String?
  public let targets: [ImportTarget]
  public let defaultTarget: String

  public init(available: Bool, preferredSource: String?, targets: [ImportTarget], defaultTarget: String) {
    self.available = available
    self.preferredSource = preferredSource
    self.targets = targets
    self.defaultTarget = defaultTarget
  }
}

public struct ImportCounts: Sendable, Equatable {
  public var bookmarks = 0
  public var history = 0
  public var tabs = 0
  public var passwords = 0
  public var cookies = 0
  public var addresses = 0
  public var cards = 0

  public init(bookmarks: Int = 0, history: Int = 0, tabs: Int = 0, passwords: Int = 0, cookies: Int = 0, addresses: Int = 0, cards: Int = 0) {
    self.bookmarks = bookmarks
    self.history = history
    self.tabs = tabs
    self.passwords = passwords
    self.cookies = cookies
    self.addresses = addresses
    self.cards = cards
  }
}

public enum ImportStatus: String, Sendable {
  case pending
  case active
  case done
  case failed
}

public struct ImportFailure: Sendable, Equatable {
  public let kind: ImportKind
  public let profiles: [String]

  public init(kind: ImportKind, profiles: [String] = []) {
    self.kind = kind
    self.profiles = profiles
  }
}

public struct ImportedExtension: Sendable, Equatable, Identifiable {
  public let id: String
  public let name: String
  public let webStoreUrl: String

  public init(id: String, name: String, webStoreUrl: String) {
    self.id = id
    self.name = name
    self.webStoreUrl = webStoreUrl
  }
}

public struct ImportRunRequest: Sendable, Equatable {
  public let runId: String
  public let browserId: String
  public let profileIds: [String]
  public let spaceIds: [String]
  public let kinds: [ImportKind]
  public let target: String
  public let withoutKey: Bool
}

public struct ImportProgressUpdate: Sendable, Equatable {
  public let runId: String
  public let preparing: Int
  public let status: [ImportKind: ImportStatus]

  public init(runId: String, preparing: Int, status: [ImportKind: ImportStatus]) {
    self.runId = runId
    self.preparing = preparing
    self.status = status
  }
}

public struct ImportRunOutcome: Sendable, Equatable {
  public let cancelled: Bool
  public let status: [ImportKind: ImportStatus]
  public let failures: [ImportFailure]
  public let counts: ImportCounts
  public let notes: [String]
  public let extensionsProfile: String
  public let extensions: [ImportedExtension]

  public init(
    cancelled: Bool = false,
    status: [ImportKind: ImportStatus] = [:],
    failures: [ImportFailure] = [],
    counts: ImportCounts = ImportCounts(),
    notes: [String] = [],
    extensionsProfile: String = "",
    extensions: [ImportedExtension] = []
  ) {
    self.cancelled = cancelled
    self.status = status
    self.failures = failures
    self.counts = counts
    self.notes = notes
    self.extensionsProfile = extensionsProfile
    self.extensions = extensions
  }

  public static let cancelledRun = ImportRunOutcome(cancelled: true)
}

public enum ImportFileOutcome: Sendable, Equatable {
  case imported(ImportCounts, failed: [ImportKind])
  case cancelled
  case failed(code: String)
}

public enum DiaStatus: String, Sendable {
  case granted
  case denied
  case notDetermined
  case notRunning
  case notInstalled
  case checking
  case reading
}

public struct DiaProfileSummary: Sendable, Equatable, Identifiable {
  public let id: String
  public let name: String
  public let pinnedCount: Int
  public let tabCount: Int

  public init(id: String, name: String, pinnedCount: Int, tabCount: Int) {
    self.id = id
    self.name = name
    self.pinnedCount = pinnedCount
    self.tabCount = tabCount
  }
}

public enum DiaRead: Sendable, Equatable {
  case read(profiles: [DiaProfileSummary], windowCount: Int)
  case failed(code: String, message: String)
}

public enum ImportFileKind: String, Sendable {
  case safariExport
  case bookmarksHTML
}

@MainActor
public protocol ImportServices: AnyObject {
  func open() async -> ImportOpening
  func listBrowsers() async -> [ImportBrowser]?
  func targetUpdates() -> AsyncStream<[ImportTarget]>
  func progressUpdates() -> AsyncStream<ImportProgressUpdate>
  func safariHasFullDiskAccess() async -> Bool
  func isBrowserUnlocked(_ browserId: String) async -> Bool
  func unlockBrowser(_ browserId: String) async -> Bool
  func run(_ request: ImportRunRequest) async -> ImportRunOutcome
  func cancel()
  func dispose()
  func diaAutomationStatus() async -> DiaStatus
  func requestDiaAutomation() async -> DiaStatus
  func openDia() async -> Bool
  func readDiaTabs() async -> DiaRead
  func runDia(profileIds: [String], target: String, pinned: Bool, open: Bool) async -> ImportRunOutcome
  func importSafariExport(path: String, target: String) async -> ImportFileOutcome
  func importSafariDirect(target: String, cookies: Bool) async -> ImportFileOutcome
  func importBookmarksHTML(target: String) async -> ImportFileOutcome
  func chooseImportFile(_ kind: ImportFileKind) async -> String?
  func openFullDiskAccessSettings()
  func openAutomationSettings()
  func openInWebStore(profileId: String, urls: [String])
  func arcHolderCount() async -> Int
  func restoreArcFolders() async -> Int
  func isOnboarding() async -> Bool
  func close()
}

func importPlural(_ n: Int, _ word: String) -> String {
  "\(n) \(word)\(n == 1 ? "" : "s")"
}
