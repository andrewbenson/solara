import AppKit
import Foundation
import SolaraModel
import SolaraOmnibox

public enum PreviewId: String, CaseIterable, Sendable, Hashable {
  case tabsSidebar = "tabs-sidebar"
  case tabsTop = "tabs-top"
  case addressToolbar = "address-toolbar"
  case addressSidebar = "address-sidebar"
  case cmdlField = "cmdl-field"
  case cmdlCentred = "cmdl-centred"
  case newtabPage = "newtab-page"
  case newtabCommandbar = "newtab-commandbar"
  case newtabposBottom = "newtabpos-bottom"
  case newtabposTop = "newtabpos-top"
  case tidyKeep = "tidy-keep"
  case tidyAuto = "tidy-auto"
  case quitRestore = "quit-restore"
  case quitFresh = "quit-fresh"
  case windowsSeparate = "windows-separate"
  case windowsShared = "windows-shared"
  case appearanceAuto = "appearance-auto"
  case appearanceLight = "appearance-light"
  case appearanceDark = "appearance-dark"
  case sitecolorOn = "sitecolor-on"
  case sitecolorOff = "sitecolor-off"
  case typedWebsite = "typed-website"
  case typedSearch = "typed-search"
  case blockOn = "block-on"
  case blockOff = "block-off"
  case linksLittle = "links-little"
  case linksTab = "links-tab"
}

public struct OnboardingChoice: Identifiable, Sendable, Equatable {
  public let value: JSONValue
  public let preview: PreviewId
  public let title: String
  public let subtitle: String
  public var id: String { preview.rawValue }

  init(_ value: JSONValue, _ preview: PreviewId, _ title: String, _ subtitle: String) {
    self.value = value
    self.preview = preview
    self.title = title
    self.subtitle = subtitle
  }
}

public struct OnboardingPageText: Sendable, Equatable {
  public let title: String
  public let subtitle: String?
}

public struct OnboardingTidyOption: Sendable, Equatable, Hashable {
  public let hours: Double
  public let title: String
}

public extension OnboardingModel {
  static let layoutKeys = ["tabLayout", "addressBar", "commandBarPlacement"]
  static let tabsKeys = ["newTabOpens", "newTabPosition", "newTabButtonPosition", "cleanUpInactiveTabsAfterHours", "restoreSession", "shareTabsAcrossWindows"]
  static let tabsMoreKeys = ["balancedTopApps", "peekModifier", "undoReopensClosedTab", "cmdClickCreatesTabGroup"]
  static let lookKeys = ["appearance", "extendWebsiteColor", "hideToolbarWhileScrolling", "bookmarksBar"]
  static let searchKeys = ["searchEngine", "commandBarPreference"]
  static let featuredEngines = ["google", "duckduckgo", "bing", "kagi", "ecosia", "brave", "startpage"]
  static let tidyAfter = [OnboardingTidyOption(hours: 12, title: "12 h"), OnboardingTidyOption(hours: 24, title: "1 day"), OnboardingTidyOption(hours: 168, title: "1 week")]
  static let peekWith: [(value: String, title: String)] = [("shift", "⇧-click"), ("alt", "⌥-click"), ("off", "Off")]
  static let bookmarksBarOptions: [(value: String, title: String)] = [("always", "Always"), ("newTab", "New Tab"), ("never", "Never")]
  static let shortcuts: [(keys: String, label: String)] = [("⌘T", "Open a new tab"), ("⌘L", "Go anywhere from the command bar"), ("⌘S", "Hide the sidebar for more room")]

  static func hoursLabel(_ hours: Double) -> String {
    if hours == 12 { return "12 hours" }
    return tidyAfter.first { $0.hours == hours }?.title ?? "\(OnboardingDocument.number(hours)) hours"
  }

  func keys(for step: OnboardingStep) -> [String] {
    switch step {
    case .layout: Self.layoutKeys
    case .tabs: Self.tabsKeys + Self.tabsMoreKeys
    case .look: Self.lookKeys
    case .searchPrivacy: Self.searchKeys
    case .home: ["openLinksInLittleSolara"]
    default: []
    }
  }

  var mockSettings: MockSettings { mock(keys(for: step)) }

