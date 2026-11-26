import Foundation
import SolaraModel

public enum ImportArcTheme {
  private struct Look {
    let value: JSONObject
    let style: String?
  }

  private static func number(_ value: JSONValue?) -> Double? {
    guard let value = value?.number, value.isFinite else { return nil }
    return value
  }

  private static func clamp(_ value: Double) -> Double { min(1, max(0, value)) }

  private static func color(_ value: JSONValue?) -> ThemeRGBA? {
    guard let r = number(value?["red"]), let g = number(value?["green"]), let b = number(value?["blue"]) else { return nil }
    return ThemeRGBA(r: r, g: g, b: b, a: number(value?["alpha"]) ?? 1)
  }

  private static func appearance(_ value: JSONValue?) -> String? {
    guard let value = value?.string, value == "light" || value == "dark" else { return nil }
    return value
  }

  private static func look(_ background: JSONValue?) -> Look? {
    guard let kind = background?["style"]?["color"]?["_0"] else { return nil }
    let gradient = (kind["blendedGradient"]?["_0"]).flatMap { $0.object == nil ? nil : $0 }
    let single = (kind["blendedSingleColor"]?["_0"]).flatMap { $0.object == nil ? nil : $0 }
    let basic = (kind["basicColor"]?["_0"]).flatMap { $0.object == nil ? nil : $0 }
    guard let config = gradient ?? single ?? basic else { return nil }
    var colors: [ThemeRGBA]
    if let gradient {
      colors = (gradient["baseColors"]?.array ?? []).prefix(2).compactMap { color($0) }
      let overlay = (gradient["overlayColors"]?.array ?? []).prefix(2).compactMap { color($0) }
      if overlay.count > 1, !colors.isEmpty {
        if colors.count == 1 { colors.append(colors[0]) }
        colors.append(overlay[1])
      }
    } else {
      colors = color(config["color"]).map { [$0] } ?? []
    }
    let stops: [JSONValue] = colors.map { color in
      let position = ThemeMath.padPosition(color)
      return .object(["color": .object(["r": .number(color.r), "g": .number(color.g), "b": .number(color.b), "a": .number(clamp(color.a))]),
                      "x": .number(clamp(position.x)), "y": .number(clamp(position.y))])
    }
    guard !stops.isEmpty else { return nil }
    let modifiers = config["modifiers"]
    let texture = modifiers?["overlay"]?.string ?? "grain"
    return Look(value: [
      "stops": .array(stops),
      "intensity": .number(clamp(number(modifiers?["intensityFactor"]) ?? 1)),
      "grain": .number(basic != nil ? 0 : clamp(number(modifiers?["noiseFactor"]) ?? 0)),
      "texture": .string(["grain", "sand", "denim", "tweed"].contains(texture) ? texture : "grain"),
      "translucency": .number(basic != nil ? 0 : 1)
    ], style: config["translucencyStyle"]?.string)
  }

  private static func sanitized(_ look: Look) -> JSONObject? {
    var value = look.value
    let stops = (value["stops"]?.array ?? []).filter { stop in
      ["r", "g", "b"].allSatisfy { abs(stop["color"]?[$0]?.number ?? 4) < 4 }
    }
    guard !stops.isEmpty else { return nil }
    value["stops"] = .array(stops)
    return value
  }

  public static func parse(_ input: String) -> JSONValue? {
    guard input.utf16.count <= 64 * 1024, let data = input.data(using: .utf8),
      let _ = try? JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed]),
      let theme = try? JSONValue.parse(data), let background = theme["background"] else { return nil }
    let single = look(background["single"]?["_0"])
    let light = single ?? look(background["appearanceBased"]?["light"])
    let dark = single == nil ? look(background["appearanceBased"]?["dark"]) : nil
    guard let main = light ?? dark else { return nil }
    let window = theme["windowAppearance"]
    var forced = appearance(window?["single"]?["_0"])
    if forced == nil, let light = appearance(window?["appearanceBased"]?["light"]), let dark = appearance(window?["appearanceBased"]?["dark"]) {
      forced = light == dark ? light : "auto"
    }
    let mode = forced ?? (light != nil && dark != nil ? "auto" : (["light", "dark"].contains(main.style ?? "") ? main.style! : "auto"))
    guard var value = sanitized(mode == "dark" ? dark ?? main : main) else { return nil }
    value["mode"] = .string(mode)
    if light != nil, let dark, mode == "auto", let valueDark = sanitized(dark) { value["dark"] = .object(valueDark) }
    return .object(value)
  }
}

@MainActor
final class ImportThemeAcknowledgement {
  var accepted = false
}
