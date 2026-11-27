import Foundation
import SolaraModel
import SolaraOmnibox
import SolaraStore

public struct ToolbarPresenter {
  public struct Input: Decodable, Sendable {
    public var windowId: String
    public var tabId: String
    public var bare: Bool
    public var windowToolbar: Bool
    public var fullscreenTabs: [String]
    public var geometry: Geometry
    public var palette: ToolbarPaletteState
    public var accent: String
    public var dark: Bool
    public var lightStripes: String?
    public var darkStripes: String?
    public var sidebar: SidebarFieldLook?
    public var extensionLimit: Int?
    public var hints: [String: String]
    public var update: ToolbarUpdateState?
    public var insecure: String?
    public var editing: Bool
    public var editRequest: Int
    public var popups: Int
    public var capture: Capture?
    public var popover: String?
    public var progress: Double?
    public var translation: Translation?
    public var newTabShown: Bool
    public var backToNewTab: Bool
    public var historyKnown: Bool

    public struct Geometry: Decodable, Sendable {
      var sidebarButton: Double?
      var back: Double
      var forward: Double
      var reload: Double
      var urlLeft: Double
    }

    public struct Capture: Decodable, Sendable {
      var camera: Bool?
      var microphone: Bool?
      var screen: Bool?
    }

    public struct Translation: Decodable, Sendable {
      var translated: Bool
      var language: String
    }
  }

  public struct Page {
    public let tab: Tab
    public let loading: Bool
    public let back: Bool
    public let forward: Bool
    public let developer: Bool
    public let bookmarkProfile: String
  }

  public static func page(windowId: String, tabId: String, state: BrowserState) -> Page? {
    guard let window = state.windows[windowId], let tab = state.tabs[tabId],
      tab.windowId == windowId, tab.profileId == window.profileId else { return nil }
    let live = state.live[tabId]
    let back = state.live[tab.pageIn ?? tabId]?.canGoBack == true
    return Page(tab: tab, loading: live?.isLoading == true, back: back, forward: live?.canGoForward == true,
      developer: OmniboxCommandSources.isDeveloperURL(tab.url, settings: state.settings, profileId: tab.profileId),
      bookmarkProfile: state.bookmarkProfileId(window))
  }

  static func address(_ url: String, title: String, fullURL: Bool, insecure: String?) -> (host: String, rest: String, hover: String) {
    let file = url.hasPrefix("file:")
    let shownHost = file ? "File" : breadcrumb(url).host
    let filePath = String(url.dropFirst("file://".count))
    let full = file ? " " + (filePath.removingPercentEncoding ?? filePath) : urlForDisplay(url)
    let path = !file && full.hasPrefix(shownHost) ? String(full.dropFirst(shownHost.count)) : full
    let scheme = insecure != nil && !shownHost.isEmpty ? url.range(of: "://") : nil
    let host = (scheme.map { String(url[..<$0.upperBound]) } ?? "") + shownHost
    let web = url.range(of: "^https?:", options: [.regularExpression, .caseInsensitive]) != nil
    let rest: String
    if insecure != nil { rest = path }
    else if fullURL { rest = path.hasSuffix("/") ? String(path.dropLast()) : path }
    else if !web && appUrlOrigin(url) != nil && !title.isEmpty { rest = " / " + title }
    else { rest = "" }
    return (host, rest, path)
  }

