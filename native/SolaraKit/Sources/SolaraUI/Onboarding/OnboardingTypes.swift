import AppKit
import Foundation
import SolaraModel

public enum OnboardingStep: String, CaseIterable, Sendable, Hashable {
  case intro, source, layout, tabs, look, searchPrivacy, pins, home, outro

  public static let order: [OnboardingStep] = allCases
  public static let cards: [OnboardingStep] = allCases.filter { $0 != .intro }

  func advanced(by delta: Int) -> OnboardingStep? {
    guard let index = Self.order.firstIndex(of: self) else { return nil }
    let target = index + delta
    return Self.order.indices.contains(target) ? Self.order[target] : nil
  }
}

public enum OnboardingPreset: String, Sendable, Hashable {
  case arc, dia

  public var settings: JSONObject {
    switch self {
    case .dia:
      [
        "addressBar": "toolbar",
        "commandBarPlacement": "field",
        "newTabOpens": "page",
        "newTabPosition": "top",
        "newTabButtonPosition": "top",
        "balancedTopApps": false,
        "shareTabsAcrossWindows": false,
        "cleanUpInactiveTabsAfterHours": nil,
        "openLinksInLittleSolara": true,
      ]
    case .arc:
      [
        "addressBar": "sidebar",
        "commandBarPlacement": "centred",
        "newTabOpens": "commandBar",
        "newTabPosition": "top",
        "newTabButtonPosition": "top",
        "balancedTopApps": true,
        "shareTabsAcrossWindows": true,
        "cleanUpInactiveTabsAfterHours": 12,
        "openLinksInLittleSolara": true,
      ]
    }
  }

  public static func forSource(_ source: BrowserSourceId?) -> OnboardingPreset {
    source == .arc || source == .zen ? .arc : .dia
  }
}

public enum BrowserSourceId: String, CaseIterable, Sendable, Hashable {
  case arc, dia, chrome, safari, firefox, zen, brave, edge, fresh
}

public enum OnboardingQuestion: String, CaseIterable, Sendable, Hashable {
  case source, tabs, address, cmdl, newTab, newTabPosition, tidy, quit, windows, tabsMore
  case color, appearance, siteColor, lookMore, engine, typed, pins
  case defaultBrowser = "default"
  case links, outro

  public var keys: [String] {
    switch self {
    case .tabs: ["tabLayout"]
    case .address: ["addressBar"]
    case .cmdl: ["commandBarPlacement"]
    case .newTab: ["newTabOpens"]
    case .newTabPosition: ["newTabPosition", "newTabButtonPosition"]
    case .tidy: ["cleanUpInactiveTabsAfterHours"]
    case .quit: ["restoreSession"]
    case .windows: ["shareTabsAcrossWindows"]
    case .tabsMore: ["balancedTopApps", "peekModifier", "undoReopensClosedTab", "cmdClickCreatesTabGroup"]
    case .appearance: ["appearance"]
    case .siteColor: ["extendWebsiteColor"]
    case .lookMore: ["hideToolbarWhileScrolling", "bookmarksBar"]
    case .engine: ["searchEngine"]
    case .typed: ["commandBarPreference"]
    case .links: ["openLinksInLittleSolara"]
    case .source, .color, .pins, .defaultBrowser, .outro: []
    }
  }

  public static func all(in step: OnboardingStep) -> [OnboardingQuestion] {
    switch step {
    case .intro: []
    case .source: [.source]
    case .layout: [.tabs, .address, .cmdl]
    case .tabs: [.newTab, .newTabPosition, .tidy, .quit, .windows, .tabsMore]
    case .look: [.color, .appearance, .siteColor, .lookMore]
    case .searchPrivacy: [.engine, .typed]
    case .pins: [.pins]
    case .home: [.defaultBrowser, .links]
    case .outro: [.outro]
    }
  }

  public static let order: [OnboardingQuestion] = OnboardingStep.cards.flatMap { all(in: $0) }
}

public struct OnboardingExtras: Equatable, Sendable {
  public var appIcon: String?
  public var pins: [String]?
  public var setDefault: Bool?
  public var trial: Bool?
  public var dock: Bool?
  public var login: Bool?

  public init() {}
}

