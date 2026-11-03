import SolaraModel
import SwiftUI

@MainActor
public final class TabsPaneModel: SettingsPaneProvider {
  let store: SettingsStoreSource

  public init(store: SettingsStoreSource) {
    self.store = store
  }

  public func isLoaded(_ place: SettingsPlace) -> Bool { true }
  public func prepare(_ place: SettingsPlace) async {}
  public func view(_ place: SettingsPlace) -> AnyView { AnyView(TabsPane(store: store)) }

  static let peekModifiers = ["alt", "shift", "off"]

  static func peekModifier(_ store: SettingsStoreSource) -> String {
    let value = store.string("peekModifier")
    return peekModifiers.contains(value) ? value : "shift"
  }

  static func splitLinkModifier(_ store: SettingsStoreSource) -> String {
    store.string("splitLinkModifier") == "alt" && peekModifier(store) != "alt" ? "alt" : "altShift"
  }

  static func peekOptions(splitWith: String) -> [SettingOption] {
    [
      SettingOption("shift", "⇧-click"),
      SettingOption("alt", splitWith == "alt" ? "⌥-click (split view moves to ⌥⇧-click)" : "⌥-click"),
      SettingOption("off", "Off"),
    ]
  }

  static func splitOptions(peekWith: String) -> [SettingOption] {
    [
      SettingOption("altShift", "⌥⇧-click"),
      SettingOption("alt", peekWith == "alt" ? "⌥-click (Peek moves to ⇧-click)" : "⌥-click"),
    ]
  }

  static func newTabPositions(top: Bool) -> [SettingOption] {
    top
      ? [SettingOption("bottom", "On the right"), SettingOption("top", "On the left"), SettingOption("nextToCurrent", "Next to the current tab")]
      : [SettingOption("bottom", "At the bottom"), SettingOption("top", "At the top"), SettingOption("nextToCurrent", "Below the current tab")]
  }

  static let newTabButtonPositions = [SettingOption("bottom", "At the bottom"), SettingOption("top", "At the top")]

  static let cleanUpChoices = [
    SettingOption("12", "12 hours"),
    SettingOption("24", "24 hours"),
    SettingOption("168", "7 days"),
    SettingOption("720", "30 days"),
  ]

  static func cleanUpHours(_ store: SettingsStoreSource) -> Int? {
    store.settingValue("cleanUpInactiveTabsAfterHours")?.int
  }
}

struct TabsPane: View {
  @Environment(\.settingsContext) private var context
  let store: SettingsStoreSource

  var body: some View {
    let top = store.topTabLayout
    SettingsForm {
      Section {
        SettingToggle("tabs.hideToolbarWhileScrolling", key: "hideToolbarWhileScrolling")
        if !top {
          SettingToggle("tabs.showSidebarButton", key: "showSidebarButton")
          SettingToggle("tabs.showClearButton", key: "showClearButton")
          SettingToggle("tabs.balancedTopApps", key: "balancedTopApps")
        }
        SettingToggle("tabs.classicPinnedTabs", key: "classicPinnedTabs", inverted: true)
        SettingToggle("tabs.fadeUnloadedTabs", key: "fadeUnloadedTabs")
      } header: {
        VStack(alignment: .leading, spacing: 14) {
          SettingsSectionHeader(anchor: "tabs.layout")
          HStack(spacing: 14) {
            TabLayoutChoice(layout: "sidebar", title: "Tab layout in the sidebar", selected: !top) { store.chooseTabLayout("sidebar") }
            TabLayoutChoice(layout: "top", title: "Tab layout across the top of the window", selected: top) { store.chooseTabLayout("top") }
          }
          .padding(.bottom, 2)
        }
      }

      SettingsSection("General") {
        SettingRow("tabs.newTabOpens") {
          SettingPicker([SettingOption("page", "New Tab Page"), SettingOption("commandBar", "Command Bar")], selection: store.choice("newTabOpens"))
        }
        SettingRow("tabs.newTabPosition") {
          SettingPicker(TabsPaneModel.newTabPositions(top: top), selection: store.choice("newTabPosition"))
        }
        if !top {
          SettingRow("tabs.newTabButtonPosition") {
            SettingPicker(TabsPaneModel.newTabButtonPositions, selection: store.choice("newTabButtonPosition"))
          }
        }
        SettingToggle("tabs.shareTabsAcrossWindows", key: "shareTabsAcrossWindows")
        SettingToggle("tabs.tabReorderHaptics", key: "tabReorderHaptics")
        SettingToggle("tabs.extendWebsiteColor", key: "extendWebsiteColor")
        SettingToggle("tabs.sidebarMediaControls", key: "sidebarMediaControls")
        SettingToggle("tabs.autoPictureInPicture", key: "autoPictureInPicture")
        SettingToggle("tabs.videoUpscaling", key: "videoUpscaling")
      }

      SettingsSection("Links") {
        LinkKeys(store: store)
      }

      SettingsSection("Tab groups") {
        SettingToggle("tabs.warnBeforeClosingTabGroup", key: "warnBeforeClosingTabGroup")
        SettingToggle("tabs.cmdClickCreatesTabGroup", key: "cmdClickCreatesTabGroup")
        SettingToggle("tabs.optShiftClickOpensInGroup", key: "optShiftClickOpensInGroup")
        SettingToggle("tabs.autoGroupMeetingTabs", key: "autoGroupMeetingTabs")
      }

      SettingsSection(
        "Clean up",
        description: "Closes unused and duplicate tabs. Pinned, playing and selected tabs stay. Find closed tabs in Recently Cleaned."
      ) {
        CleanUpRow(store: store)
      }
    }
  }
}

