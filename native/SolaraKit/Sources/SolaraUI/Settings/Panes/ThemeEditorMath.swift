import Foundation

public struct ThemeRGBA: Hashable, Sendable, Codable {
  public var r: Double
  public var g: Double
  public var b: Double
  public var a: Double

  public init(r: Double, g: Double, b: Double, a: Double = 1) {
    self.r = r
    self.g = g
    self.b = b
    self.a = a
  }
}

public struct ThemeStopValue: Hashable, Sendable, Codable {
  public var color: ThemeRGBA
  public var x: Double
  public var y: Double

  public init(color: ThemeRGBA, x: Double, y: Double) {
    self.color = color
    self.x = x
    self.y = y
  }
}

public enum ThemeModeValue: String, Hashable, Sendable, Codable, CaseIterable {
  case light
  case dark
  case auto
}

public enum ThemeTextureValue: String, Hashable, Sendable, Codable, CaseIterable {
  case grain
  case sand
  case denim
  case tweed

  public var title: String {
    switch self {
    case .grain: "Grain"
    case .sand: "Sand"
    case .denim: "Denim"
    case .tweed: "Tweed"
    }
  }

  var strength: Double {
    switch self {
    case .grain: 0.8
    case .sand: 0.15
    case .denim: 0.6
    case .tweed: 0.4
    }
  }
}

public struct ThemeLookValue: Hashable, Sendable, Codable {
  public var stops: [ThemeStopValue]
  public var intensity: Double
  public var grain: Double
  public var texture: ThemeTextureValue
  public var translucency: Double
  public var angle: Double?

  public init(stops: [ThemeStopValue], intensity: Double, grain: Double, texture: ThemeTextureValue, translucency: Double, angle: Double? = nil) {
    self.stops = stops
    self.intensity = intensity
    self.grain = grain
    self.texture = texture
    self.translucency = translucency
    self.angle = angle
  }
}

public struct ProfileThemeValue: Hashable, Sendable, Codable {
  public var stops: [ThemeStopValue]
  public var intensity: Double
  public var grain: Double
  public var texture: ThemeTextureValue
  public var translucency: Double
  public var angle: Double?
  public var mode: ThemeModeValue
  public var dark: ThemeLookValue?

  public init(stops: [ThemeStopValue], intensity: Double, mode: ThemeModeValue, grain: Double, texture: ThemeTextureValue, translucency: Double, angle: Double? = nil, dark: ThemeLookValue? = nil) {
    self.stops = stops
    self.intensity = intensity
    self.mode = mode
    self.grain = grain
    self.texture = texture
    self.translucency = translucency
    self.angle = angle
    self.dark = dark
  }

  public var look: ThemeLookValue {
    ThemeLookValue(stops: stops, intensity: intensity, grain: grain, texture: texture, translucency: translucency, angle: angle)
  }
}

public enum ThemeLookSource: String, Sendable {
  case own
  case app
  case utility
}

public struct ShownThemeLook: Hashable, Sendable {
  public var look: ProfileThemeValue
  public var requestedDark: Bool
  public var dark: Bool
}

public struct ThemeSwatchSpec: Hashable, Sendable {
  public var colors: [Double]
  public var grain: Double
  public var texture: ThemeTextureValue
  public var padLightness: Double
  public var angle: Double

  public init(colors: [Double], grain: Double = 0, texture: ThemeTextureValue = .grain, padLightness: Double = -1, angle: Double = ThemeMath.defaultAngle) {
    self.colors = colors
    self.grain = grain
    self.texture = texture
    self.padLightness = padLightness
    self.angle = angle
  }
}

public enum ThemeMath {
  public static let maxStops = 3
  public static let padLightness = 0.6
  public static let defaultAngle = 135.0
  static let baseReach = 0.75
  static let darkenedKeep = 0.4

  static func clamp01(_ v: Double) -> Double { min(1, max(0, v)) }

  static func jsRound(_ v: Double) -> Double { (v + 0.5).rounded(.down) }

  static func positiveModulo(_ v: Double, _ m: Double) -> Double {
    (v.truncatingRemainder(dividingBy: m) + m).truncatingRemainder(dividingBy: m)
  }

