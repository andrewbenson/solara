import AppKit
import Foundation

public struct StripHostState: Decodable, Equatable, Sendable {
  public var profileId: String
  public var dark: Bool
  public var theme: [String: String]
  public var border: [String]
  public var glow: SidebarGlow
  public var floating: Bool
  public var pageWidth: Double
  public var playing: [String]
  public var sleeping: [String]
  public var engines: [String: String]
  public var capture: [String: TabCapture]
  public var bands: [String: String]
  public var closeHint: String?
  public var newTabMark: String?
  public var pages: [SidebarPageLook]?
  public var selection: [String]?
  public var iconRing: Bool?

  public init(profileId: String, dark: Bool = true) {
    self.profileId = profileId
    self.dark = dark
    theme = [:]
    border = []
    glow = SidebarGlow(color: "#FFFFFF26", opacity: 1, radius: 15)
    floating = false
    pageWidth = 0
    playing = []
    sleeping = []
    engines = [:]
    capture = [:]
    bands = [:]
  }

  public static func decode(_ json: String) -> StripHostState? {
    guard let data = json.data(using: .utf8) else { return nil }
    return try? JSONDecoder().decode(StripHostState.self, from: data)
  }

  public func page(_ look: SidebarPageLook) -> StripHostState {
    var out = self
    out.profileId = look.profileId
    out.dark = look.dark
    out.theme = look.theme
    out.border = look.border
    out.glow = look.glow
    out.pages = nil
    return out
  }

  var sidebarLook: SidebarHostState {
    var look = SidebarHostState(profileId: profileId, dark: dark)
    look.theme = theme
    look.border = border
    look.glow = glow
    look.sleeping = sleeping
    look.engines = engines
    look.capture = capture
    look.iconRing = iconRing ?? false
    return look
  }
}

@MainActor
public struct StripBandPalette: Equatable {
  public var background: NSColor
  public var text: NSColor
  public var secondary: NSColor
  public var icon: NSColor
  public var divider: NSColor

  public static func of(_ website: String?) -> StripBandPalette? {
    guard let website, website.hasPrefix("#"), website.count >= 7, let base = CSSColor(String(website.prefix(7))) else { return nil }
    func linear(_ v: Double) -> Double { v <= 0.03928 ? v / 12.92 : pow((v + 0.055) / 1.055, 2.4) }
    let l = 0.2126 * linear(base.red) + 0.7152 * linear(base.green) + 0.0722 * linear(base.blue)
    let light = 1.05 / (l + 0.05) < (l + 0.05) / 0.05
    func c(_ s: String) -> NSColor { SidebarPalette.parse(s)! }
    return light
      ? StripBandPalette(background: base.ns, text: c("#000000E6"), secondary: c("#00000080"), icon: c("#000000C6"), divider: c("rgba(0,0,0,0.05)"))
      : StripBandPalette(background: base.ns, text: c("#FFFFFF"), secondary: c("#FFFFFF99"), icon: c("#FFFFFFD9"), divider: c("rgba(255,255,255,0.025)"))
  }
}

@MainActor
struct StripPalette {
  let base: SidebarPalette
  let card: NSColor
  let windowTint: NSColor
  let dark: Bool
  let neutralSwatch: NSColor
  let groupDivider: NSColor
  let floatingCardBorder: NSColor
  let rimTop: NSColor

  init(_ host: StripHostState) {
    base = SidebarPalette(host.sidebarLook)
    dark = host.dark
    card = SidebarPalette.parse(host.theme["card"]) ?? (host.dark ? NSColor(white: 0.12, alpha: 1) : .white)
    windowTint = SidebarPalette.parse(host.theme["windowTint"]) ?? card
    neutralSwatch = SidebarPalette.parse(base.lightInk ? "#FFFFFF4D" : "#0000004D")!
    groupDivider = SidebarPalette.parse(base.lightInk ? "rgba(255,255,255,0.16)" : "rgba(0,0,0,0.12)")!
    floatingCardBorder = SidebarPalette.parse(host.dark ? "rgba(255,255,255,0.15)" : "rgba(0,0,0,0.08)")!
    rimTop = SidebarPalette.parse(host.dark ? "#FFFFFF3B" : "#FFFFFFFA")!
  }

  static func tint(_ color: String?) -> CSSColor? {
    guard let color, color != "none", let hex = SidebarPalette.groupColors[color] else { return nil }
    return CSSColor(hex)
  }
}
