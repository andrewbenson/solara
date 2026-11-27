import Foundation
import SolaraModel

public enum LaunchBackdropProvider {
  struct Color {
    var r: Double
    var g: Double
    var b: Double
    var a: Double

    var rgb: [Double] { [r, g, b] }

    init(_ r: Double, _ g: Double, _ b: Double, _ a: Double = 1) {
      self.r = r
      self.g = g
      self.b = b
      self.a = a
    }

    init(_ hex: String) {
      let value = UInt32(hex.dropFirst(), radix: 16) ?? 0
      self.init(Double((value >> 16) & 255) / 255, Double((value >> 8) & 255) / 255, Double(value & 255) / 255)
    }
  }

  struct Look {
    var colors: [Color]
    var intensity: Double
    var grain: Double
    var texture: String
    var translucency: Double
    var angle: Double

    init?(_ json: JSONValue) {
      colors = (json["stops"]?.array ?? []).compactMap { stop in
        guard let r = stop["color"]?["r"]?.number, let g = stop["color"]?["g"]?.number, let b = stop["color"]?["b"]?.number else { return nil }
        return Color(r, g, b, stop["color"]?["a"]?.number ?? 1)
      }
      guard !colors.isEmpty else { return nil }
      intensity = json["intensity"]?.number ?? 0.6
      grain = json["grain"]?.number ?? 0
      texture = json["texture"]?.string ?? "grain"
      translucency = json["translucency"]?.number ?? 1
      angle = json["angle"]?.number ?? 135
    }

    func darkened() -> Look {
      var look = self
      look.colors = colors.map { Color($0.r * 0.4, $0.g * 0.4, $0.b * 0.4, $0.a) }
      return look
    }
  }

  static let swatches: [String: String] = [
    "plum": "#C07A98", "blue": "#4691C3", "purple": "#7873AF", "pink": "#D37B8B", "red": "#C1575C",
    "orange": "#D87249", "yellow": "#E3AC38", "green": "#3EB489", "neutral": "#8E8E93",
  ]

  static func document(_ state: BrowserState, windowId: String?) -> JSONValue {
    guard let windowId, let window = state.windows[windowId], !window.incognito, !window.isSmall else { return .null }
    let appDark: Bool
    switch state.settings.string("appearance") {
    case "dark": appDark = true
    case "light": appDark = false
    default: appDark = state.caches.systemDark
    }
    return profile(state, profileId: window.profileId, appDark: appDark)
  }

  public static func profile(_ state: BrowserState, profileId: String, appDark: Bool) -> JSONValue {
    let profile = state.profiles[profileId]
    let color = profile?.color ?? "plum"
    guard let custom = profile?.theme, let base = Look(custom) else { return preset(color, appDark: appDark) }
    let mode = custom["mode"]?.string ?? "auto"
    let followsApp = state.settings.bool("spacesFollowAppearance")
    let requestedDark = followsApp || mode == "auto" ? appDark : mode == "dark"
    let darkLook = custom["dark"].flatMap(Look.init)
    var look = requestedDark ? darkLook ?? base : base
    if followsApp && requestedDark && mode != "dark" && darkLook == nil && !readableDark(look, dark: true) {
      look = look.darkened()
    }
    let dark = readableDark(look, dark: requestedDark)
    let accent = hex(area(look, x: 0.5, y: 0.5))
    let appearance = dark != requestedDark ? (dark ? "dark" : "light") : followsApp ? "auto" : mode
    let textureStrength = ["grain": 0.8, "sand": 0.15, "denim": 0.6, "tweed": 0.4][look.texture] ?? 0.8
    return [
      "dark": .bool(appDark), "vibrancy": true,
      "colors": JSONValue([hex(composite(look, dark: dark, x: 0, y: 0)), hex(composite(look, dark: dark, x: 1, y: 1))]),
      "tintColor": .string(accent), "tintAlpha": 0.36, "tintLightness": 0.25,
      "themeColors": .array(look.colors.prefix(3).flatMap { [$0.r, $0.g, $0.b, $0.a] }.map(JSONValue.number)),
      "themeOpacity": .number(layerAlpha(look)), "themeBaseAlpha": .number(underlayAlpha(look, dark: dark)),
      "themeGrain": .number(clamp(look.grain) * textureStrength), "themeTexture": .string(look.texture),
      "themeAppearance": .string(appearance), "themeAngle": .number(look.angle), "grainOpacity": .number(dark ? 0.006 : 0.05),
    ]
  }