  func choices(_ question: OnboardingQuestion) -> [OnboardingChoice] {
    switch question {
    case .tabs:
      [
        OnboardingChoice("sidebar", .tabsSidebar, "In the sidebar", "A tall list down the side, as in Arc"),
        OnboardingChoice("top", .tabsTop, "Along the top", "Classic tabs above the page"),
      ]
    case .address:
      [
        OnboardingChoice("toolbar", .addressToolbar, "In the toolbar", "Above the page, as in Dia"),
        OnboardingChoice("sidebar", .addressSidebar, "In the sidebar", "On top of your tabs, as in Arc"),
      ]
    case .cmdl:
      [
        OnboardingChoice("field", .cmdlField, "Under the address", "Drops down from the field, as in Dia"),
        OnboardingChoice("centred", .cmdlCentred, "In the centre", "Floats over the page, as in Arc"),
      ]
    case .newTab:
      [
        OnboardingChoice("page", .newtabPage, "The New Tab page", "Your apps and a search box, as in Dia"),
        OnboardingChoice("commandBar", .newtabCommandbar, "The command bar", "Start typing right away, as in Arc"),
      ]
    case .newTabPosition:
      mockSettings.top
        ? [
          OnboardingChoice("bottom", .newtabposBottom, "On the right", "After your other tabs, as in Dia"),
          OnboardingChoice("top", .newtabposTop, "On the left", "Before your other tabs, as in Arc"),
        ]
        : [
          OnboardingChoice("bottom", .newtabposBottom, "At the bottom", "Under your other tabs, as in Dia"),
          OnboardingChoice("top", .newtabposTop, "At the top", "Above your other tabs, as in Arc"),
        ]
    case .tidy:
      [
        OnboardingChoice("keep", .tidyKeep, "Keep them", "Tabs stay until you close them"),
        OnboardingChoice("tidy", .tidyAuto, "Tidy them up", "Close the ones you haven't used in a while"),
      ]
    case .quit:
      [
        OnboardingChoice(true, .quitRestore, "Restore my tabs", "Pick up where you left off"),
        OnboardingChoice(false, .quitFresh, "Start fresh", "Open to a clean window"),
      ]
    case .windows:
      [
        OnboardingChoice(false, .windowsSeparate, "Separate", "Each window has its own tabs"),
        OnboardingChoice(true, .windowsShared, "Shared", "Every window shows the same tabs, as in Arc"),
      ]
    case .appearance:
      [
        OnboardingChoice("auto", .appearanceAuto, "Automatic", "Light by day, dark by night, like your Mac"),
        OnboardingChoice("light", .appearanceLight, "Light", "Always light"),
        OnboardingChoice("dark", .appearanceDark, "Dark", "Always dark"),
      ]
    case .siteColor:
      [
        OnboardingChoice(true, .sitecolorOn, "Take on the site's color", "The tab bar blends into the page"),
        OnboardingChoice(false, .sitecolorOff, "Keep my theme color", "The same color on every site"),
      ]
    case .typed:
      [
        OnboardingChoice("website", .typedWebsite, "Go to the website", "“github” opens github.com"),
        OnboardingChoice("search", .typedSearch, "Search for it", "“github” searches the web"),
      ]
    case .links:
      [
        OnboardingChoice(true, .linksLittle, copy.littleWindow, "A small window that's gone when you're done"),
        OnboardingChoice(false, .linksTab, "A new tab", "Right in your main window"),
      ]
    default: []
    }
  }

  func choiceValue(_ question: OnboardingQuestion) -> JSONValue {
    switch question {
    case .tabs: value("tabLayout")
    case .address: value("addressBar")
    case .cmdl: value("commandBarPlacement")
    case .newTab: value("newTabOpens")
    case .newTabPosition: value("newTabPosition")
    case .tidy: value("cleanUpInactiveTabsAfterHours").number == nil ? "keep" : "tidy"
    case .quit: .bool(bool("restoreSession"))
    case .windows: .bool(bool("shareTabsAcrossWindows"))
    case .appearance: value("appearance")
    case .siteColor: .bool(bool("extendWebsiteColor"))
    case .typed: value("commandBarPreference")
    case .links: .bool(bool("openLinksInLittleSolara"))
    default: .null
    }
  }

