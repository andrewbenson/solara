import AppKit
import Observation
import SwiftUI

public struct AppIconChoice: Identifiable, Equatable, @unchecked Sendable {
  public let id: String
  public let name: String
  public let preview: NSImage?

  public init(id: String, name: String, preview: NSImage?) {
    self.id = id
    self.name = name
    self.preview = preview
  }
}

@MainActor
public protocol AppearanceServices: AnyObject {
  func appIcons(size: CGFloat) async -> (icons: [AppIconChoice], current: String?)
  func setAppIcon(_ id: String) async
  func setAppearance(_ mode: String) async
}

@MainActor
@Observable
public final class AppearancePaneModel: SettingsPaneProvider {
  public static let appIconSize: CGFloat = 56

  @ObservationIgnored let services: AppearanceServices
  @ObservationIgnored let store: SettingsStoreSource
  var icons: [AppIconChoice] = []
  var currentIcon: String?
  var iconsLoaded = false

  public init(services: AppearanceServices, store: SettingsStoreSource) {
    self.services = services
    self.store = store
  }

  public func isLoaded(_ place: SettingsPlace) -> Bool { iconsLoaded }

  public func prepare(_ place: SettingsPlace) async {
    let loaded = await services.appIcons(size: Self.appIconSize)
    icons = loaded.icons
    currentIcon = loaded.current
    iconsLoaded = true
  }

  public func view(_ place: SettingsPlace) -> AnyView { AnyView(AppearancePane(model: self)) }

  func chooseAppearance(_ mode: String) {
    store.set("appearance", mode)
    Task { await services.setAppearance(mode) }
  }

  func chooseIcon(_ id: String) {
    currentIcon = id
    Task { await services.setAppIcon(id) }
  }

  static let modes: [(value: String, title: String, description: String)] = [
    ("auto", "Automatic", "Follow the system appearance setting"),
    ("light", "Light", "Use the light application appearance"),
    ("dark", "Dark", "Use the dark application appearance"),
  ]

  static func addressBarDescription(topTabs: Bool) -> String {
    topTabs
      ? "With tabs across the top, the address bar stays in the toolbar."
      : "Putting the address bar in the sidebar gives pages more height. It returns to the toolbar when the sidebar is hidden."
  }
}

struct AppearancePane: View {
  let model: AppearancePaneModel

  var body: some View {
    let store = model.store
    let appearance = store.string("appearance")
    let addressBar = store.string("addressBar")
    SettingsForm {
      Section {
        SettingToggle("appearance.spacesFollowAppearance", key: "spacesFollowAppearance")
      } header: {
        VStack(alignment: .leading, spacing: 14) {
          SettingsSectionHeader(description: "Also in View › Appearance. Incognito windows are always dark.", anchor: "appearance.theme")
          HStack(spacing: 14) {
            ForEach(AppearancePaneModel.modes, id: \.value) { mode in
              SettingsChoiceCard(title: mode.title, selected: appearance == mode.value, help: mode.description, action: { model.chooseAppearance(mode.value) }) {
                ModePreview(mode: mode.value)
              }
            }
          }
          .padding(.bottom, 2)
        }
      }

      Section {
        SettingRow("appearance.commandBarPlacement") {
          SettingPicker([SettingOption("field", "At the address"), SettingOption("centred", "In the centre")], selection: store.choice("commandBarPlacement"))
        }
      } header: {
        VStack(alignment: .leading, spacing: 14) {
          SettingsSectionHeader(description: AppearancePaneModel.addressBarDescription(topTabs: store.topTabLayout), anchor: "appearance.addressBar")
          HStack(spacing: 14) {
            SettingsChoiceCard(title: "In the toolbar", selected: addressBar != "sidebar", action: { store.set("addressBar", "toolbar") }) {
              AddressBarPreview(sidebar: false)
            }
            SettingsChoiceCard(title: "In the sidebar", selected: addressBar == "sidebar", action: { store.set("addressBar", "sidebar") }) {
              AddressBarPreview(sidebar: true)
            }
          }
          .padding(.bottom, 2)
        }
      }

      SettingsSection("Scroll Bars") {
        SettingRow("appearance.pageScrollBars") {
          SettingPicker([SettingOption("system", "Follow macOS"), SettingOption("thin", "Thin")], selection: store.choice("pageScrollBars"))
        }
      }

      if model.icons.count >= 2 {
        Section {
        } header: {
          VStack(alignment: .leading, spacing: 10) {
            SettingsSectionHeader(description: "Shown in the Dock and the app switcher. The Dock keeps it after you quit.", anchor: "appearance.appIcon")
            AppIconGrid(model: model)
          }
        }
      }
    }
  }
}

