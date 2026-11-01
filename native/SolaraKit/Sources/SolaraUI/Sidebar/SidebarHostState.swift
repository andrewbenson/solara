import AppKit
import Foundation

public struct SidebarGlow: Decodable, Equatable, Sendable {
  public var color: String
  public var opacity: Double
  public var radius: Double
}

public struct SidebarPageLook: Decodable, Equatable, Sendable {
  public var profileId: String
  public var dark: Bool
  public var theme: [String: String]
  public var border: [String]
  public var glow: SidebarGlow
  public var tidy: Bool
  public var incognito: Bool
}

public struct SidebarHostState: Decodable, Equatable, Sendable {
  public var profileId: String
  public var dark: Bool
  public var theme: [String: String]
  public var border: [String]
  public var glow: SidebarGlow
  public var selection: [String]
  public var loading: [String]
  public var playing: [String]
  public var sleeping: [String]
  public var closeHint: String?
  public var backHint: String?
  public var renaming: String?
  public var addressBar: Bool
  public var tidy: Bool
  public var clear: Bool
  public var iconRing: Bool
  public var newTabAtTop: Bool
  public var incognito: Bool
  public var cleaned: Int
  public var engines: [String: String]
  public var newTabMark: String?
  public var developer: [String]
  public var pages: [SidebarPageLook]?
  public var player: MediaPlayerState?
  public var pip: [String]?
  public var capture: [String: TabCapture]?
  public var badge: [String]?
  public var upsell: Int?
  public var product: String?

  public init(profileId: String, dark: Bool = true) {
    self.profileId = profileId
    self.dark = dark
    theme = [:]
    border = []
    glow = SidebarGlow(color: "#FFFFFF26", opacity: 1, radius: 15)
    selection = []
    loading = []
    playing = []
    sleeping = []
    addressBar = false
    tidy = false
    clear = false
    iconRing = false
    newTabAtTop = false
    incognito = false
    cleaned = 0
    engines = [:]
    developer = []
  }

  public func page(_ look: SidebarPageLook) -> SidebarHostState {
    var out = self
    out.profileId = look.profileId
    out.dark = look.dark
    out.theme = look.theme
    out.border = look.border
    out.glow = look.glow
    out.tidy = look.tidy
    out.incognito = look.incognito
    out.pages = nil
    if look.profileId != profileId {
      out.player = nil
      out.upsell = nil
    }
    return out
  }

  public static func decode(_ json: String) -> SidebarHostState? {
    guard let data = json.data(using: .utf8) else { return nil }
    return try? JSONDecoder().decode(SidebarHostState.self, from: data)
  }
}

public struct SidebarFlags: Equatable, Sendable {
  public var selection: Set<String> = []
  public var loading: Set<String> = []
  public var playing: Set<String> = []
  public var sleeping: Set<String> = []
  public var developer: Set<String> = []
  public var pip: Set<String> = []
  public var capture: [String: TabCapture] = [:]

  public init() {}

  init(_ state: SidebarHostState) {
    selection = Set(state.selection)
    loading = Set(state.loading)
    playing = Set(state.playing)
    sleeping = Set(state.sleeping)
    developer = Set(state.developer)
    pip = Set(state.pip ?? [])
    capture = state.capture ?? [:]
  }
}

@MainActor
public struct SidebarPalette {
  public let dark: Bool
  let tokens: [String: String]
  public let textTab: NSColor
  public let selectedText: NSColor
  public let hover: NSColor
  public let pressed: NSColor
  public let selected: NSColor
  public let selectedBorder: [NSColor]
  public let glowColor: NSColor
  public let glowOpacity: Double
  public let glowRadius: Double
  public let rowHover: NSColor
  public let divider: NSColor
  public let textPrimary: NSColor
  public let textSecondary: NSColor
  public let textTertiary: NSColor
  public let icon: NSColor
  public let pinnedResting: NSColor
  public let pinnedRestingStroke: NSColor
  public let pinnedSelectedFill: NSColor
  public let pinnedSelectedRim: NSColor
  public let pinnedSelectedOutline: NSColor
  public let accent: NSColor
  public let toolbarHover: NSColor
  public let toolbarPressed: NSColor
  public let backdropTint: CSSColor?

  public let groupFill: NSColor
  public let groupHeaderHover: NSColor
  public let groupStroke: NSColor
  public let groupTitle: NSColor
  public let multiSelected: NSColor
  public let multiSelectedStroke: NSColor
  public let dragBorder: NSColor
  public let scrollEdge: NSColor
  public let newTabLabel: NSColor
  public let newTabIcon: NSColor
  public let noGroupIcon: NSColor

