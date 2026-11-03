import SwiftUI

public enum ProfileColorValue: String, Hashable, Sendable, Codable, CaseIterable {
  case plum
  case blue
  case purple
  case pink
  case red
  case orange
  case yellow
  case green
  case neutral

  public var name: String {
    switch self {
    case .plum: "Plum"
    case .blue: "Blue"
    case .purple: "Purple"
    case .pink: "Pink"
    case .red: "Red"
    case .orange: "Orange"
    case .yellow: "Yellow"
    case .green: "Green"
    case .neutral: "Neutral"
    }
  }

  public var swatch: String {
    switch self {
    case .plum: "#C07A98"
    case .blue: "#4691C3"
    case .purple: "#7873AF"
    case .pink: "#D37B8B"
    case .red: "#C1575C"
    case .orange: "#D87249"
    case .yellow: "#E3AC38"
    case .green: "#3EB489"
    case .neutral: "#8E8E93"
    }
  }

  static let creationOrder: [ProfileColorValue] = [.blue, .green, .orange, .purple, .red, .yellow, .pink]

  static func unused(by profiles: [ProfileSummary]) -> ProfileColorValue {
    creationOrder.first { color in !profiles.contains { $0.color == color } } ?? .blue
  }
}

public struct ProfileSymbol: Hashable, Sendable {
  public let name: String
  public let title: String
}

public enum ProfileIcons {
  public static let symbolPrefix = "symbol:"

  public static let symbols: [ProfileSymbol] = [
    ProfileSymbol(name: "house.fill", title: "Home"),
    ProfileSymbol(name: "briefcase.fill", title: "Work"),
    ProfileSymbol(name: "graduationcap.fill", title: "School"),
    ProfileSymbol(name: "chevron.left.forwardslash.chevron.right", title: "Code"),
    ProfileSymbol(name: "paintpalette.fill", title: "Art"),
    ProfileSymbol(name: "hammer.fill", title: "Projects"),
    ProfileSymbol(name: "book.closed.fill", title: "Reading"),
    ProfileSymbol(name: "music.note", title: "Music"),
    ProfileSymbol(name: "camera.fill", title: "Photos"),
    ProfileSymbol(name: "gamecontroller.fill", title: "Games"),
    ProfileSymbol(name: "cart.fill", title: "Shopping"),
    ProfileSymbol(name: "banknote.fill", title: "Finance"),
    ProfileSymbol(name: "airplane", title: "Travel"),
    ProfileSymbol(name: "figure.run", title: "Fitness"),
    ProfileSymbol(name: "cup.and.saucer.fill", title: "Café"),
    ProfileSymbol(name: "leaf.fill", title: "Nature"),
    ProfileSymbol(name: "pawprint.fill", title: "Pets"),
    ProfileSymbol(name: "heart.fill", title: "Personal"),
    ProfileSymbol(name: "star.fill", title: "Favorites"),
    ProfileSymbol(name: "moon.stars.fill", title: "Evenings"),
  ]

  public static func symbol(_ icon: String?) -> String? {
    guard let icon, icon.hasPrefix(symbolPrefix) else { return nil }
    return String(icon.dropFirst(symbolPrefix.count))
  }

  public static func title(_ icon: String?) -> String {
    if let symbol = symbol(icon) { return symbols.first { $0.name == symbol }?.title ?? spokenName(symbol) }
    return icon ?? "Initial"
  }

  static func spokenName(_ symbol: String) -> String {
    let words = symbol.split(separator: ".").filter { $0 != "fill" }.joined(separator: " ")
    return words.prefix(1).uppercased() + words.dropFirst()
  }
}

enum ProfileNames {
  static func listOf(_ names: [String]) -> String {
    if names.count <= 2 { return names.joined(separator: " and ") }
    return "\(names.dropLast().joined(separator: ", ")), and \(names.last ?? "")"
  }

  static func ampersand(_ names: [String]) -> String {
    if names.count <= 2 { return names.joined(separator: " & ") }
    return "\(names.prefix(2).joined(separator: ", ")), & \(names.count - 2) more"
  }

  static func plural(_ n: Int, _ word: String) -> String {
    "\(n) \(word)\(n == 1 ? "" : "s")"
  }
}

extension Color {
  init(themeHex hex: String) {
    let rgba = ThemeMath.hexColor(hex)
    self.init(.sRGB, red: rgba.r, green: rgba.g, blue: rgba.b, opacity: 1)
  }

  init(themeRGBA rgba: ThemeRGBA) {
    self.init(.sRGB, red: ThemeMath.clamp01(rgba.r), green: ThemeMath.clamp01(rgba.g), blue: ThemeMath.clamp01(rgba.b), opacity: ThemeMath.clamp01(rgba.a))
  }
}

struct ProfileBadge: View {
  let profile: ProfileSummary
  var size: CGFloat = 26

  var body: some View {
    let symbol = ProfileIcons.symbol(profile.icon)
    ZStack {
      Circle().fill(Color(themeHex: profile.accent))
      if size >= 22 {
        Circle().strokeBorder(Color.black.opacity(0.12), lineWidth: 0.5)
      }
      if let symbol {
        Image(systemName: symbol)
          .font(.system(size: size * 0.5, weight: .semibold))
          .foregroundStyle(.white)
      } else {
        Text(profile.icon ?? profile.initial)
          .font(.system(size: profile.icon != nil ? size * 0.55 : size * 0.46, weight: .semibold))
          .foregroundStyle(.white)
      }
    }
    .frame(width: size, height: size)
  }
}

struct ProfileColorStack: View {
  @Environment(\.colorScheme) private var scheme
  let colors: [String]
  var size: CGFloat = 12

  var body: some View {
    let shown = Array(colors.prefix(4))
    HStack(spacing: -size * 0.4) {
      ForEach(Array(shown.enumerated()), id: \.offset) { _, color in
        Circle()
          .fill(Color(themeHex: color))
          .overlay(Circle().strokeBorder(scheme == .dark ? Color.black.opacity(0.35) : Color.white, lineWidth: 1))
          .frame(width: size, height: size)
      }
    }
  }
}