struct AppIconGrid: View {
  let model: AppearancePaneModel

  var body: some View {
    LazyVGrid(columns: [GridItem(.adaptive(minimum: 72, maximum: 72), spacing: 6, alignment: .top)], alignment: .leading, spacing: 10) {
      ForEach(model.icons) { icon in
        AppIconTile(icon: icon, selected: icon.id == model.currentIcon) { model.chooseIcon(icon.id) }
      }
    }
  }
}

struct AppIconTile: View {
  let icon: AppIconChoice
  let selected: Bool
  let action: () -> Void
  @State private var hovered = false

  var body: some View {
    Button(action: action) {
      VStack(spacing: 5) {
        ZStack {
          RoundedRectangle(cornerRadius: 16)
            .fill(hovered && !selected ? Color.primary.opacity(0.08) : Color.clear)
          if let preview = icon.preview {
            Image(nsImage: preview)
              .resizable()
              .frame(width: AppearancePaneModel.appIconSize, height: AppearancePaneModel.appIconSize)
          }
        }
        .frame(width: 70, height: 70)
        .overlay {
          RoundedRectangle(cornerRadius: 16).strokeBorder(selected ? Color.accentColor : Color.clear, lineWidth: 2.5)
        }
        HStack(spacing: 4) {
          if selected {
            Image(systemName: "checkmark.circle.fill")
              .font(.system(size: 11))
              .foregroundStyle(Color.accentColor)
          }
          Text(icon.name)
            .font(.system(size: 12))
            .foregroundStyle(selected ? .primary : .secondary)
            .lineLimit(1)
        }
      }
      .frame(width: 72)
      .contentShape(Rectangle())
    }
    .buttonStyle(.plain)
    .onHover { hovered = $0 }
    .help(icon.name)
  }
}

struct ModePreview: View {
  let mode: String

  var body: some View {
    HStack(spacing: 0) {
      if mode == "auto" {
        window(dark: false)
        window(dark: true)
      } else {
        window(dark: mode == "dark")
      }
    }
  }

  private func window(dark: Bool) -> some View {
    GeometryReader { geometry in
      HStack(alignment: .top, spacing: 5) {
        VStack(spacing: 3) {
          ForEach(0..<3, id: \.self) { _ in
            RoundedRectangle(cornerRadius: 2.5)
              .fill(dark ? Color.white.opacity(0.2) : Color.black.opacity(0.12))
              .frame(height: 5)
          }
        }
        .padding(.top, 8)
        .frame(width: (geometry.size.width - 12) * 0.24)
        RoundedRectangle(cornerRadius: 4)
          .fill(dark ? Color(red: 0x1A / 255, green: 0x16 / 255, blue: 0x18 / 255) : Color.white)
      }
      .padding(6)
    }
    .background(dark ? Color(red: 0x2B / 255, green: 0x22 / 255, blue: 0x26 / 255) : Color(red: 0xED / 255, green: 0xE6 / 255, blue: 0xEA / 255))
  }
}

struct AddressBarPreview: View {
  @Environment(\.colorScheme) private var scheme
  let sidebar: Bool

  var body: some View {
    let bar = SettingsPreviewColors.bar(scheme)
    let field = SettingsPreviewColors.field(scheme)
    GeometryReader { geometry in
      HStack(alignment: .top, spacing: 5) {
        VStack(spacing: 3) {
          if sidebar {
            RoundedRectangle(cornerRadius: 3)
              .fill(field)
              .overlay { RoundedRectangle(cornerRadius: 3).strokeBorder(Color.accentColor, lineWidth: 1) }
              .frame(height: 8)
              .padding(.bottom, 2)
          }
          ForEach(0..<3, id: \.self) { _ in
            RoundedRectangle(cornerRadius: 2.5).fill(bar).frame(height: 5)
          }
        }
        .padding(.top, sidebar ? 3 : 8)
        .frame(width: (geometry.size.width - 12) * 0.28)
        VStack(spacing: 0) {
          if !sidebar {
            HStack(spacing: 5) {
              RoundedRectangle(cornerRadius: 2).fill(bar).frame(width: 14, height: 4)
              RoundedRectangle(cornerRadius: 2.5)
                .fill(field)
                .overlay { RoundedRectangle(cornerRadius: 2.5).strokeBorder(Color.accentColor, lineWidth: 1) }
                .frame(height: 7)
            }
            .padding(.horizontal, 5)
            .frame(height: 13)
            Rectangle().fill(field).frame(height: 1)
          }
          Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(SettingsPreviewColors.page(scheme))
        .clipShape(RoundedRectangle(cornerRadius: 4))
      }
      .padding(6)
    }
    .background(SettingsPreviewColors.window(scheme))
  }
}