  public static func hslToRgb(_ h: Double, _ s: Double, _ l: Double) -> (Double, Double, Double) {
    if s == 0 { return (l, l, l) }
    let q = l < 0.5 ? l * (1 + s) : l + s - l * s
    let p = 2 * l - q
    func channel(_ input: Double) -> Double {
      let t = input < 0 ? input + 1 : input > 1 ? input - 1 : input
      if t < 1.0 / 6 { return p + (q - p) * 6 * t }
      if t < 1.0 / 2 { return q }
      if t < 2.0 / 3 { return p + (q - p) * (2.0 / 3 - t) * 6 }
      return p
    }
    return (channel(h + 1.0 / 3), channel(h), channel(h - 1.0 / 3))
  }

  public static func rgbToHsl(_ r: Double, _ g: Double, _ b: Double) -> (Double, Double, Double) {
    let maxV = max(r, g, b), minV = min(r, g, b), l = (maxV + minV) / 2, d = maxV - minV
    if d == 0 { return (0, 0, l) }
    let s = l > 0.5 ? d / (2 - maxV - minV) : d / (maxV + minV)
    let h: Double
    if maxV == r { h = (g - b) / d + (g < b ? 6 : 0) } else if maxV == g { h = (b - r) / d + 2 } else { h = (r - g) / d + 4 }
    return (h / 6, s, l)
  }

  public static func padColor(_ x: Double, _ y: Double, lightness: Double = padLightness) -> ThemeRGBA {
    let dx = clamp01(x) - 0.5, dy = clamp01(y) - 0.5
    var hue = atan2(dy, dx) / (2 * .pi)
    if hue < 0 { hue += 1 }
    let sat = min(1, hypot(dx, dy) / 0.5)
    let (r, g, b) = hslToRgb(hue, sat, clamp01(lightness))
    return ThemeRGBA(r: r, g: g, b: b, a: 1)
  }

  public static func padPosition(_ color: ThemeRGBA) -> (x: Double, y: Double) {
    let (h, s, _) = rgbToHsl(clamp01(color.r), clamp01(color.g), clamp01(color.b))
    let angle = h * 2 * .pi
    return (0.5 + 0.5 * s * cos(angle), 0.5 + 0.5 * s * sin(angle))
  }

  static func decode(_ v: Double) -> Double {
    let a = abs(v)
    let sign: Double = v < 0 ? -1 : v > 0 ? 1 : 0
    return sign * (a <= 0.04045 ? a / 12.92 : pow((a + 0.055) / 1.055, 2.4))
  }

  static func encode(_ v: Double) -> Double {
    let a = abs(v)
    let sign: Double = v < 0 ? -1 : v > 0 ? 1 : 0
    return sign * (a <= 0.0031308 ? a * 12.92 : 1.055 * pow(a, 1 / 2.4) - 0.055)
  }