  public init(_ state: SidebarHostState) {
    dark = state.dark
    tokens = state.theme
    func color(_ key: String, _ fallback: String) -> NSColor { Self.parse(state.theme[key]) ?? Self.parse(fallback)! }
    let d = state.dark
    textTab = color("textTab", d ? "#FFFFFFC7" : "#000000AD")
    selectedText = color("tabSelectedText", d ? "#FFFFFF" : "#000000")
    hover = color("tabHover", d ? "rgba(255,255,255,0.16)" : "rgba(255,255,255,0.55)")
    pressed = color("tabPressed", d ? "rgba(255,255,255,0.31)" : "rgba(255,255,255,0.7)")
    selected = color("tabSelected", d ? "rgba(18,18,18,0.5)" : "rgba(255,255,255,0.7)")
    let border = state.border.compactMap(Self.parse)
    selectedBorder = border.count >= 2 ? border : [Self.parse(d ? "rgba(255,255,255,0.15)" : "rgba(255,255,255,0.98)")!, Self.parse(d ? "rgba(255,255,255,0.15)" : "rgba(0,0,0,0.06)")!]
    glowColor = Self.parse(state.glow.color) ?? .white
    glowOpacity = state.glow.opacity
    glowRadius = state.glow.radius
    rowHover = color("rowHover", d ? "rgba(255,255,255,0.07)" : "rgba(15,24,44,0.05)")
    divider = color("divider", d ? "rgba(255,255,255,0.08)" : "rgba(0,0,0,0.08)")
    textPrimary = color("textPrimary", d ? "#FFFFFF" : "#000000")
    textSecondary = color("textSecondary", d ? "#FFFFFF80" : "#00000080")
    textTertiary = color("textTertiary", d ? "#FFFFFF59" : "#00000059")
    icon = color("icon", d ? "#F7F5FFC6" : "#000000C6")
    pinnedResting = color("pinnedResting", d ? "rgba(255,255,255,0.1)" : "rgba(0,0,0,0.05)")
    pinnedRestingStroke = color("pinnedRestingStroke", d ? "rgba(255,255,255,0.14)" : "rgba(0,0,0,0.18)")
    pinnedSelectedFill = color("pinnedSelectedFill", d ? "rgba(255,255,255,0.25)" : "rgba(255,255,255,0.7)")
    pinnedSelectedRim = color("pinnedSelectedRim", d ? "rgba(0,0,0,0.85)" : "rgba(0,0,0,0.12)")
    pinnedSelectedOutline = color("pinnedSelectedOutline", d ? "rgba(255,255,255,0.2)" : "rgba(255,255,255,0.98)")
    accent = color("accent", d ? "#4A77D4" : "#6395FC")
    toolbarHover = color("toolbarHover", d ? "rgba(255,255,255,0.1)" : "rgba(0,0,0,0.06)")
    toolbarPressed = color("toolbarPressed", d ? "rgba(255,255,255,0.18)" : "rgba(0,0,0,0.1)")
    backdropTint = state.theme["backdropTint"].flatMap { CSSColor($0) }

    groupFill = Self.parse(d ? "rgba(255,255,255,0.1)" : "rgba(0,0,0,0.05)")!
    groupHeaderHover = Self.parse(d ? "rgba(255,255,255,0.12)" : "rgba(255,255,255,0.4)")!
    groupStroke = Self.parse(d ? "rgba(255,255,255,0.1)" : "rgba(0,0,0,0.1)")!
    groupTitle = Self.parse(d ? "#FFFFFF" : "#000000D9")!
    multiSelected = Self.parse(d ? "rgba(255,255,255,0.1)" : "rgba(0,0,0,0.1)")!
    multiSelectedStroke = Self.parse(d ? "rgba(255,255,255,0.14)" : "rgba(0,0,0,0.08)")!
    dragBorder = Self.parse(d ? "rgba(255,255,255,0.33)" : "rgba(0,0,0,0.28)")!
    scrollEdge = Self.parse(d ? "rgba(255,255,255,0.09)" : "rgba(0,0,0,0.09)")!
    newTabLabel = Self.parse(d ? "#FFFFFF8C" : "#00000080")!
    newTabIcon = Self.parse(d ? "#FFFFFF40" : "#00000042")!
    noGroupIcon = Self.parse(d ? "#FFFFFF40" : "#00000040")!
  }

  static func parse(_ text: String?) -> NSColor? {
    guard let text else { return nil }
    if text == "transparent" { return .clear }
    return CSSColor(text)?.ns
  }

  public static let groupColors: [String: String] = [
    "grey": "#8E8E93", "blue": "#4C8DF6", "red": "#E5534B", "yellow": "#E3B341", "green": "#3FB06C", "pink": "#DB61A2",
    "purple": "#9B6CF0", "cyan": "#35B8C6", "orange": "#EE8434",
  ]

  public func groupSurface(_ color: String?) -> (fill: NSColor, stroke: NSColor) {
    if color == "none" { return (.clear, .clear) }
    guard let color, let hex = Self.groupColors[color], let tint = CSSColor(hex) else { return (groupFill, groupStroke) }
    return (tint.withAlpha(0.16).ns, tint.withAlpha(0.3).ns)
  }

  public func glassTint(_ fill: NSColor, raised: Bool) -> NSColor {
    guard let c = fill.usingColorSpace(.sRGB) else { return fill }
    let r = c.redComponent * 255, g = c.greenComponent * 255, b = c.blueComponent * 255, a = c.alphaComponent
    let profile = backdropTint ?? CSSColor(red: 0, green: 0, blue: 0, alpha: 1)
    let lightening = r + g + b > 3 * 127
    let alpha = a * (!lightening ? 1 : dark ? (raised ? 0.9 : 0.6) : raised ? 0.8 : 0.55)
    func mix(_ v: Double, _ p: Double) -> Double { v + (p * 255 - v) * 0.15 }
    func byte(_ v: Double) -> Double { (min(255, max(0, v))).rounded() / 255 }
    return NSColor(srgbRed: byte(mix(r, profile.red)), green: byte(mix(g, profile.green)), blue: byte(mix(b, profile.blue)), alpha: byte(alpha * 255))
  }
}