  func choose(_ question: OnboardingQuestion, _ choice: JSONValue) {
    switch question {
    case .tabs: change(["tabLayout": choice], live: true)
    case .address: change(["addressBar": choice], live: true)
    case .cmdl: change(["commandBarPlacement": choice], live: true)
    case .newTab: change(["newTabOpens": choice])
    case .newTabPosition: change(["newTabPosition": choice, "newTabButtonPosition": choice.string == "top" ? "top" : "bottom"])
    case .tidy:
      let hours = value("cleanUpInactiveTabsAfterHours").number
      change(["cleanUpInactiveTabsAfterHours": choice.string == "keep" ? .null : .number(hours ?? 12)])
    case .quit: change(["restoreSession": choice])
    case .windows: change(["shareTabsAcrossWindows": choice])
    case .appearance: change(["appearance": choice], live: true)
    case .siteColor: change(["extendWebsiteColor": choice], live: true)
    case .typed: setDraft(["commandBarPreference": choice])
    case .links: setDraft(["openLinksInLittleSolara": choice])
    default: break
    }
  }

  func change(_ patch: JSONObject, live: Bool = false) {
    setDraft(patch)
    if live { previewLive(patch) }
  }

  func pageText(_ question: OnboardingQuestion) -> OnboardingPageText {
    switch question {
    case .source: OnboardingPageText(title: "Where are you coming from?", subtitle: copy.sourceSubtitle)
    case .tabs: OnboardingPageText(title: "Where do your tabs go?", subtitle: "Your window changes as you pick.")
    case .address: OnboardingPageText(title: "Where's the address bar?", subtitle: "Your window changes as you pick.")
    case .cmdl: OnboardingPageText(title: "Where does ⌘L open?", subtitle: "The command bar, for going anywhere.")
    case .newTab: OnboardingPageText(title: "What does ⌘T open?", subtitle: "What you see when you open a tab.")
    case .newTabPosition: OnboardingPageText(title: "Where do new tabs go?", subtitle: "Where a tab lands when you open it.")
    case .tidy: OnboardingPageText(title: "What about old tabs?", subtitle: "Tabs you opened and forgot.")
    case .quit: OnboardingPageText(title: "When you quit and come back?", subtitle: copy.launchSubtitle)
    case .windows: OnboardingPageText(title: "Two windows, same tabs?", subtitle: "How windows share what's open.")
    case .tabsMore: OnboardingPageText(title: "A few more tab habits", subtitle: "Small things Arc and Dia do differently.")
    case .color: OnboardingPageText(title: "Pick a color", subtitle: "It tints the sidebar and the window.")
    case .appearance: OnboardingPageText(title: "Light or dark?", subtitle: "Incognito windows are always dark.")
    case .siteColor: OnboardingPageText(title: "Let sites tint the tab bar?", subtitle: "Many sites have a color of their own.")
    case .lookMore: OnboardingPageText(title: "A few finishing touches", subtitle: "All of these live in Settings too.")
    case .engine: OnboardingPageText(title: "Search with what?", subtitle: "For anything that isn't a website.")
    case .typed: OnboardingPageText(title: "Type a word. What happens?", subtitle: "When what you type could be a site.")
    case .pins: OnboardingPageText(title: "Keep your favorite apps handy", subtitle: copy.pinnedSubtitle)
    case .defaultBrowser: OnboardingPageText(title: copy.systemTitle, subtitle: "Links from everywhere open here.")
    case .links: OnboardingPageText(title: "Where do links from other apps open?", subtitle: "From Mail, Slack, Notes and the rest.")
    case .outro: OnboardingPageText(title: "Welcome to your new\nhome on the internet", subtitle: "Everything you set up is saved. Change any of it later in Settings.")
    }
  }

  var styleTag: String {
    let values = resolve(Self.layoutKeys)
    let preset = { (p: OnboardingPreset) in
      ["addressBar", "commandBarPlacement"].allSatisfy { values[$0] == p.settings[$0] } && values["tabLayout"]?.string == "sidebar"
    }
    if preset(.arc) { return "Arc-style" }
    if preset(.dia) || (values["tabLayout"]?.string == "top" && values["commandBarPlacement"] == OnboardingPreset.dia.settings["commandBarPlacement"]) { return "Dia-style" }
    return "Your mix"
  }

  func tidyOptions(_ hours: Double) -> [OnboardingTidyOption] {
    Self.tidyAfter.contains { $0.hours == hours } ? Self.tidyAfter : Self.tidyAfter + [OnboardingTidyOption(hours: hours, title: Self.hoursLabel(hours))]
  }