  static func preset(_ color: String, appDark: Bool) -> JSONValue {
    let name = swatches[color] == nil ? "plum" : color
    let neutral = name == "neutral"
    let swatch = Color(swatches[name] ?? "#C07A98")
    let tint = name == "plum" ? "#B25B6B" : hex(fromHsl(hsl(swatch.rgb)[0], neutral ? 0 : 0.36, 0.527))
    let alpha = neutral ? 0.12 : 0.36
    let a = alpha * (appDark ? 0.5 : 0.75)
    let darkFill: [Double] = [40.7, 33.1, 31.8]
    let lightFill: [Double] = [235, 231, 230]
    let darkUnder: [Double] = darkFill.map { 0.6 * $0 / 255 }
    let lightUnder: [Double] = lightFill.map { (0.8 * 255 + 0.2 * $0) / 255 }
    let under: [Double] = appDark ? darkUnder : lightUnder
    let top = Color(tint).rgb
    let parts = hsl(top)
    let bottom = fromHsl(parts[0], parts[1], clamp(parts[2] + 0.25))
    func over(_ c: [Double]) -> String { hex(zip(c, under).map { a * $0 + (1 - a) * $1 }) }
    return [
      "dark": .bool(appDark), "vibrancy": true, "colors": JSONValue([over(top), over(bottom)]),
      "tintColor": .string(tint), "tintAlpha": .number(alpha), "tintLightness": 0.25,
      "themeColors": [], "themeOpacity": 1, "themeBaseAlpha": 0, "themeGrain": 0, "themeTexture": "grain",
      "themeAppearance": "auto", "themeAngle": 135, "grainOpacity": .number(appDark ? 0.006 : 0.05),
    ]
  }

  static func clamp(_ value: Double) -> Double { min(1, max(0, value)) }

  static func hex(_ c: [Double]) -> String {
    "#" + c.map { String(format: "%02X", Int(floor(clamp($0) * 255 + 0.5))) }.joined()
  }

  static func hsl(_ c: [Double]) -> [Double] {
    let r = c[0], g = c[1], b = c[2]
    let maximum = max(r, g, b), minimum = min(r, g, b), lightness = (maximum + minimum) / 2, delta = maximum - minimum
    if delta == 0 { return [0, 0, lightness] }
    let saturation = lightness > 0.5 ? delta / (2 - maximum - minimum) : delta / (maximum + minimum)
    let hue = maximum == r ? (g - b) / delta + (g < b ? 6 : 0) : maximum == g ? (b - r) / delta + 2 : (r - g) / delta + 4
    return [hue / 6, saturation, lightness]
  }

  static func fromHsl(_ h: Double, _ s: Double, _ l: Double) -> [Double] {
    if s == 0 { return [l, l, l] }
    let q = l < 0.5 ? l * (1 + s) : l + s - l * s, p = 2 * l - q
    func channel(_ value: Double) -> Double {
      let t = value < 0 ? value + 1 : value > 1 ? value - 1 : value
      return t < 1 / 6 ? p + (q - p) * 6 * t : t < 1 / 2 ? q : t < 2 / 3 ? p + (q - p) * (2 / 3 - t) * 6 : p
    }
    return [channel(h + 1 / 3), channel(h), channel(h - 1 / 3)]
  }

  static func decode(_ v: Double) -> Double {
    (v < 0 ? -1 : 1) * (abs(v) <= 0.04045 ? abs(v) / 12.92 : pow((abs(v) + 0.055) / 1.055, 2.4))
  }

  static func encode(_ v: Double) -> Double {
    (v < 0 ? -1 : 1) * (abs(v) <= 0.0031308 ? abs(v) * 12.92 : 1.055 * pow(abs(v), 1 / 2.4) - 0.055)
  }

