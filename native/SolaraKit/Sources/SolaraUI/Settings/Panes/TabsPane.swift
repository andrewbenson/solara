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
  public func view(_ place: SettingsPlace) -> AnyView { AnyView(TabsPane(store: store, detail: place.detail)) }

  static func pinnedLinkTargets(app: String) -> [SettingOption] {
    [SettingOption("tab", "New tab"), SettingOption("peek", "Peek"), SettingOption("littleSolara", "Little \(app)")]
  }

  static func pinnedLinkTarget(_ store: SettingsStoreSource) -> String {
    let value = store.string("pinnedLinkTarget")
    return ["tab", "peek", "littleSolara"].contains(value) ? value : "peek"
  }

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

  static let sleepAfterChoices = [
    SettingOption("15", "15 minutes"),
    SettingOption("30", "30 minutes"),
    SettingOption("60", "1 hour"),
    SettingOption("120", "2 hours"),
    SettingOption("240", "4 hours"),
  ]

  static func sleepAfterMinutes(_ store: SettingsStoreSource) -> Int {
    KeepAwakeSites.sleepAfterMinutes(store.settingValue("sleepTabsAfterMinutes"))
  }

  static func sleepsTabs(_ store: SettingsStoreSource) -> Bool {
    store.settingValue("sleepInactiveTabs")?.bool != false
  }

  static func keepAwakeSites(_ store: SettingsStoreSource) -> [String] {
    KeepAwakeSites.sites(store.settingValue(KeepAwakeSites.settingKey))
  }

  static func keepAwakeSelection(_ detail: String?) -> String? {
    guard let detail, detail.hasPrefix(KeepAwakeSites.detailPrefix) else { return nil }
    return String(detail.dropFirst(KeepAwakeSites.detailPrefix.count))
  }
}

struct TabsPane: View {
  @Environment(\.settingsContext) private var context
  let store: SettingsStoreSource
  var detail: String? = nil