  static func developerAddress(_ url: String) -> String {
    url.replacingOccurrences(of: #"^([a-z][a-z0-9+.-]*://[^/?#]*)/$"#, with: "$1", options: [.regularExpression, .caseInsensitive])
  }

  static func urlRight(inSplit: Bool, extensionsWidth: Double) -> Double {
    (inSplit ? 68 : 12) + extensionsWidth
  }

  static func onFrame(rail: Bool, focused: Bool, top: Bool, fullscreen: Bool, sidebarOpen: Bool) -> Bool {
    rail && focused && !top && !fullscreen && sidebarOpen
  }

  public static func fullscreen(_ input: Input, state: BrowserState) -> Bool {
    let active = state.activeTabId(input.windowId)
    let split = active.flatMap { id in state.splits.values.first { $0.windowId == input.windowId && $0.tabIds.contains(id) } }
    let shown = (split?.tabIds ?? active.map { [$0] } ?? []) + (state.peeks[input.windowId].map { [$0.tabId] } ?? [])
    return shown.contains { input.fullscreenTabs.contains($0) }
  }

  public static func present(_ input: Input, state: BrowserState, page: Page, shell: Bool, fullscreen: Bool,
    engineBack: Bool, bookmarked: Bool, extensions: [ToolbarButtonState], extensionsWidth: Double) -> ToolbarState? {
    let tab = page.tab
    guard let window = state.windows[input.windowId], tab.id == input.tabId, tab.windowId == window.id,
      tab.profileId == window.profileId, state.tabs[tab.id] == tab else { return nil }
    let sidebar = input.sidebar != nil
    let split = state.splits.values.first { $0.windowId == window.id && $0.tabIds.contains(tab.id) }
    let inSplit = !sidebar && split != nil
    let focused = sidebar || !inSplit || state.activeTabId(window.id) == tab.id
    let top = (window.tabLayout ?? state.settings.string("tabLayout")) == "top"
    let rail = !window.isSmall && SidebarRail.contains(width: SidebarRail.effectiveWidth(window, state.settings))
    let frame = !sidebar && shell && onFrame(rail: rail, focused: focused, top: top, fullscreen: fullscreen, sidebarOpen: window.sidebarOpen)
    let toggle = state.settings["showSidebarButton"]?.bool != false
    let leading = split?.tabIds.first == tab.id || split == nil
    let native = ToolbarGeometry.of(sidebarButton: leading && !top && toggle)
    let supplied = input.geometry
    let useSupplied = !shell || supplied.urlLeft == Double(ToolbarGeometry.none.urlLeft)
    let geometry = ToolbarGeometryState(
      sidebarButton: sidebar ? (toggle ? 0 : nil) : useSupplied ? supplied.sidebarButton : native.sidebarButton.map { Double($0) },
      back: useSupplied ? supplied.back : Double(native.back),
      forward: useSupplied ? supplied.forward : Double(native.forward),
      reload: useSupplied ? supplied.reload : Double(native.reload),
      urlLeft: useSupplied ? supplied.urlLeft : Double(native.urlLeft),
      urlRight: urlRight(inSplit: inSplit, extensionsWidth: extensionsWidth))
    let palette = palette(input, state: state, page: page, onFrame: frame)
    let hasPage = !tab.url.isEmpty
    let opener = tab.openerId.flatMap { state.tabs[$0] }
    let openerBack = input.historyKnown && state.live[tab.pageIn ?? tab.id] != nil
      && opener?.windowId == tab.windowId && opener?.profileId == tab.profileId
      && split == nil && !state.inPinnedContainer(tab.id) && state.peeks[window.id]?.tabId != tab.id
    let canBack = !input.newTabShown && (page.back || engineBack || input.backToNewTab || openerBack)
    let left = navigation(input, page: page, sidebarButton: geometry.sidebarButton != nil, canBack: canBack)
    let right: [ToolbarButtonState] = inSplit ? [
      .init(id: "splitMenu", icon: "rectangle.split.2x1", size: 14, box: 30, tooltip: "Split View"),
      .init(id: "closePane", icon: "xmark", size: 12, box: 30, weight: "medium", tooltip: "Close Pane"),
    ] : []
    let stripes = page.developer && !frame ? stripeAsset(input, palette: palette) : nil
    return ToolbarState(tabId: tab.id, height: Double(ShellMetrics.toolbarHeight), bare: input.bare, focused: focused,
      palette: palette, accent: input.accent, geometry: geometry, left: left,
      url: hasPage ? urlState(input, page: page, fullURL: state.settings.bool("showFullUrl"), bookmarked: bookmarked, canSplit: !inSplit && !sidebar) : nil,
      right: right, rightInset: 8, extensions: extensions, extensionsRight: inSplit ? 68 : 8,
      update: top && !sidebar && focused ? input.update : nil,
      hairline: hasPage && !input.bare && !frame, progress: page.loading ? input.progress : nil, stripes: stripes,
      inSplit: inSplit, windowToolbar: input.windowToolbar, newTabShown: input.newTabShown)
  }

  public static func sidebar(_ input: Input, state: BrowserState, toolbar: ToolbarState?) -> SidebarAddressBarState? {
    guard let look = input.sidebar else { return nil }
    let toggle = state.settings["showSidebarButton"]?.bool != false
    var buttons = toolbar?.left ?? (toggle ? [sidebarButton(input)] : [])
    for index in buttons.indices {
      buttons[index].box = Double(SidebarHeaderMetrics.plate)
      buttons[index].radius = Double(SidebarHeaderMetrics.plateRadius)
    }
    return SidebarAddressBarState(palette: toolbar?.palette ?? input.palette, accent: input.accent, look: look, buttons: buttons,
      url: toolbar?.url, extensions: toolbar?.url == nil ? [] : toolbar?.extensions ?? [], progress: toolbar?.progress, tabId: input.tabId, newTabShown: input.newTabShown)
  }

  private static func palette(_ input: Input, state: BrowserState, page: Page, onFrame: Bool) -> ToolbarPaletteState {
    var palette = input.palette
    if input.sidebar != nil || onFrame { return palette }
    var dark = input.dark
    if let backdrop = ToolbarBackdropState.resolve(windowId: input.windowId, tabId: page.tab.id, state: state, dark: dark),
      let background = backdrop.background {
      dark = backdrop.divider == "rgba(255,255,255,0.025)"
      palette.background = background
      palette.text = dark ? "#FFFFFF" : "#000000E6"
      palette.secondary = dark ? "#FFFFFF99" : "#00000080"
      palette.hover = dark ? "rgba(255,255,255,0.14)" : "rgba(0,0,0,0.07)"
      palette.pressed = dark ? "rgba(255,255,255,0.22)" : "rgba(0,0,0,0.12)"
      palette.pill = dark ? "rgba(255,255,255,0.1)" : "rgba(0,0,0,0.06)"
      palette.divider = backdrop.divider
    }
    palette.urlHost = dark ? "rgba(255,255,255,0.55)" : "rgba(0,0,0,0.8)"
    palette.urlPath = dark ? "rgba(255,255,255,0.2)" : "rgba(0,0,0,0.3)"
    palette.icon = dark ? "rgba(255,255,255,0.51)" : "rgba(0,0,0,0.83)"
    palette.iconDisabled = dark ? "rgba(255,255,255,0.24)" : "rgba(0,0,0,0.43)"
    return palette
  }

  private static func stripeAsset(_ input: Input, palette: ToolbarPaletteState) -> String? {
    let text = palette.text
    guard text.hasPrefix("#"), text.count >= 7, let color = CSSColor(String(text.prefix(7))) else { return input.lightStripes }
    return 0.2126 * color.red + 0.7152 * color.green + 0.0722 * color.blue > 128.0 / 255 ? input.lightStripes : input.darkStripes
  }

  private static func hint(_ title: String, _ id: String, _ input: Input) -> String {
    guard let shortcut = input.hints[id], !shortcut.isEmpty else { return title }
    return "\(title) (\(shortcut))"
  }

  private static func sidebarButton(_ input: Input) -> ToolbarButtonState {
    .init(id: "sidebar", icon: "sidebar.left", size: 13, tooltip: hint("Auto-Hide Tabs", "sidebar", input))
  }

  private static func navigation(_ input: Input, page: Page, sidebarButton: Bool, canBack: Bool) -> [ToolbarButtonState] {
    let refresh = hint("Refresh", "reload", input)
    return (sidebarButton ? [Self.sidebarButton(input)] : []) + [
      .init(id: "back", icon: "chevron.left", size: 13, enabled: canBack,
        tooltip: hint("Go Back", "back", input), menu: true, longPress: true, middle: true),
      .init(id: "forward", icon: "chevron.right", size: 13, enabled: input.newTabShown || page.forward,
        tooltip: hint("Go Forward", "forward", input), menu: true, longPress: true, middle: true),
      .init(id: "reload", icon: page.loading ? "xmark" : "arrow.clockwise", size: 13, enabled: !page.tab.url.isEmpty,
        tooltip: page.loading ? "Stop Loading This Page" : page.developer ? refresh + " · Right-Click for Reload Options" : refresh,
        menu: page.developer, longPress: page.developer),
    ]
  }

  private static func urlState(_ input: Input, page: Page, fullURL: Bool, bookmarked: Bool, canSplit: Bool) -> ToolbarUrlState {
    let tab = page.tab
    let insecure = input.insecure == "warning" || input.insecure == "dangerous" ? input.insecure : nil
    let shown = address(tab.url, title: tab.title, fullURL: fullURL, insecure: insecure)
    let developer = page.developer ? ToolbarDeveloperState(text: developerAddress(tab.url), editing: input.editing, request: input.editRequest) : nil
    var hover = [small("bookmark", bookmarked ? "bookmark.fill" : "bookmark",
      bookmarked ? "Remove Bookmark" : hint("Bookmark This Page", "bookmark", input))]
    if canSplit { hover.append(small("split", "rectangle.split.2x1", hint("Open Split View", "split", input))) }
    let pinned = input.popover == "siteControls"
    hover.append(small("siteControls", "slider.horizontal.3", "Site Controls", active: pinned))
    return ToolbarUrlState(developer: developer, host: shown.host, restTrail: shown.rest, hoverTrail: shown.hover,
      insecure: insecure, hoverButtons: hover, trailing: trailing(input, page: page), pinned: pinned)
  }

  private static func trailing(_ input: Input, page: Page) -> [ToolbarButtonState] {
    var buttons: [ToolbarButtonState] = []
    if let capture = input.capture {
      let devices = [capture.camera == true ? "camera" : nil, capture.microphone == true ? "microphone" : nil,
        capture.screen == true ? "screen" : nil].compactMap { $0 }.joined(separator: " and ")
      let icon = capture.screen == true ? "rectangle.inset.filled.on.rectangle" : capture.camera == true ? "video.fill" : "mic.fill"
      buttons.append(.init(id: "capture", icon: icon, size: 12, box: 24, color: "#FF453A",
        tooltip: "This page is using your " + devices, plain: true))
    }
    if page.developer {
      buttons += [
        .init(id: "divider-dev-start", icon: ""),
        small("dev:console", "terminal", "Toggle Console"),
        small("dev:network", "network", "Toggle Network Panel"),
        small("dev:elements", "scope", "Inspect Element"),
        .init(id: "divider-dev-end", icon: ""),
      ]
    }
    if let translation = input.translation {
      buttons.append(small("translate", "translate",
        translation.translated ? "Show Original (\(translation.language))" : "Translate this page",
        color: translation.translated ? input.accent : nil, menu: true))
    }
    if abs(page.tab.zoom - 1) >= 0.001 {
      let percent = (page.tab.zoom * 100).rounded()
      let label = Int(exactly: percent).map(String.init) ?? String(percent)
      buttons.append(small("zoom", page.tab.zoom > 1 ? "plus.magnifyingglass" : "minus.magnifyingglass",
        "Zoom: \(label)%", active: input.popover == "zoom"))
    }
    if input.popups > 0 { buttons.append(small("popups", "macwindow.badge.plus", "Pop-ups blocked on this page", active: input.popover == "popups")) }
    return buttons
  }

  private static func small(_ id: String, _ icon: String, _ tooltip: String, active: Bool? = nil, color: String? = nil, menu: Bool? = nil) -> ToolbarButtonState {
    .init(id: id, icon: icon, size: 13, box: 24, radius: 6, color: color, active: active, tooltip: tooltip, menu: menu)
  }
}
