import AppKit
import SolaraEngine
import SolaraOmnibox
import SwiftUI

@MainActor
public final class NewTabFavicons {
  struct Key: Hashable {
    var url: String
    var favicon: String
    var profileId: String
    var dark: Bool
  }

  private let load: (String, String?, String, Bool) async -> NSImage?
  private var cache: [Key: NSImage] = [:]
  private var missing: Set<Key> = []
  private var generation = 0
  nonisolated(unsafe) private var invalidationObserver: NSObjectProtocol?

  public init(load: @escaping (_ url: String, _ favicon: String?, _ profileId: String, _ dark: Bool) async -> NSImage?) {
    self.load = load
    invalidationObserver = NotificationCenter.default.addObserver(forName: FaviconLibrary.didInvalidate, object: nil, queue: nil) { [weak self] _ in
      MainActor.assumeIsolated {
        self?.generation += 1
        self?.cache.removeAll()
        self?.missing.removeAll()
      }
    }
  }

  deinit { if let invalidationObserver { NotificationCenter.default.removeObserver(invalidationObserver) } }

  static func key(_ url: String, _ favicon: String?, profileId: String, dark: Bool) -> Key {
    Key(url: url, favicon: favicon ?? "", profileId: profileId, dark: dark)
  }

  func cached(_ url: String, _ favicon: String?, profileId: String, dark: Bool) -> NSImage? { cache[Self.key(url, favicon, profileId: profileId, dark: dark)] }

  func fetch(_ url: String, _ favicon: String?, profileId: String, dark: Bool) async -> NSImage? {
    let key = Self.key(url, favicon, profileId: profileId, dark: dark)
    if let image = cache[key] { return image }
    if missing.contains(key) { return nil }
    let generation = generation
    let image = await load(url, favicon, profileId, dark)
    guard generation == self.generation else { return nil }
    guard let image else {
      missing.insert(key)
      return nil
    }
    cache[key] = image
    return image
  }
}

struct NewTabEnvironment {
  var theme: NewTabTheme
  var favicons: NewTabFavicons?
  var profileId: String
}

private struct NewTabEnvironmentKey: EnvironmentKey {
  static let defaultValue = NewTabEnvironment(theme: .fallbackLight, favicons: nil, profileId: "")
}

extension EnvironmentValues {
  var newTab: NewTabEnvironment {
    get { self[NewTabEnvironmentKey.self] }
    set { self[NewTabEnvironmentKey.self] = newValue }
  }
}

struct SymbolImage: View {
  let name: String
  let size: CGFloat
  var weight: Font.Weight = .regular
  let color: Color
  let box: CGSize

  var body: some View {
    Image(systemName: name)
      .font(.system(size: size, weight: weight))
      .foregroundStyle(color)
      .frame(width: box.width, height: box.height)
  }
}

struct NewTabFavicon: View {
  @Environment(\.newTab) private var env
  @State private var image: NSImage?
  @State private var loadedKey: NewTabFavicons.Key?
  let url: String
  var favicon: String?
  var size: CGFloat = 16

  var body: some View {
    let key = NewTabFavicons.key(url, favicon, profileId: env.profileId, dark: env.theme.dark)
    Group {
      if let image = (loadedKey == key ? image : nil) ?? env.favicons?.cached(url, favicon, profileId: env.profileId, dark: env.theme.dark) {
        Image(nsImage: image)
          .resizable()
          .interpolation(.high)
          .frame(width: size, height: size)
          .clipShape(RoundedRectangle(cornerRadius: size > 18 ? 4 : 3))
      } else {
        FaviconFallbackTile(url: url, size: size)
      }
    }
    .task(id: key) {
      guard let favicons = env.favicons else { return }
      let fetched = await favicons.fetch(url, favicon, profileId: env.profileId, dark: env.theme.dark)
      image = fetched
      loadedKey = key
    }
  }
}

struct FaviconFallbackTile: View {
  @Environment(\.newTab) private var env
  let url: String
  let size: CGFloat

  var body: some View {
    let initial = hostInitial(url)
    if initial.isEmpty {
      SymbolImage(name: "globe", size: size - 3, color: env.theme.textSecondary.color, box: CGSize(width: size, height: size))
    } else {
      let tile = (size * 14 / 16).rounded()
      RoundedRectangle(cornerRadius: tile * 0.32, style: .continuous)
        .fill(env.theme.dark ? Color(.sRGB, red: 247 / 255, green: 245 / 255, blue: 1, opacity: 0.2) : Color(.sRGB, red: 0, green: 0, blue: 0, opacity: 0.13))
        .frame(width: tile, height: tile)
        .overlay(
          Text(initial)
            .font(.system(size: (tile * 0.64).rounded(), weight: .semibold))
            .foregroundStyle(env.theme.textSecondary.color)
        )
        .frame(width: size, height: size)
    }
  }

