import SwiftUI

public enum SettingsFileKeys {
  public static let byAnchor: [String: [String]] = [
    "general.openLinksFrom": ["openLinksInLittleSolara"],
    "general.littleSolaraNewTabLinks": ["littleSolaraKeepsNewTabLinks"],
    "general.windowsAndTabs": ["restoreSession"],
    "general.commandBarPreference": ["commandBarPreference"],
    "appearance.commandBarPlacement": ["commandBarPlacement"],
    "appearance.addressBar": ["addressBar"],
    "appearance.pageScrollBars": ["pageScrollBars"],
    "appearance.theme": ["appearance"],
    "advanced.batterySaver": ["batterySaverWhen"],
    "advanced.cliControl": ["cliControl"],
    "engines.defaultEngine": ["pageEngine"],
    "profiles.loadAllProfilesAtLaunch": ["loadAllProfilesAtLaunch"],
    "tabs.newTabOpens": ["newTabOpens"],
    "tabs.newTabPosition": ["newTabPosition"],
    "tabs.newTabButtonPosition": ["newTabButtonPosition"],
    "tabs.pinnedLinkTarget": ["pinnedLinkTarget"],
    "tabs.sleepTabsAfter": ["sleepTabsAfterMinutes"],
    "tabs.peekModifier": ["peekModifier"],
    "tabs.splitLinkModifier": ["splitLinkModifier"],
    "tabs.layout": ["tabLayout"],
    "tabs.keepAwakeSites": ["keepAwakeSites"],
    "tabs.cleanUp": ["cleanUpInactiveTabsAfterHours"],
    "search.defaultEngine": ["searchEngine"],
    "search.otherEngines": ["customSearchEngines"],
    "engines.websiteRules": ["websiteEngines"],
  ]

  public static func keys(anchor: String?) -> [String] {
    anchor.flatMap { byAnchor[$0] } ?? []
  }
}

public struct SettingsFileNote: View {
  let source: String

  public init(source: String) {
    self.source = source
  }

  public var body: some View {
    Label("Set in \(source)", systemImage: "doc.text")
      .labelStyle(.titleAndIcon)
      .foregroundStyle(.secondary)
      .help("This setting comes from \(source). Change it there; \(source) wins over Settings.")
      .accessibilityIdentifier("settings.fileNote")
  }
}