  var body: some View {
    let top = store.topTabLayout
    SettingsForm {
      Section {
        SettingToggle("tabs.hideToolbarWhileScrolling", key: "hideToolbarWhileScrolling")
        if !top {
          SettingToggle("tabs.sidebarIconsOnly", key: "sidebarIconsOnly")
          SettingToggle("tabs.showSidebarButton", key: "showSidebarButton")
          SettingToggle("tabs.showClearButton", key: "showClearButton")
          SettingToggle("tabs.balancedTopApps", key: "balancedTopApps")
        }
        SettingToggle("tabs.classicPinnedTabs", key: "classicPinnedTabs", inverted: true)
        SettingToggle("tabs.fadeUnloadedTabs", key: "fadeUnloadedTabs")
        SettingToggle("tabs.showUnreadBadges", key: "showUnreadBadges")
      } header: {
        VStack(alignment: .leading, spacing: 14) {
          SettingsSectionHeader(anchor: "tabs.layout")
          HStack(spacing: 14) {
            TabLayoutChoice(layout: "sidebar", title: "Tab layout in the sidebar", selected: !top) { store.chooseTabLayout("sidebar") }
            TabLayoutChoice(layout: "top", title: "Tab layout across the top of the window", selected: top) { store.chooseTabLayout("top") }
          }
          .disabled(store.fileSource("tabLayout") != nil)
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
        if !top {
          SettingToggle("tabs.hoverCardMemoryUsage", key: "hoverCardMemoryUsage")
        }
        SettingToggle("tabs.autoPictureInPicture", key: "autoPictureInPicture")
        SettingToggle("tabs.videoUpscaling", key: "videoUpscaling")
      }

      SettingsSection("Links") {
        SettingRow("tabs.pinnedLinkTarget") {
          SettingPicker(
            TabsPaneModel.pinnedLinkTargets(app: context?.appName ?? ""),
            selection: Binding(get: { TabsPaneModel.pinnedLinkTarget(store) }, set: { store.set("pinnedLinkTarget", $0) })
          )
        }
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

      SettingsSection(
        "Sleeping tabs",
        description: "Tabs that are playing sound, sharing your screen, camera or microphone, in Picture in Picture, or holding something you're typing stay awake. Your 10 most recent tabs stay awake too. When your Mac is low on memory, tabs sleep sooner."
      ) {
        SettingToggle("tabs.sleepInactiveTabs", key: "sleepInactiveTabs")
        SettingRow("tabs.sleepTabsAfter", description: RowDescription.none) {
          SettingPicker(
            TabsPaneModel.sleepAfterChoices,
            selection: Binding(
              get: { String(TabsPaneModel.sleepAfterMinutes(store)) },
              set: { store.updateSettings(["sleepTabsAfterMinutes": .number(Double($0) ?? 30)]) }
            )
          )
          .disabled(!TabsPaneModel.sleepsTabs(store))
        }
      }

      SettingsSection(
        "Always keep these sites awake",
        description: "Tabs from these sites never sleep, in any profile, including their subdomains.",
        anchor: "tabs.keepAwakeSites"
      ) {
        KeepAwakeSitesList(store: store, requested: TabsPaneModel.keepAwakeSelection(detail))
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

struct KeepAwakeSitesList: View {
  let store: SettingsStoreSource
  let requested: String?
  @State private var selection: String?
  @State private var adding = false

  var body: some View {
    let sites = TabsPaneModel.keepAwakeSites(store)
    Group {
      if sites.isEmpty {
        Text("No sites yet. Add one here, or choose Sleep When Inactive in a site's controls.")
          .foregroundStyle(.secondary)
      }
      ForEach(sites, id: \.self) { site in
        Button {
          selection = site
        } label: {
          Text(site)
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .padding(.horizontal, 6)
        .padding(.vertical, 2)
        .background(selection == site ? Color.accentColor.opacity(0.18) : Color.clear, in: RoundedRectangle(cornerRadius: 5))
        .accessibilityAddTraits(selection == site ? .isSelected : [])
      }
      HStack(spacing: 4) {
        Button {
          adding = true
        } label: {
          Image(systemName: "plus")
        }
        .help("Add a Site")
        .accessibilityLabel("Add a Site")
        Button {
          if let selection { remove(selection) }
        } label: {
          Image(systemName: "minus")
        }
        .help("Remove the Selected Site")
        .accessibilityLabel("Remove the Selected Site")
        .disabled(selection.map { sites.contains($0) } != true)
        Spacer()
      }
      .buttonStyle(.borderless)
    }
    .onAppear { select(requested) }
    .onChange(of: requested) { _, next in select(next) }
    .sheet(isPresented: $adding) {
      KeepAwakeSiteSheet(store: store) { selection = $0 }
    }
  }

  private func select(_ site: String?) {
    if let site, TabsPaneModel.keepAwakeSites(store).contains(site) { selection = site }
  }

  private func remove(_ site: String) {
    store.updateSettings([KeepAwakeSites.settingKey: JSONValue(TabsPaneModel.keepAwakeSites(store).filter { $0 != site })])
    selection = nil
  }
}

struct KeepAwakeSiteSheet: View {
  let store: SettingsStoreSource
  let added: (String) -> Void
  @Environment(\.dismiss) private var dismiss
  @State private var text = ""

  var body: some View {
    VStack(alignment: .leading, spacing: 12) {
      Text("Keep a Site Awake")
        .font(.headline)
      Text("Tabs from this site won't sleep, in any profile.")
        .foregroundStyle(.secondary)
      VStack(alignment: .leading, spacing: 4) {
        TextField("Website", text: $text, prompt: Text("example.com"))
          .textFieldStyle(.roundedBorder)
          .onSubmit(add)
        Text("A site like example.com also covers its subdomains.")
          .font(.caption)
          .foregroundStyle(.secondary)
      }
      HStack {
        Spacer()
        Button("Cancel", role: .cancel) { dismiss() }
          .keyboardShortcut(.cancelAction)
        Button("Add", action: add)
          .keyboardShortcut(.defaultAction)
          .disabled(KeepAwakeSites.normalized(text) == nil)
      }
    }
    .padding(20)
    .frame(width: 380)
  }

  private func add() {
    guard let site = KeepAwakeSites.normalized(text) else { return }
    store.updateSettings([KeepAwakeSites.settingKey: JSONValue(KeepAwakeSites.adding(site, to: TabsPaneModel.keepAwakeSites(store)))])
    added(site)
    dismiss()
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
        if let fileSource = store.fileSource("cleanUpInactiveTabsAfterHours") {
          SettingsFileNote(source: fileSource)
        }
      }
      .disabled(store.fileSource("cleanUpInactiveTabsAfterHours") != nil)
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