  private func hostInitial(_ url: String) -> String {
    guard let match = url.range(of: "^(?:https?|ftp)://(?:[^@/?#]*@)?([^/?#:]+)", options: [.regularExpression, .caseInsensitive]) else { return "" }
    var rest = String(url[match])
    if let slashes = rest.range(of: "://") { rest = String(rest[slashes.upperBound...]) }
    if let at = rest.lastIndex(of: "@") { rest = String(rest[rest.index(after: at)...]) }
    let host = rest.lowercased()
    if host.range(of: "^[\\d.]+$|^\\[", options: .regularExpression) != nil { return "" }
    var shown = displayHost(host)
    if shown.hasPrefix("www.") { shown.removeFirst(4) }
    return shown.first.map { String($0).uppercased() } ?? ""
  }
}

struct SuggestionIconView: View {
  @Environment(\.newTab) private var env
  let suggestion: SolaraOmnibox.Suggestion
  var color: Color?

  var body: some View {
    let tint = color ?? env.theme.textSecondary.color
    let box = CGSize(width: 16, height: 16)
    switch suggestion {
    case .page(let url, _, let favicon, _, _, _):
      NewTabFavicon(url: url, favicon: favicon)
    case .create(_, _, _, let site):
      NewTabFavicon(url: "https://\(site)")
    case .search:
      SymbolImage(name: "magnifyingglass", size: 13, color: tint, box: box)
    case .calc:
      SymbolImage(name: "equal.circle", size: 14, color: tint, box: box)
    case .action(_, _, let icon, _):
      SymbolImage(name: icon ?? "command", size: 13, color: tint, box: box)
    case .extension(_, _, let icon, _):
      if let icon, let url = URL(string: icon), let image = NSImage(contentsOf: url) {
        Image(nsImage: image).resizable().frame(width: 16, height: 16)
      } else {
        SymbolImage(name: "puzzlepiece.extension", size: 13, color: tint, box: box)
      }
    }
  }
}

func suggestionLabels(_ s: SolaraOmnibox.Suggestion) -> (String, String?) {
  switch s {
  case .page(let url, let title, _, let tabId, _, _):
    if let tabId, !tabId.isEmpty { return (title.isEmpty ? displayUrl(url) : title, "Switch to Tab") }
    return title.isEmpty ? (displayUrl(url), nil) : (title, displayUrl(url))
  case .search(let query, _, let engine, _, let bang):
    return (bang ? "Search \(engine) for \(query)" : query, nil)
  case .calc(let expression, let value, _):
    return (value, expression)
  case .action(_, let title, _, _), .create(_, let title, _, _):
    return (title, nil)
  case .extension(_, let title, _, let open):
    return (title, open == .action ? "Open Extension" : "Extension Options")
  }
}

func isRemovable(_ s: SolaraOmnibox.Suggestion?) -> String? {
  if case .page(let url, _, _, let tabId, _, let visited)? = s, visited, tabId?.isEmpty ?? true { return url }
  return nil
}

struct HoverButtonStyle: ButtonStyle {
  func makeBody(configuration: Configuration) -> some View { configuration.label.contentShape(Rectangle()) }
}

struct SuggestionRowView: View {
  @Environment(\.newTab) private var env
  @State private var hovered = false
  let suggestion: SolaraOmnibox.Suggestion
  let selected: Bool
  let trailing: String?
  let model: HeroBarModel
  var pointerMoved = true