public struct OnboardingSystemState: Equatable, Sendable {
  public var isDefault: Bool
  public var inDock: Bool
  public var loginEnabled: Bool

  public init(isDefault: Bool, inDock: Bool, loginEnabled: Bool) {
    self.isDefault = isDefault
    self.inDock = inDock
    self.loginEnabled = loginEnabled
  }
}

public struct OnboardingAppIcon: Identifiable, Sendable, Equatable {
  public let id: String
  public let name: String
  public let preview: NSImage?

  public init(id: String, name: String, preview: NSImage?) {
    self.id = id
    self.name = name
    self.preview = preview
  }
}

public struct OnboardingHistoryVisit: Sendable, Equatable {
  public let url: String
  public let visits: Int

  public init(url: String, visits: Int) {
    self.url = url
    self.visits = visits
  }
}

public struct PinnableSite: Identifiable, Sendable, Equatable {
  public let id: String
  public let title: String
  public let url: String

  public static let all: [PinnableSite] = [
    PinnableSite(id: "gmail", title: "Gmail", url: "https://mail.google.com/"),
    PinnableSite(id: "calendar", title: "Calendar", url: "https://calendar.google.com/"),
    PinnableSite(id: "slack", title: "Slack", url: "https://app.slack.com/"),
    PinnableSite(id: "notion", title: "Notion", url: "https://www.notion.so/"),
    PinnableSite(id: "figma", title: "Figma", url: "https://www.figma.com/"),
    PinnableSite(id: "github", title: "GitHub", url: "https://github.com/"),
    PinnableSite(id: "linear", title: "Linear", url: "https://linear.app/"),
    PinnableSite(id: "docs", title: "Docs", url: "https://docs.google.com/"),
    PinnableSite(id: "drive", title: "Drive", url: "https://drive.google.com/"),
    PinnableSite(id: "outlook", title: "Outlook", url: "https://outlook.office.com/mail/"),
    PinnableSite(id: "youtube", title: "YouTube", url: "https://www.youtube.com/"),
    PinnableSite(id: "spotify", title: "Spotify", url: "https://open.spotify.com/"),
  ]

  public static func host(_ url: String) -> String {
    guard let host = URL(string: url)?.host(percentEncoded: false)?.lowercased() else { return "" }
    return host.hasPrefix("www.") ? String(host.dropFirst(4)) : host
  }

  public static func preselected(history: [OnboardingHistoryVisit], alreadyPinned: Set<String> = []) -> [String] {
    var visits: [String: Int] = [:]
    for entry in history {
      let host = host(entry.url)
      if !host.isEmpty { visits[host, default: 0] += entry.visits }
    }
    let ranked = all.filter { !alreadyPinned.contains(host($0.url)) }
      .map { (id: $0.id, visits: visits[host($0.url)] ?? 0) }
      .filter { $0.visits >= 3 }
    let sorted = ranked.enumerated().sorted { a, b in a.element.visits != b.element.visits ? a.element.visits > b.element.visits : a.offset < b.offset }
    return sorted.prefix(4).map(\.element.id)
  }
}

public struct BrowserSourceCandidate: Sendable, Equatable {
  public let id: BrowserSourceId
  public let name: String
  public let app: String
  public let importId: String?

  init(_ id: BrowserSourceId, _ name: String, _ app: String, importId: String? = nil) {
    self.id = id
    self.name = name
    self.app = app
    self.importId = importId
  }

  public static let groups: [[BrowserSourceCandidate]] = [
    [BrowserSourceCandidate(.arc, "Arc", "/Applications/Arc.app")],
    [BrowserSourceCandidate(.dia, "Dia", "/Applications/Dia.app")],
    [BrowserSourceCandidate(.chrome, "Chrome", "/Applications/Google Chrome.app")],
    [
      BrowserSourceCandidate(.safari, "Safari", "/System/Volumes/Preboot/Cryptexes/App/System/Applications/Safari.app"),
      BrowserSourceCandidate(.safari, "Safari", "/Applications/Safari.app"),
    ],
    [BrowserSourceCandidate(.firefox, "Firefox", "/Applications/Firefox.app")],
    [
      BrowserSourceCandidate(.zen, "Zen", "/Applications/Zen.app"),
      BrowserSourceCandidate(.zen, "Zen", "/Applications/Zen Browser.app"),
      BrowserSourceCandidate(.zen, "Zen Twilight", "/Applications/Zen Twilight.app"),
    ],
    [
      BrowserSourceCandidate(.brave, "Brave", "/Applications/Brave Browser.app"),
      BrowserSourceCandidate(.brave, "Brave Beta", "/Applications/Brave Browser Beta.app", importId: "braveBeta"),
      BrowserSourceCandidate(.brave, "Brave Nightly", "/Applications/Brave Browser Nightly.app", importId: "braveNightly"),
      BrowserSourceCandidate(.edge, "Edge", "/Applications/Microsoft Edge.app"),
      BrowserSourceCandidate(.edge, "Edge Beta", "/Applications/Microsoft Edge Beta.app", importId: "edgeBeta"),
    ],
  ]
}

