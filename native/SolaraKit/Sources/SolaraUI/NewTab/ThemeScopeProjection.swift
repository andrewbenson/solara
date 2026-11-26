import SolaraModel
import SolaraStore

public struct ThemeScopeProjection: Encodable, Equatable, Sendable {
  public struct Backdrop: Encodable, Equatable, Sendable {
    public let tintColor: String
    public var tintAlpha = 0.36
    public var tintLightness = 0.25
    public var themeColors: [Double] = []
    public var themeOpacity = 1.0
    public var themeBaseAlpha = 0.0
    public var themeGrain = 0.0
    public var themeTexture: ThemeTextureValue = .grain
    public var themeAppearance: ThemeModeValue = .auto
    public var themeAngle = ThemeMath.defaultAngle
  }

  public let dark: Bool
  public let profileColor: String
  public let backdrop: Backdrop
  public let windowTint: [String]
  public let powerUpColor: String
  public let powerUpPalette: [String]
  public let custom: ProfileThemeValue?
  public let sidebarInk: [String: String]?
  public let stripInk: [String: String]?
  public let adjustInk: Bool

  private static let swatches = [
    ("plum", "#C07A98"), ("blue", "#4691C3"), ("purple", "#7873AF"), ("pink", "#D37B8B"), ("red", "#C1575C"),
    ("orange", "#D87249"), ("yellow", "#E3AC38"), ("green", "#3EB489"), ("neutral", "#8E8E93"),
  ]

  private static let presets = Dictionary(uniqueKeysWithValues: swatches)
  private static let presetHues = swatches.dropLast().map { ($0.0, hsl($0.1).0) }

  public static func project(_ state: BrowserState, windowId: String? = nil, pageProfileId: String? = nil) -> Self {
    let window = (windowId ?? state.ui.focusedWindowId).flatMap { state.windows[$0] }
    let adjustInk = !state.settings.bool("lightColorsKeepWhiteText")
    if window?.incognito == true { return preset("incognito", dark: true, adjustInk: adjustInk) }
    let profile = state.profiles[pageProfileId ?? window?.profileId ?? state.settings.defaultProfileId]
    let color = profile?.color ?? "plum"
    let appDark = state.ui.appDark
    guard let custom = profile?.theme.flatMap(parseTheme) else { return preset(color, dark: appDark, adjustInk: adjustInk) }

    let source: ThemeLookSource = windowId == nil ? .utility : state.settings.bool("spacesFollowAppearance") ? .app : .own
    let shown = ThemeMath.shown(custom, appDark: appDark, source: source)
    let look = shown.look
    let accent = ThemeMath.accent(look)
    let appearance: ThemeModeValue = shown.dark != shown.requestedDark ? (shown.dark ? .dark : .light) : (source == .own ? custom.mode : .auto)
    let backdrop = Backdrop(tintColor: accent, themeColors: ThemeMath.flatColors(look), themeOpacity: ThemeMath.layerAlpha(look),
      themeBaseAlpha: ThemeMath.underlayAlpha(look, dark: shown.dark), themeGrain: ThemeMath.grainAlpha(look),
      themeTexture: look.texture, themeAppearance: appearance, themeAngle: ThemeMath.lookAngle(look))
    let windowTint = [0.0, 1.0].map { corner in ThemeMath.hex(ThemeMath.composite(look, dark: shown.dark, corner, corner)) }
    return Self(dark: shown.dark, profileColor: nearestPreset(accent), backdrop: backdrop, windowTint: windowTint,
      powerUpColor: accent, powerUpPalette: look.stops.map { ThemeMath.colorHex($0.color) }, custom: custom,
      sidebarInk: ink(look, dark: shown.dark, strip: false), stripInk: ink(look, dark: shown.dark, strip: true), adjustInk: adjustInk)
  }

  public static func mayChange(_ changes: ChangeSet) -> Bool {
    let settings = ["defaultProfileId", "spacesFollowAppearance", "lightColorsKeepWhiteText"]
    return !changes.profiles.isEmpty || !changes.windows.isEmpty || changes.lists.contains("ui")
      || changes.settingsChanged.contains(where: settings.contains) || changes.settingsRemoved.contains(where: settings.contains)
  }

  private static func hsl(_ color: String) -> (Double, Double, Double) {
    let rgb = ThemeMath.hexColor(color)
    return ThemeMath.rgbToHsl(rgb.r, rgb.g, rgb.b)
  }

  private static func nearestPreset(_ accent: String) -> String {
    let (hue, saturation, _) = hsl(accent)
    if saturation < 0.12 { return "neutral" }
    func distance(_ other: Double) -> Double { min(abs(other - hue), 1 - abs(other - hue)) }
    return presetHues.min { distance($0.1) < distance($1.1) }?.0 ?? "plum"
  }

