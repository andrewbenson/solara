import AppKit
import SolaraOmnibox
import SwiftUI

public enum OmniboxBarMetrics {
  public static let panelTextLeft: CGFloat = 48
  public static let panelIconLeft: CGFloat = 21
  public static let fieldTextInset: CGFloat = 2.5
  public static let panelRow: CGFloat = 55
  public static let dropdownRow: CGFloat = 44
  public static let panelBottomRow: CGFloat = 52
  public static let suggestionTextSize: CGFloat = 14
  public static let panelTextSize: CGFloat = 13

  static var panelGap: CGFloat { panelTextLeft - fieldTextInset - panelIconLeft - 18 }
}

struct OmniboxBarContent: View {
  @Environment(\.newTab) private var env
  let model: HeroBarModel
  let floating: Bool
  var onHeight: (CGFloat) -> Void = { _ in }

  var body: some View {
    VStack(spacing: 0) {
      if model.variant == .sidebar { dropdownField } else { panelField }
      if !model.items.isEmpty {
        VStack(spacing: 0) {
          ForEach(Array(model.items.enumerated()), id: \.offset) { i, s in
            SuggestionRowView(suggestion: s, selected: i == model.selectedIndex, trailing: i == 0 ? model.trailingHint : nil, model: model)
          }
        }
        .padding(.horizontal, model.variant == .sidebar ? 6 : 9)
        .padding(.bottom, model.variant == .sidebar ? 6 : 2)
      }
      if model.variant != .sidebar { bottomRow }
    }
    .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { onHeight($0) }
  }

  private var panelField: some View {
    HStack(spacing: OmniboxBarMetrics.panelGap) {
      leadingIcon.frame(width: 18)
      if let scope = model.scope { ScopeChipView(scope: scope, large: false) }
      HeroFieldView(model: model, theme: env.theme, fontSize: floating ? OmniboxBarMetrics.suggestionTextSize : OmniboxBarMetrics.panelTextSize)
        .padding(.leading, OmniboxBarMetrics.fieldTextInset)
        .padding(.top, -3)
    }
    .padding(.leading, OmniboxBarMetrics.panelIconLeft)
    .padding(.trailing, 18)
    .frame(height: OmniboxBarMetrics.panelRow)
    .contentShape(Rectangle())
  }

  private var dropdownField: some View {
    HStack(spacing: 9) {
      leadingIcon.frame(width: 18)
      if let scope = model.scope { ScopeChipView(scope: scope, large: false) }
      HeroFieldView(model: model, theme: env.theme, fontSize: OmniboxBarMetrics.suggestionTextSize)
        .padding(.leading, OmniboxBarMetrics.fieldTextInset)
      if !model.currentUrl.isEmpty {
        IconButtonView(icon: "info.circle", size: 15, box: 26, radius: 13, color: env.theme.textSecondary.color, tooltip: "Site Controls") {
          model.events.siteControls()
        }
      }
    }
    .padding(.leading, 13)
    .padding(.trailing, 9)
    .frame(height: OmniboxBarMetrics.dropdownRow)
    .contentShape(Rectangle())
  }

  private var bottomRow: some View {
    HStack(spacing: 0) {
      AddChipView { model.events.openChip() }
      Spacer(minLength: 0)
      IconButtonView(icon: "mic", size: 14, color: Color(nsColor: .secondaryLabelColor), tooltip: "Dictate") { model.dictatePressed() }
      GoButtonView(label: model.goLabel, enabled: model.goEnabled) { model.goPressed() }
    }
    .padding(.leading, 14)
    .padding(.trailing, 13)
    .frame(height: OmniboxBarMetrics.panelBottomRow)
  }

  @ViewBuilder private var leadingIcon: some View {
    if let s = model.leadingSuggestion {
      SuggestionIconView(suggestion: s, color: env.theme.textPrimary.color)
    } else {
      SymbolImage(
        name: model.incognito ? "eyeglasses" : "magnifyingglass", size: 15, weight: .medium, color: env.theme.textPrimary.color,
        box: CGSize(width: 18, height: 18))
    }
  }
}