  var body: some View {
    let (title, accessory) = suggestionLabels(suggestion)
    let showsHover = hovered && pointerMoved
    let hintText: String? = {
      if let trailing { return trailing }
      if case .action(_, _, _, let hint) = suggestion { return hint }
      return nil
    }()
    let removeUrl = isRemovable(suggestion)
    let removable = removeUrl != nil && (showsHover || selected)
    Button { model.chooseRow(suggestion) } label: {
      HStack(spacing: 11) {
        SuggestionIconView(suggestion: suggestion)
        (Text(title).foregroundStyle(env.theme.textPrimary.color)
          + Text(accessory.map { " — \($0)" } ?? "").foregroundStyle(env.theme.textSecondary.color))
          .font(.system(size: 14))
          .lineLimit(1)
          .layoutPriority(-1)
        Spacer(minLength: 0)
        if let hintText, !removable {
          Text(hintText).font(.system(size: 12)).foregroundStyle(env.theme.textTertiary.color)
        }
        if removable, let removeUrl {
          IconButtonView(icon: "xmark", size: 10, box: 22, radius: 6, color: env.theme.textSecondary.color, tooltip: "Remove from History") {
            model.removeRow(removeUrl)
          }
        }
      }
      .padding(.horizontal, 13)
      .frame(height: 35)
      .frame(maxWidth: .infinity, alignment: .leading)
      .background(
        RoundedRectangle(cornerRadius: 11)
          .fill(selected ? env.theme.commandBarSelected.color : showsHover ? env.theme.commandBarHover.color : .clear)
      )
    }
    .buttonStyle(HoverButtonStyle())
    .onHover { hovered = $0 }
    .padding(.vertical, 2.5)
  }
}

struct IconButtonView: View {
  @Environment(\.newTab) private var env
  @State private var hovered = false
  let icon: String
  var size: CGFloat = 15
  var box: CGFloat = 30
  var radius: CGFloat = 7
  var weight: Font.Weight = .regular
  let color: Color
  var tooltip: String?
  let action: () -> Void

  var body: some View {
    Button(action: action) {
      SymbolImage(name: icon, size: size, weight: weight, color: color, box: CGSize(width: box, height: box))
        .background(RoundedRectangle(cornerRadius: radius).fill(hovered ? env.theme.toolbarHover.color : .clear))
    }
    .buttonStyle(PressTintStyle(radius: radius, pressed: env.theme.toolbarPressed.color))
    .onHover { hovered = $0 }
    .help(tooltip ?? "")
  }
}

struct PressTintStyle: ButtonStyle {
  let radius: CGFloat
  let pressed: Color

  func makeBody(configuration: Configuration) -> some View {
    configuration.label
      .background(RoundedRectangle(cornerRadius: radius).fill(configuration.isPressed ? pressed : .clear))
      .contentShape(Rectangle())
  }
}

struct ScopeChipView: View {
  @Environment(\.newTab) private var env
  let scope: SearchScope
  var large = true

  var body: some View {
    HStack(spacing: 6) {
      NewTabFavicon(url: "https://\(scope.host)", size: 14)
      Text(scope.name)
        .font(.system(size: large ? 15 : 14, weight: .medium))
        .foregroundStyle(env.theme.textPrimary.color)
        .lineLimit(1)
        .frame(maxWidth: 220, alignment: .leading)
        .fixedSize(horizontal: true, vertical: false)
    }
    .padding(.leading, 7)
    .padding(.trailing, 9)
    .frame(height: large ? 28 : 26)
    .background(RoundedRectangle(cornerRadius: 8).fill(env.theme.rowSelected.color))
  }
}

struct AddChipView: View {
  @Environment(\.newTab) private var env
  @State private var hovered = false
  let action: () -> Void

  var body: some View {
    Button(action: action) {
      HStack(spacing: 5) {
        SymbolImage(name: "arrow.up.right", size: 10, weight: .medium, color: env.theme.chipText.color, box: CGSize(width: 14, height: 14))
        Text("Open a tab or file").font(.system(size: 13)).foregroundStyle(env.theme.chipText.color)
      }
      .padding(.leading, 10)
      .padding(.trailing, 13)
      .frame(height: 32)
      .fixedSize()
      .background(Capsule(style: .circular).fill(hovered ? env.theme.rowHover.color : .clear))
      .overlay(Capsule(style: .circular).strokeBorder(env.theme.chipBorder.color, lineWidth: 1))
    }
    .buttonStyle(HoverButtonStyle())
    .onHover { hovered = $0 }
  }
}

struct GoButtonView: View {
  @Environment(\.newTab) private var env
  @State private var hovered = false
  let label: String
  let enabled: Bool
  let action: () -> Void

  var body: some View {
    let text = enabled ? env.theme.goButtonText : env.theme.textTertiary
    let symbol = enabled ? text.withAlpha(Double(0x99) / 255) : text
    Button(action: action) {
      HStack(spacing: 6) {
        Text(label).font(.system(size: 15, weight: .semibold)).foregroundStyle(text.color).lineLimit(1)
        SymbolImage(name: "return", size: 11, weight: .medium, color: symbol.color, box: CGSize(width: 14, height: 14))
      }
      .padding(.horizontal, 16)
      .frame(minWidth: 99)
      .frame(height: 32)
      .background(Capsule(style: .circular).fill(enabled ? env.theme.goButton.color : env.theme.goButtonIdle.color))
      .opacity(enabled && hovered ? 0.9 : 1)
    }
    .buttonStyle(HoverButtonStyle())
    .disabled(!enabled)
    .onHover { hovered = $0 }
    .accessibilityLabel(label)
    .padding(.leading, 8)
  }
}

