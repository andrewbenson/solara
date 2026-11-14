import SwiftUI

public enum PersonalizeCopy {
  public static let title = "Make it yours"
  public static let subtitle = "Pick the theme color and layout that feel right for you."
  public static let layouts = "Choose how you would like to view your tabs:"
}

public struct ThemeColorPicker: View {
  let current: ProfileColorValue?
  let size: CGFloat
  let onPick: (ProfileColorValue) -> Void

  public init(current: ProfileColorValue?, size: CGFloat = 30, onPick: @escaping (ProfileColorValue) -> Void) {
    self.current = current
    self.size = size
    self.onPick = onPick
  }

  public var body: some View {
    let gap: CGFloat = size >= 30 ? 8 : 6
    LazyVGrid(columns: [GridItem(.adaptive(minimum: size, maximum: size), spacing: gap)], alignment: .leading, spacing: gap) {
      ForEach(ProfileColorValue.allCases, id: \.self) { color in
        ColorDot(color: color, size: size, selected: current == color) { onPick(color) }
      }
    }
    .accessibilityElement(children: .contain)
    .accessibilityLabel("Theme color")
  }
}

struct ColorDot: View {
  let color: ProfileColorValue
  let size: CGFloat
  let selected: Bool
  let action: () -> Void
  @State private var shown: Double

  init(color: ProfileColorValue, size: CGFloat, selected: Bool, action: @escaping () -> Void) {
    self.color = color
    self.size = size
    self.selected = selected
    self.action = action
    _shown = State(initialValue: selected ? 1 : 0)
  }

  var body: some View {
    let swatch = PreviewColor.color(color.swatch)
    PersonalizePressable(title: color.name, selected: selected, action: action) { hovered, pressed in
      let rest = size - (hovered ? 6 : 8)
      let inner = rest + (size - 12 - rest) * shown
      ZStack {
        Circle().strokeBorder(swatch, lineWidth: 2).opacity(shown)
        Circle().fill(swatch).frame(width: inner, height: inner).opacity(hovered || selected ? 1 : 0.85)
      }
      .frame(width: size, height: size)
      .scaleEffect(pressed ? 0.94 : 1)
      .contentShape(Circle())
    }
    .help(color.name)
    .onChange(of: selected) { _, on in withAnimation(.rn(160, .outQuad)) { shown = on ? 1 : 0 } }
  }
}

public struct TabLayoutPicker: View {
  let layout: String
  let onPick: (String) -> Void

  public init(layout: String, onPick: @escaping (String) -> Void) {
    self.layout = layout
    self.onPick = onPick
  }

  public var body: some View {
    HStack(alignment: .top, spacing: 10) {
      LayoutButton(kind: "sidebar", title: "Sidebar", subtitle: "Tabs down the side", selected: layout == "sidebar") { if layout != "sidebar" { onPick("sidebar") } }
      LayoutButton(kind: "top", title: "Classic", subtitle: "Tabs along the top", selected: layout == "top") { if layout != "top" { onPick("top") } }
    }
    .accessibilityElement(children: .contain)
    .accessibilityLabel("Tab layout")
  }
}

struct LayoutButton: View {
  @Environment(\.colorScheme) private var scheme
  let kind: String
  let title: String
  let subtitle: String
  let selected: Bool
  let action: () -> Void

  var body: some View {
    let colors = OnboardingColors.of(scheme)
    PersonalizePressable(title: title, selected: selected, action: action) { hovered, pressed in
      VStack(alignment: .leading, spacing: 10) {
        GeometryReader { proxy in
          let inner = proxy.size.width - 12
          let card = RoundedRectangle(cornerRadius: 4).fill(colors.card).overlay(RoundedRectangle(cornerRadius: 4).strokeBorder(colors.previewBorder, lineWidth: 1))
          Group {
            if kind == "sidebar" {
              HStack(alignment: .top, spacing: 4) {
                VStack(alignment: .leading, spacing: 3) {
                  ForEach(Array([1.0, 0.8, 0.9].enumerated()), id: \.offset) { i, w in
                    RoundedRectangle(cornerRadius: 2).fill(colors.progressTrack).frame(width: inner * 0.26 * w, height: 5).opacity(i == 0 ? 1 : 0.6)
                  }
                }
                .padding(.top, 7)
                .frame(width: inner * 0.26, alignment: .leading)
                card
              }
            } else {
              VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 3) {
                  ForEach(0..<3, id: \.self) { i in
                    RoundedRectangle(cornerRadius: 2).fill(colors.progressTrack).frame(width: (inner - 12) * 0.22, height: 7).opacity(i == 0 ? 1 : 0.6)
                  }
                }
                .padding(.leading, 12)
                card
              }
            }
          }
          .padding(6)
        }
        .frame(height: 64)
        .background(RoundedRectangle(cornerRadius: 7).fill(colors.preview))
        .overlay(RoundedRectangle(cornerRadius: 7).strokeBorder(colors.previewBorder, lineWidth: 1))
        HStack(spacing: 8) {
          OnboardingRadio(on: selected)
          VStack(alignment: .leading, spacing: 0) {
            OnboardingText(title, size: 12.5, weight: 500, color: colors.title)
            OnboardingText(subtitle, size: 11, color: colors.rowSubtitle)
          }
          .frame(maxWidth: .infinity, alignment: .leading)
        }
      }
      .padding(selected ? 11.5 : 11)
      .background(RoundedRectangle(cornerRadius: 12).fill(hovered || selected ? colors.button : colors.row))
      .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(selected ? colors.title : colors.rowBorder, lineWidth: selected ? 1.5 : 1))
      .scaleEffect(pressed ? 0.98 : 1)
      .contentShape(Rectangle())
    }
    .frame(maxWidth: .infinity)
  }
}