  func patch(for question: OnboardingQuestion) -> JSONObject {
    switch question {
    case .tabsMore:
      var out: JSONObject = [:]
      for key in Self.tabsMoreKeys { out[key] = value(key) }
      return out
    case .source, .color, .pins, .defaultBrowser, .outro:
      return [:]
    default:
      return resolve(question.keys)
    }
  }

  func picked(for question: OnboardingQuestion) -> [String] {
    let none: [String] = []
    switch question {
    case .tabs: return [string("tabLayout") == "top" ? "Tabs along the top" : "Tabs in the sidebar"]
    case .address: return [string("addressBar") == "sidebar" ? "Address in the sidebar" : "Address in the toolbar"]
    case .cmdl: return [string("commandBarPlacement") == "centred" ? "⌘L opens in the centre" : "⌘L opens under the address"]
    case .newTab: return [string("newTabOpens") == "commandBar" ? "⌘T opens the command bar" : "⌘T opens the New Tab page"]
    case .tidy:
      return value("cleanUpInactiveTabsAfterHours").number.map { ["Old tabs tidy up after \(Self.hoursLabel($0))"] } ?? ["Old tabs stay until you close them"]
    case .quit: return bool("restoreSession") ? [] : [copy.startsFresh]
    case .windows: return bool("shareTabsAcrossWindows") ? ["Windows share their tabs"] : []
    case .color: return colorName.map { ["\($0) theme"] } ?? []
    case .appearance:
      return ["Appearance \(["auto": "automatic", "light": "always light", "dark": "always dark"][string("appearance")] ?? "automatic")"]
    case .engine: return ["Search with \(selectedEngine?.name ?? "your engine")"]
    case .links: return [bool("openLinksInLittleSolara") ? copy.linksInLittleWindow : "Links from other apps open in a tab"]
    case .pins:
      let n = selectedPins.count
      return n > 0 ? ["\(n) \(n == 1 ? "app" : "apps") pinned"] : []
    case .source:
      if let tile = chosenTile { return ["Coming from \(tile.name)"] }
      return source == .fresh ? ["Starting fresh"] : []
    case .newTabPosition, .tabsMore, .siteColor, .lookMore, .typed, .defaultBrowser, .outro: return none
    }
  }

  func confirmCurrent() {
    guard syncRoute == .setup, isActive else { return }
    guard let question else { return }
    switch question {
    case .lookMore:
      if let icon = extras.appIcon, icon != currentIcon { Task { if syncRoute == .setup, isActive { await services.setAppIcon(icon) } } }
    case .pins:
      if let windowId, !selectedPins.isEmpty { pinSelected(windowId) }
    case .defaultBrowser:
      Task { await applySystem() }
      return
    case .outro:
      return finish()
    default:
      break
    }
    confirm(question, patch: patch(for: question), picked: picked(for: question))
  }

  var colorName: String? {
    _ = settingsRevision
    guard let windowId else { return nil }
    return services.profileColor(windowId)?.name
  }

  var currentColor: ProfileColorValue? {
    _ = settingsRevision
    guard let windowId else { return nil }
    return services.profileColor(windowId)
  }

  var colorPickerShown: Bool {
    guard let windowId else { return false }
    return currentColor != nil && !services.isIncognito(windowId)
  }

  var engines: [SearchEngine] {
    _ = settingsRevision
    var values: JSONObject = [:]
    for key in ["customSearchEngines", "extensionSearchEngines", "customSearchUrl"] { if let v = store.settingValue(key) { values[key] = v } }
    return searchEngines(Settings(values: values))
  }

  var shownEngines: [SearchEngine] {
    let current = string("searchEngine")
    return engines.filter { Self.featuredEngines.contains($0.id) || $0.id == current }
  }

  var selectedEngine: SearchEngine? {
    let current = string("searchEngine")
    return engines.first { $0.id == current }
  }

  var selectedPins: [String] {
    if let pins = extras.pins { return pins }
    guard let windowId else { return [] }
    return PinnableSite.preselected(history: services.history(windowId), alreadyPinned: services.pinnedHosts(windowId))
  }

  func togglePin(_ id: String) {
    let selected = selectedPins
    setExtras { $0.pins = selected.contains(id) ? selected.filter { $0 != id } : selected + [id] }
  }

  func pinSelected(_ windowId: String) {
    let pinned = services.pinnedHosts(windowId)
    let sites = PinnableSite.all.filter { selectedPins.contains($0.id) && !pinned.contains(PinnableSite.host($0.url)) }
    services.openPinnedTabs(windowId, sites)
  }