  static func oklab(_ c: ThemeRGBA) -> [Double] {
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

  static func fromOklab(_ lab: [Double]) -> [Double] {
    let (L, A, B) = (lab[0], lab[1], lab[2])
    let l = pow3(L + 0.3963377774 * A + 0.2158037573 * B)
    let m = pow3(L - 0.1055613458 * A - 0.0638541728 * B)
    let s = pow3(L - 0.0894841775 * A - 1.291485548 * B)
    return [
      4.0767416621 * l - 3.3077115913 * m + 0.2309699292 * s,
      -1.2684380046 * l + 2.6097574011 * m - 0.3413193965 * s,
      -0.0041960863 * l - 0.7034186147 * m + 1.707614701 * s,
    ].map(encode)
  }

  static func pow3(_ v: Double) -> Double { v * v * v }

  static func hex(_ channels: [Double]) -> String {
    "#" + channels.map { String(format: "%02X", Int(jsRound(clamp01($0) * 255))) }.joined()
  }

  public static func colorHex(_ color: ThemeRGBA) -> String { hex([color.r, color.g, color.b]) }

  public static func hexColor(_ hex: String) -> ThemeRGBA {
    let digits = Array(hex.dropFirst())
    func channel(_ i: Int) -> Double {
      guard digits.count >= 2 * i + 2 else { return 0 }
      return Double(Int(String(digits[(2 * i)...(2 * i + 1)]), radix: 16) ?? 0) / 255
    }
    return ThemeRGBA(r: channel(0), g: channel(1), b: channel(2), a: 1)
  }

  static func mixOklab(_ a: ThemeRGBA, _ b: ThemeRGBA, _ t: Double) -> [Double] {
    let la = oklab(a), lb = oklab(b)
    return fromOklab(zip(la, lb).map { $0 + ($1 - $0) * t })
  }

  public static func lookAngle(_ theme: ProfileThemeValue) -> Double { theme.angle ?? defaultAngle }

  static func direction(_ degrees: Double) -> (dx: Double, dy: Double) {
    let r = degrees * .pi / 180
    return (sin(r), -cos(r))
  }

  static func baseHalf(_ w: Double, _ h: Double, _ dx: Double, _ dy: Double) -> Double {
    hypot(w * dx, h * dy) * hypot(w, h) / (2 * max(w, h))
  }

  static func overlayHalf(_ w: Double, _ h: Double, _ dx: Double, _ dy: Double) -> Double {
    (w * abs(dx) + h * abs(dy)) / 2
  }

  static func along(_ degrees: Double, _ x: Double, _ y: Double, _ w: Double, _ h: Double, _ half: (Double, Double, Double, Double) -> Double) -> Double {
    let (dx, dy) = direction(degrees)
    return ((x - w / 2) * dx + (y - h / 2) * dy) / (2 * half(w, h, dx, dy)) + 0.5
  }

  static func themeArea(_ theme: ProfileThemeValue, _ x: Double, _ y: Double, _ w: Double, _ h: Double) -> [Double] {
    let colors = theme.stops.map(\.color)
    guard let c0 = colors.first else { return [0, 0, 0] }
    let c1 = colors.count > 1 ? colors[1] : c0
    let angle = lookAngle(theme)
    let t = clamp01(along(angle, x, y, w, h, baseHalf) / baseReach)
    let base = mixOklab(c0, c1, t)
    guard colors.count > 2 else { return base }
    let c2 = colors[2]
    let a = clamp01(along(angle + 45, x, y, w, h, overlayHalf)) * c2.a
    let target = [c2.r, c2.g, c2.b]
    return base.enumerated().map { i, v in v + (target[i] - v) * a }
  }

  public static func themeDark(_ theme: ProfileThemeValue, appDark: Bool) -> Bool {
    theme.mode == .auto ? appDark : theme.mode == .dark
  }

  public static func resolve(_ theme: ProfileThemeValue, dark: Bool) -> ProfileThemeValue {
    var base = theme
    base.dark = nil
    guard dark, let darkLook = theme.dark else { return base }
    base.stops = darkLook.stops
    base.intensity = darkLook.intensity
    base.grain = darkLook.grain
    base.texture = darkLook.texture
    base.translucency = darkLook.translucency
    base.angle = darkLook.angle
    return base
  }

  static func darkened(_ theme: ProfileThemeValue, keep: Double = darkenedKeep) -> ProfileThemeValue {
    var next = theme
    next.stops = theme.stops.map { stop in
      var s = stop
      s.color = ThemeRGBA(r: stop.color.r * keep, g: stop.color.g * keep, b: stop.color.b * keep, a: stop.color.a)
      return s
    }
    return next
  }

  public static func requestedDark(_ theme: ProfileThemeValue, appDark: Bool, source: ThemeLookSource) -> Bool {
    source == .own ? themeDark(theme, appDark: appDark) : appDark
  }

  public static func shown(_ theme: ProfileThemeValue, appDark: Bool, source: ThemeLookSource) -> ShownThemeLook {
    let requested = requestedDark(theme, appDark: appDark, source: source)
    let resolved = resolve(theme, dark: requested)
    let lightOnly = theme.mode != .dark && theme.dark == nil
    let look = source != .own && requested && lightOnly && !readableDark(resolved, dark: true) ? darkened(resolved) : resolved
    let dark = source == .utility ? requested : readableDark(look, dark: requested)
    return ShownThemeLook(look: look, requestedDark: requested, dark: dark)
  }

  static func arcLayerAlpha(_ intensity: Double) -> Double { 0.2 + 0.55 * clamp01(intensity) }

  public static func layerAlpha(_ theme: ProfileThemeValue) -> Double {
    1 - clamp01(theme.translucency) * (1 - arcLayerAlpha(theme.intensity))
  }

  static func underlayAlpha(_ theme: ProfileThemeValue, dark: Bool) -> Double {
    let arc = min(arcLayerAlpha(theme.intensity), 0.5)
    return clamp01(theme.translucency) * (dark ? 0.35 * arc : arc)
  }

  public static func grainAlpha(_ theme: ProfileThemeValue) -> Double {
    clamp01(theme.grain) * theme.texture.strength
  }

  public static func flatColors(_ theme: ProfileThemeValue) -> [Double] {
    theme.stops.prefix(maxStops).flatMap { [$0.color.r, $0.color.g, $0.color.b, $0.color.a] }
  }

  public static func accent(_ theme: ProfileThemeValue) -> String {
    hex(themeArea(theme, 0.5, 0.5, 1, 1))
  }

  static func underGray(_ theme: ProfileThemeValue, dark: Bool) -> Double {
    let u = underlayAlpha(theme, dark: dark)
    let blur = dark ? 0.16 : 0.92
    return (dark ? 0 : 1) * u + blur * (1 - u)
  }

  public static func underColor(_ theme: ProfileThemeValue, dark: Bool) -> String {
    let gray = underGray(theme, dark: dark)
    return hex([gray, gray, gray])
  }

  static func composite(_ theme: ProfileThemeValue, dark: Bool, _ x: Double, _ y: Double) -> [Double] {
    let a = layerAlpha(theme)
    let under = underGray(theme, dark: dark)
    return themeArea(theme, x, y, 1, 1).map { a * clamp01($0) + (1 - a) * under }
  }

  static func relativeLuminance(_ c: [Double]) -> Double {
    let d = c.map { decode(clamp01($0)) }
    return 0.2126 * d[0] + 0.7152 * d[1] + 0.0722 * d[2]
  }

  static func luminance(_ theme: ProfileThemeValue, dark: Bool) -> Double {
    let points = [0, 0.5, 1.0]
    var sum = 0.0
    for x in points { for y in points { sum += relativeLuminance(composite(theme, dark: dark, x, y)) } }
    return sum / Double(points.count * points.count)
  }

  public static func readableDark(_ theme: ProfileThemeValue, dark: Bool) -> Bool {
    let y = luminance(theme, dark: dark)
    let blackText = (y + 0.05) / 0.05, whiteText = 1.05 / (y + 0.05)
    if dark { return !(whiteText < 2 && blackText > whiteText) }
    return blackText < 3 && whiteText > blackText
  }

  public static func opaqueTint(_ theme: ProfileThemeValue, dark: Bool) -> String {
    hex(composite(theme, dark: dark, 0, 0))
  }

  public static func textInk(_ theme: ProfileThemeValue, dark: Bool, strip: Bool) -> (dark: Bool, selectedDark: Bool) {
    let points: [(Double, Double)] = strip ? [(0.1, 0.03), (0.5, 0.03), (0.9, 0.03)] : [(0.06, 0.1), (0.06, 0.5), (0.06, 0.9)]
    let colors = points.map { composite(theme, dark: dark, $0.0, $0.1) }
    let a = dark ? 0.5 : 0.7
    let fill = dark ? 18.0 / 255 : 1.0
    let selected = colors.map { $0.map { clamp01($0) * (1 - a) + fill * a } }
    func black(_ colors: [[Double]]) -> Bool {
      let y = colors.reduce(0) { $0 + relativeLuminance($1) } / Double(colors.count)
      return (y + 0.05) / 0.05 > 1.05 / (y + 0.05)
    }
    return (black(colors), black(selected))
  }

  public static func stopLightness(_ stop: ThemeStopValue) -> Double {
    rgbToHsl(clamp01(stop.color.r), clamp01(stop.color.g), clamp01(stop.color.b)).2
  }

  public static func withStop(_ theme: ProfileThemeValue, at index: Int, x: Double, y: Double) -> ProfileThemeValue {
    var next = theme
    next.stops = theme.stops.enumerated().map { i, s in
      guard i == index else { return s }
      var color = padColor(x, y, lightness: stopLightness(s))
      color.a = s.color.a
      return ThemeStopValue(color: color, x: x, y: y)
    }
    return next
  }

  public static func withStopLightness(_ theme: ProfileThemeValue, at index: Int, _ lightness: Double) -> ProfileThemeValue {
    var next = theme
    next.stops = theme.stops.enumerated().map { i, s in
      guard i == index else { return s }
      var color = padColor(s.x, s.y, lightness: lightness)
      color.a = s.color.a
      return ThemeStopValue(color: color, x: s.x, y: s.y)
    }
    return next
  }

  public static func withAngle(_ theme: ProfileThemeValue, _ degrees: Double) -> ProfileThemeValue {
    var next = theme
    next.angle = positiveModulo(jsRound(degrees), 360)
    return next
  }

  public static func withAddedStop(_ theme: ProfileThemeValue) -> ProfileThemeValue {
    guard theme.stops.count < maxStops else { return theme }
    let lastX = theme.stops.last?.x ?? 0.8, lastY = theme.stops.last?.y ?? 0.5
    let angle = atan2(lastY - 0.5, lastX - 0.5) + 2 * .pi / 5
    let radius = max(0.3, hypot(lastX - 0.5, lastY - 0.5))
    let x = 0.5 + radius * cos(angle), y = 0.5 + radius * sin(angle)
    var next = theme
    next.stops.append(ThemeStopValue(color: padColor(x, y), x: x, y: y))
    return next
  }

  public static func withoutStop(_ theme: ProfileThemeValue, at index: Int) -> ProfileThemeValue {
    guard theme.stops.count > 1 else { return theme }
    var next = theme
    next.stops = theme.stops.enumerated().filter { $0.offset != index }.map(\.element)
    return next
  }

  public static func starting(swatch: String) -> ProfileThemeValue {
    let base = padPosition(hexColor(swatch))
    let angle = atan2(base.y - 0.5, base.x - 0.5)
    let radius = max(0.3, hypot(base.x - 0.5, base.y - 0.5))
    func stop(_ offset: Double) -> ThemeStopValue {
      let x = 0.5 + radius * cos(angle + offset), y = 0.5 + radius * sin(angle + offset)
      return ThemeStopValue(color: padColor(x, y), x: x, y: y)
    }
    return ProfileThemeValue(stops: [stop(-0.45), stop(0.45)], intensity: 0.6, mode: .auto, grain: 0, texture: .grain, translucency: 1)
  }

  public static let rainbow = ProfileThemeValue(
    stops: [
      ThemeStopValue(color: ThemeRGBA(r: 0.93, g: 0.45, b: 0.62), x: 1, y: 0.5),
      ThemeStopValue(color: ThemeRGBA(r: 0.42, g: 0.66, b: 0.95), x: 0, y: 0.5),
      ThemeStopValue(color: ThemeRGBA(r: 0.62, g: 0.9, b: 0.58), x: 0.5, y: 1),
    ],
    intensity: 1,
    mode: .auto,
    grain: 0,
    texture: .grain,
    translucency: 0
  )

  public static func snappedDialAngle(dx: Double, dy: Double, snap: Double = 4) -> Double {
    let degrees = positiveModulo(atan2(dx, -dy) * 180 / .pi + 360, 360)
    let notch = jsRound(degrees / 45) * 45
    return positiveModulo(abs(degrees - notch) <= snap ? notch : jsRound(degrees), 360)
  }

  public static func insidePad(x: Double, y: Double) -> (x: Double, y: Double) {
    let dx = x - 0.5, dy = y - 0.5, r = hypot(dx, dy)
    return r <= 0.5 ? (x, y) : (0.5 + dx / r * 0.5, 0.5 + dy / r * 0.5)
  }
}