  static func oklab(_ c: Color) -> [Double] {
    let r = decode(c.r), g = decode(c.g), b = decode(c.b)
    let l = cbrt(0.4122214708 * r + 0.5363325363 * g + 0.0514459929 * b)
    let m = cbrt(0.2119034982 * r + 0.6806995451 * g + 0.1073969566 * b)
    let s = cbrt(0.0883024619 * r + 0.2817188376 * g + 0.6299787005 * b)
    return [
      0.2104542553 * l + 0.793617785 * m - 0.0040720468 * s,
      1.9779984951 * l - 2.428592205 * m + 0.4505937099 * s,
      0.0259040371 * l + 0.7827717662 * m - 0.808675766 * s,
    ]
  }

  static func fromOklab(_ c: [Double]) -> [Double] {
    let l = pow(c[0] + 0.3963377774 * c[1] + 0.2158037573 * c[2], 3)
    let m = pow(c[0] - 0.1055613458 * c[1] - 0.0638541728 * c[2], 3)
    let s = pow(c[0] - 0.0894841775 * c[1] - 1.291485548 * c[2], 3)
    return [
      4.0767416621 * l - 3.3077115913 * m + 0.2309699292 * s,
      -1.2684380046 * l + 2.6097574011 * m - 0.3413193965 * s,
      -0.0041960863 * l - 0.7034186147 * m + 1.707614701 * s,
    ].map(encode)
  }

  static func mix(_ a: Color, _ b: Color, t: Double) -> [Double] {
    let x = oklab(a), y = oklab(b)
    return fromOklab(zip(x, y).map { $0 + ($1 - $0) * t })
  }

  static func area(_ look: Look, x: Double, y: Double) -> [Double] {
    func along(_ degrees: Double, overlay: Bool) -> Double {
      let radians = degrees * .pi / 180
      let dx = sin(radians), dy = -cos(radians)
      let half = overlay ? (abs(dx) + abs(dy)) / 2 : hypot(dx, dy) * hypot(1, 1) / 2
      return ((x - 0.5) * dx + (y - 0.5) * dy) / (2 * half) + 0.5
    }
    let base = mix(look.colors[0], look.colors.count > 1 ? look.colors[1] : look.colors[0], t: clamp(along(look.angle, overlay: false) / 0.75))
    guard look.colors.count > 2 else { return base }
    let top = look.colors[2]
    let alpha = clamp(along(look.angle + 45, overlay: true)) * top.a
    return zip(base, top.rgb).map { $0 + ($1 - $0) * alpha }
  }

  static func arcAlpha(_ look: Look) -> Double { 0.2 + 0.55 * clamp(look.intensity) }
  static func layerAlpha(_ look: Look) -> Double { 1 - clamp(look.translucency) * (1 - arcAlpha(look)) }
  static func underlayAlpha(_ look: Look, dark: Bool) -> Double { clamp(look.translucency) * (dark ? 0.35 * min(arcAlpha(look), 0.5) : min(arcAlpha(look), 0.5)) }

  static func composite(_ look: Look, dark: Bool, x: Double, y: Double) -> [Double] {
    let underlay = underlayAlpha(look, dark: dark)
    let under = (dark ? 0.0 : 1) * underlay + (dark ? 0.16 : 0.92) * (1 - underlay)
    let alpha = layerAlpha(look)
    return area(look, x: x, y: y).map { alpha * clamp($0) + (1 - alpha) * under }
  }

  static func readableDark(_ look: Look, dark: Bool) -> Bool {
    var sum = 0.0
    for x in [0.0, 0.5, 1] {
      for y in [0.0, 0.5, 1] {
        let c = composite(look, dark: dark, x: x, y: y).map { decode(clamp($0)) }
        sum += 0.2126 * c[0] + 0.7152 * c[1] + 0.0722 * c[2]
      }
    }
    let luminance = sum / 9
    let blackText = (luminance + 0.05) / 0.05, whiteText = 1.05 / (luminance + 0.05)
    return dark ? !(whiteText < 2 && blackText > whiteText) : blackText < 3 && whiteText > blackText
  }
}