struct LinkKeys: View {
  let store: SettingsStoreSource

  var body: some View {
    let peekWith = TabsPaneModel.peekModifier(store)
    let splitWith = TabsPaneModel.splitLinkModifier(store)
    SettingRow(
      "tabs.peekModifier",
      description: splitWith == "alt" ? .text("⌥-click is currently used for split view.") : .index
    ) {
      SettingPicker(TabsPaneModel.peekOptions(splitWith: splitWith), selection: Binding(get: { peekWith }, set: { store.set("peekModifier", $0) }))
    }
    SettingRow(
      "tabs.splitLinkModifier",
      description: peekWith == "alt" ? .text("⌥-click is currently used for Peek.") : .index
    ) {
      SettingPicker(TabsPaneModel.splitOptions(peekWith: peekWith), selection: Binding(get: { splitWith }, set: { store.set("splitLinkModifier", $0) }))
    }
  }
}

struct CleanUpRow: View {
  let store: SettingsStoreSource

  var body: some View {
    let hours = TabsPaneModel.cleanUpHours(store)
    SettingsAnchor("tabs.cleanUp") {
      LabeledContent {
        SettingPicker(
          TabsPaneModel.cleanUpChoices,
          selection: Binding(get: { String(hours ?? 24) }, set: { store.updateSettings(["cleanUpInactiveTabsAfterHours": .number(Double($0) ?? 24)]) })
        )
        .disabled(hours == nil)
      } label: {
        HStack(spacing: 7) {
          Toggle("", isOn: Binding(
            get: { hours != nil },
            set: { store.updateSettings(["cleanUpInactiveTabsAfterHours": $0 ? .number(24) : .null]) }
          ))
          .labelsHidden()
          .toggleStyle(.checkbox)
          Text("Clean up tabs I haven't used in:")
        }
      }
    }
  }
}

struct TabLayoutChoice: View {
  @Environment(\.colorScheme) private var scheme
  let layout: String
  let title: String
  let selected: Bool
  let action: () -> Void

  var body: some View {
    SettingsChoiceCard(title: title, selected: selected, height: 104, radius: 10, action: action) {
      let bar = SettingsPreviewColors.bar(scheme)
      ZStack {
        SettingsPreviewColors.window(scheme)
        if layout == "sidebar" {
          GeometryReader { geometry in
            HStack(alignment: .top, spacing: 5) {
              VStack(spacing: 4) {
                ForEach(0..<4, id: \.self) { i in
                  RoundedRectangle(cornerRadius: 3).fill(i == 1 ? Color.accentColor : bar).frame(height: 7)
                }
              }
              .padding(.top, 10)
              .frame(width: geometry.size.width * 0.26)
              RoundedRectangle(cornerRadius: 5).fill(SettingsPreviewColors.page(scheme))
            }
          }
          .padding(8)
        } else {
          VStack(spacing: 5) {
            HStack(spacing: 4) {
              ForEach(0..<3, id: \.self) { i in
                RoundedRectangle(cornerRadius: 3).fill(i == 1 ? Color.accentColor : bar)
              }
            }
            .frame(height: 10)
            .padding(.leading, 26)
            RoundedRectangle(cornerRadius: 5).fill(SettingsPreviewColors.page(scheme))
          }
          .padding(8)
        }
      }
    }
  }
}