  private static func tintHex(hue: Double, saturation: Double, lightness: Double) -> String {
    let (r, g, b) = ThemeMath.hslToRgb(hue, saturation, lightness)
    return ThemeMath.hex([r, g, b])
  }

  private static func preset(_ color: String, dark: Bool, adjustInk: Bool) -> Self {
    let privateWindow = color == "incognito"
    let neutral = privateWindow || color == "neutral"
    let plum = color == "plum" || presets[color] == nil
    let swatch = presets[color] ?? presets["plum"]!
    let tint = privateWindow ? "#3A3A3C" : plum ? "#B25B6B" : tintHex(hue: hsl(swatch).0, saturation: neutral ? 0 : 0.36, lightness: 0.527)
    let backdrop = Backdrop(tintColor: tint, tintAlpha: neutral ? 0.12 : 0.36)
    let powerUp = neutral ? "#808080A6" : plum ? "#B5556B" : swatch

    let alpha = backdrop.tintAlpha * (dark ? 0.5 : 0.75)
    let under = dark ? [40.7, 33.1, 31.8].map { 0.6 * $0 } : [235.0, 231.0, 230.0].map { 0.8 * 255 + 0.2 * $0 }
    let top = ThemeMath.hexColor(tint)
    let (h, s, l) = hsl(tint)
    let (r, g, b) = ThemeMath.hslToRgb(h, s, min(1, l + backdrop.tintLightness))
    let windowTint = [[top.r, top.g, top.b], [r, g, b]].map { layer in
      ThemeMath.hex(zip(layer, under).map { alpha * $0.0 + (1 - alpha) * $0.1 / 255 })
    }
    return Self(dark: dark, profileColor: color, backdrop: backdrop, windowTint: windowTint, powerUpColor: powerUp,
      powerUpPalette: [powerUp], custom: nil, sidebarInk: nil, stripInk: nil, adjustInk: adjustInk)
  }

  private static func ink(_ look: ProfileThemeValue, dark: Bool, strip: Bool) -> [String: String]? {
    let ink = ThemeMath.textInk(look, dark: dark, strip: strip, selectedAlpha: dark ? 128.0 / 255 : 179.0 / 255)
    let flips = ink.dark == dark
    guard flips || ink.selectedDark == dark else { return nil }
    var tokens = ["tabSelectedText": ink.selectedDark ? "#000000" : "#FFFFFF"]
    if flips {
      let base = dark ? NewTabThemeTokens.light : NewTabThemeTokens.dark
      for key in ["textPrimary", "textSecondary", "textTertiary", "icon", "iconDisabled"] { tokens[key] = base[key] }
      tokens["textTab"] = dark ? "#000000AD" : "#FFFFFFC7"
      tokens["ink"] = dark ? "dark" : "light"
    }
    return tokens
  }

  private static func parseTheme(_ raw: JSONValue) -> ProfileThemeValue? {
    guard let look = parseLook(raw) else { return nil }
    return ProfileThemeValue(stops: look.stops, intensity: look.intensity,
      mode: raw["mode"]?.string.flatMap(ThemeModeValue.init(rawValue:)) ?? .auto,
      grain: look.grain, texture: look.texture, translucency: look.translucency, angle: look.angle,
      dark: raw["dark"].flatMap(parseLook))
  }

  private static func parseLook(_ raw: JSONValue) -> ThemeLookValue? {
    guard let rawStops = raw["stops"]?.array else { return nil }
    let stops = rawStops.prefix(16).compactMap { item -> ThemeStopValue? in
      let color = item["color"]
      guard let r = color?["r"]?.number, let g = color?["g"]?.number, let b = color?["b"]?.number,
        abs(r) < 4, abs(g) < 4, abs(b) < 4 else { return nil }
      return ThemeStopValue(color: ThemeRGBA(r: r, g: g, b: b, a: unit(color?["a"], default: 1)),
        x: unit(item["x"], default: 0.5), y: unit(item["y"], default: 0.5))
    }.prefix(ThemeMath.maxStops)
    guard !stops.isEmpty else { return nil }
    let angle = raw["angle"]?.number.flatMap { $0.isFinite ? ThemeMath.positiveModulo($0, 360) : nil }
    return ThemeLookValue(stops: Array(stops), intensity: unit(raw["intensity"], default: 0.6),
      grain: unit(raw["grain"], default: 0), texture: raw["texture"]?.string.flatMap(ThemeTextureValue.init(rawValue:)) ?? .grain,
      translucency: unit(raw["translucency"], default: 1), angle: angle)
  }

  private static func unit(_ value: JSONValue?, default fallback: Double) -> Double {
    guard let number = value?.number, number.isFinite else { return fallback }
    return ThemeMath.clamp01(number)
  }
}