public struct BrowserSourceTile: Sendable, Equatable, Identifiable {
  public let id: BrowserSourceId
  public let name: String
  public let app: String?
  public var icon: NSImage?
  public let importId: String?

  public static func detect(fileExists: (String) -> Bool) -> [BrowserSourceTile] {
    BrowserSourceCandidate.groups.map { group in
      if let found = group.first(where: { fileExists($0.app) }) {
        return BrowserSourceTile(id: found.id, name: found.name, app: found.app, icon: nil, importId: found.importId)
      }
      var names: [String] = []
      for candidate in group where candidate.importId == nil && !names.contains(candidate.name) { names.append(candidate.name) }
      return BrowserSourceTile(id: group[0].id, name: names.joined(separator: " or "), app: nil, icon: nil, importId: nil)
    }
  }

  public static func == (a: BrowserSourceTile, b: BrowserSourceTile) -> Bool {
    a.id == b.id && a.name == b.name && a.app == b.app && a.importId == b.importId && (a.icon == nil) == (b.icon == nil)
  }
}

public struct IntroMusicCues: Sendable, Equatable {
  public static let letterDuration = 0.52
  public static let taglineDuration = 0.6
  public static let exitDuration = 0.65

  public let icon: Double
  public let letters: Double
  public let letterStep: Double
  public let letterCount: Int
  public let tagline: Double
  public let exit: Double
  public let end: Double

  public init(letterCount: Int) {
    icon = 0.25
    letters = 1.15
    letterStep = 0.055
    self.letterCount = letterCount
    tagline = letters + Double(letterCount - 1) * letterStep + Self.letterDuration + 0.15
    exit = tagline + Self.taglineDuration + 1.1
    end = exit + Self.exitDuration
  }
}

public struct PowerUpSpec: Sendable, Equatable {
  public static let diaSpectrum = ["#0358F7", "#5092C7", "#E1E1FE", "#FFD400", "#FA3D1D", "#FD02F5"]

  public var palette: [String]
  public var speed: Double
  public var origin: Double
  public var cornerRadius: Double
  public var halo: CGRect?

  public init(palette: [String] = ["pink"], speed: Double = 1, origin: Double = 0.5, cornerRadius: Double = 0, halo: CGRect? = nil) {
    self.palette = palette
    self.speed = speed
    self.origin = origin
    self.cornerRadius = cornerRadius
    self.halo = halo
  }
}

public struct OnboardingCopy: Sendable {
  public let product: String

  public init(product: String) {
    self.product = product
  }

  public var wordmark: String { product }
  public var systemTitle: String { "Make \(product) your default?" }
  public var setDefault: String { "Set \(product) as default browser" }
  public var alreadyDefault: String { "\(product) is already your default browser" }
  public var openByDefault: String { "Open links and web pages in \(product)" }
  public var isDefault: String { "\(product) is your default browser" }
  public var dock: String { "Add \(product) to Dock" }
  public var login: String { "Open \(product) at login" }
  public var littleWindow: String { "Little \(product)" }
  public var linksInLittleWindow: String { "Links from other apps open in Little \(product)" }
  public var sourceSubtitle: String { "\(product) sets itself up the way you're used to. Change anything later." }
  public var launchSubtitle: String { "What \(product) opens to." }
  public var startsFresh: String { "\(product) starts fresh each launch" }
  public var pinnedSubtitle: String { "Pin the apps you use most. They stay put when you open \(product)." }

}