struct HeroBarContent: View {
  @Environment(\.newTab) private var env
  @State private var pointer = ListPointer()
  let model: HeroBarModel
  var onHeight: (CGFloat) -> Void = { _ in }

  var body: some View {
    VStack(spacing: 0) {
      HStack(spacing: 8) {
        leadingIcon.frame(width: 18)
        if let scope = model.scope { ScopeChipView(scope: scope) }
        HeroFieldView(model: model, theme: env.theme).accessibilityLabel(model.placeholder).padding(.leading, 2)
      }
      .padding(.leading, 18)
      .padding(.trailing, 18)
      .frame(height: 60)
      .contentShape(Rectangle())
      if !model.listAway && !model.items.isEmpty {
        VStack(spacing: 0) {
          ForEach(Array(model.items.enumerated()), id: \.offset) { i, s in
            SuggestionRowView(
              suggestion: s, selected: i == model.selectedIndex, trailing: i == 0 ? model.trailingHint : nil, model: model,
              pointerMoved: pointer.moved)
          }
        }
        .onContinuousHover(coordinateSpace: .global) { phase in
          switch phase {
          case .active(let point): pointer.observe(point)
          case .ended: pointer.leave()
          }
        }
        .onChange(of: model.items) { pointer.listChanged() }
        .padding(.horizontal, 9)
        .padding(.bottom, 2)
      }
      HStack(spacing: 0) {
        AddChipView { model.events.openChip() }
        Spacer(minLength: 0)
        IconButtonView(icon: "mic", size: 14, color: env.theme.textTertiary.color, tooltip: "Dictate") { model.dictatePressed() }
        GoButtonView(label: model.goLabel, enabled: model.goEnabled) { model.goPressed() }
      }
      .padding(.leading, 13)
      .padding(.trailing, 15)
      .frame(height: 43)
      .padding(.bottom, 8)
    }
    .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { onHeight($0) }
  }

  @ViewBuilder private var leadingIcon: some View {
    if let s = model.leadingSuggestion {
      SuggestionIconView(suggestion: s, color: env.theme.textPrimary.color)
    } else {
      SymbolImage(
        name: model.incognito ? "eyeglasses" : "magnifyingglass", size: 15, weight: .medium, color: env.theme.textSecondary.color,
        box: CGSize(width: 18, height: 18))
    }
  }
}

struct IncognitoHeadingView: View {
  @Environment(\.newTab) private var env
  var onHeight: (CGFloat) -> Void = { _ in }

  var body: some View {
    VStack(spacing: 6) {
      HStack(spacing: 10) {
        SymbolImage(name: "eyeglasses", size: 24, weight: .medium, color: env.theme.textPrimary.color, box: CGSize(width: 32, height: 28))
        Text("Incognito")
          .font(.system(size: 30, weight: .bold))
          .kerning(-0.4)
          .foregroundStyle(env.theme.textPrimary.color)
          .lineLimit(1)
          .accessibilityAddTraits(.isHeader)
      }
      Text("Pages you visit here aren't saved to your history. Cookies and site data are deleted when you close all Incognito windows.")
        .font(.system(size: 13))
        .lineSpacing(18 - NSFont.systemFont(ofSize: 13).lineHeight)
        .padding(.vertical, (18 - NSFont.systemFont(ofSize: 13).lineHeight) / 2)
        .foregroundStyle(env.theme.textSecondary.color)
        .multilineTextAlignment(.center)
        .frame(maxWidth: 460)
        .fixedSize(horizontal: false, vertical: true)
    }
    .frame(maxWidth: .infinity)
    .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { onHeight($0) }
    .allowsHitTesting(false)
  }
}

extension NSFont {
  var lineHeight: CGFloat { ceil(ascender - descender + leading) }
}

struct ListPointer {
  private(set) var moved = false
  private var resting: CGPoint?
  private var last: CGPoint?

  mutating func observe(_ point: CGPoint) {
    defer { last = point }
    if moved { return }
    guard let resting else {
      self.resting = point
      return
    }
    if point != resting { moved = true }
  }

  mutating func leave() {
    moved = false
    resting = nil
    last = nil
  }

  mutating func listChanged() {
    moved = false
    resting = last
  }
}