  var pinsContinueTitle: String {
    let n = selectedPins.count
    return n > 0 ? "Pin \(n) \(n == 1 ? "Tab" : "Tabs")" : "Continue"
  }

  var chosenTile: BrowserSourceTile? { sourceTiles.first { $0.id == source } }
  var canImport: Bool { chosenTile?.app != nil && services.importAvailable }

  func startImport() {
    guard syncRoute == .setup, isActive else { return }
    guard let tile = chosenTile else { return }
    services.openImport(tile.importId ?? tile.id.rawValue)
    importing = tile.id
  }

  func loadSources() async {
    guard syncRoute == .setup, isActive else { return }
    let activeSession = session
    if sourceTiles.isEmpty { sourceTiles = BrowserSourceTile.detect(fileExists: services.fileExists) }
    var tiles = sourceTiles
    for i in tiles.indices {
      if let app = tiles[i].app, tiles[i].icon == nil { tiles[i].icon = await services.fileIcon(app, size: 64) }
    }
    guard syncRoute == .setup, isActive, session == activeSession, !Task.isCancelled else { return }
    sourceTiles = tiles
  }

  var setDefaultChoice: Bool { extras.setDefault ?? !services.backgroundInstance }
  var trialChoice: Bool { extras.trial ?? false }
  var dockChoice: Bool { extras.dock ?? true }
  var loginChoice: Bool { extras.login ?? system?.loginEnabled ?? false }

  func loadSystem() async {
    guard syncRoute == .setup, isActive else { return }
    let activeSession = session
    let isDefault = await services.isDefaultBrowser()
    let inDock = await services.isInDock()
    let login = await services.loginItemStatus()
    guard syncRoute == .setup, isActive, session == activeSession, !Task.isCancelled else { return }
    system = OnboardingSystemState(isDefault: isDefault, inDock: inDock, loginEnabled: login == .enabled)
  }

  func applySystem() async {
    guard syncRoute == .setup, isActive, systemOperation == nil, let system else { return }
    let activeSession = session
    let operation = UUID()
    systemOperation = operation
    busy = true
    defer {
      if systemOperation == operation {
        systemOperation = nil
        if session == activeSession { busy = false }
        let waiters = systemWaiters
        systemWaiters = []
        for waiter in waiters { waiter.resume() }
      }
    }
    var lines: [String] = []
    let setDefault = setDefaultChoice, trial = trialChoice, dock = dockChoice, login = loginChoice
    if !system.isDefault && (setDefault || trial), await services.setAsDefaultBrowser() {
      guard syncRoute == .setup, isActive, session == activeSession, !Task.isCancelled else { return }
      if !setDefault { recordDefaultBrowserTrial() }
      lines.append(setDefault ? copy.isDefault : "A week as your default browser")
    }
    guard syncRoute == .setup, isActive, session == activeSession, !Task.isCancelled else { return }
    if login != system.loginEnabled { await services.setLaunchAtLogin(login) }
    guard syncRoute == .setup, isActive, session == activeSession, !Task.isCancelled else { return }
    if dock && !system.inDock { await services.addToDock() }
    guard syncRoute == .setup, isActive, session == activeSession, !Task.isCancelled else { return }
    busy = false
    confirm(.defaultBrowser, patch: [:], picked: lines)
  }

  func waitForSystemChoices() async {
    guard systemOperation != nil else { return }
    await withCheckedContinuation { systemWaiters.append($0) }
  }

  func loadIcons() async {
    guard syncRoute == .setup, isActive else { return }
    let activeSession = session
    let loaded = await services.appIcons(size: 56)
    let current = await services.currentAppIcon()
    guard syncRoute == .setup, isActive, session == activeSession, !Task.isCancelled else { return }
    icons = loaded
    currentIcon = current
  }

  var appIconValue: String? { extras.appIcon ?? currentIcon ?? icons.first?.id }

  func enter(_ step: OnboardingStep) async {
    guard syncRoute == .setup, isActive, !Task.isCancelled else { return }
    switch step {
    case .source: await loadSources()
    case .layout: previewLive(resolve(Self.layoutKeys))
    case .look:
      previewLive(resolve(["appearance", "extendWebsiteColor"]))
      await loadIcons()
    default: break
    }
  }
}
