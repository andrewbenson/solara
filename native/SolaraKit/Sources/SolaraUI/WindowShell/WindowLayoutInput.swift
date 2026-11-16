import AppKit
import SolaraModel
import SolaraStore

public struct WindowLayoutPageFacts: Equatable, Sendable {
  public let registration: String
  public let fullscreen: Bool
  public let top: CGFloat?
  public let band: CGFloat
  public let scrolledDown: Bool
  public let peek: Bool

  public init(registration: String = "", fullscreen: Bool = false, top: CGFloat? = nil, band: CGFloat = 0, scrolledDown: Bool = false, peek: Bool = false) {
    self.registration = registration
    self.fullscreen = fullscreen
    self.top = top
    self.band = band
    self.scrolledDown = scrolledDown
    self.peek = peek
  }
}

public struct WindowLayoutInput: Equatable, Sendable {
  public let windowId: String
  public let windowGeneration: UInt64
  public let storeRevision: Int
  public let bounds: CGRect
  public let backingScale: CGFloat
  public let profileId: String
  public let profileTitle: String
  public let profileNameWidth: CGFloat
  public let profileCount: Int
  public let selectedTabId: String?
  public let split: SplitView?
  public let windowFullscreen: Bool
  public let windowFullscreenTransition: Bool
  public let peekTabId: String?
  public let fullscreenTabId: String?
  public let toolbarHolds: Set<String>
  public let toolbarModes: [String: ToolbarAutoHideMode]
  public let shownTops: [String: CGFloat]
  public let showSidebarButton: Bool
  public let hideToolbarWhileScrolling: Bool
  public let bookmarksBar: String
  public let layout: DockedLayoutInput
  public let presentation: DockedLayoutInput
  public let pageFacts: [String: WindowLayoutPageFacts]
  public let sidebarHeaderHeight: CGFloat
  public let sidebarFooterHeight: CGFloat
  public let stripControlsWidth: CGFloat
  public let stripProfileSlotWidth: CGFloat

  @MainActor
  public init?(
    state: BrowserState, windowId: String, windowGeneration: UInt64 = 1, storeRevision: Int = 0,
    bounds: CGRect, backingScale: CGFloat = 1, presentation: DockedLayoutInput? = nil,
    sidebarUpdateHeight: CGFloat = 0, stripProfileWidth: CGFloat? = nil, sidebarPositionAllowed: Bool = true,
    pageFacts: [String: WindowLayoutPageFacts] = [:], windowFullscreen: Bool? = nil, windowTransitioning: Bool = false,
    toolbarHolds: Set<String> = []
  ) {
    guard let window = state.windows[windowId] else { return nil }
    self.windowId = windowId
    self.windowGeneration = windowGeneration
    self.storeRevision = storeRevision
    self.bounds = CGRect(origin: .zero, size: CGSize(width: max(0, bounds.width), height: max(0, bounds.height)))
    self.backingScale = backingScale.isFinite && backingScale > 0 ? backingScale : 1
    profileId = window.profileId
    profileTitle = window.incognito ? "Incognito" : state.profiles[window.profileId]?.name ?? BrowserState.defaultProfile.name
    profileNameWidth = max(0, stripProfileWidth ?? StripControlsLayout.nameWidth(profileTitle))
    profileCount = state.profileOrder.count
    selectedTabId = state.activeTabId(windowId)
    split = selectedTabId.flatMap { selected in state.splits.values.first { $0.windowId == windowId && $0.tabIds.contains(selected) } }
    peekTabId = state.peeks[windowId].flatMap { peek in state.tabs[peek.tabId]?.windowId == windowId ? peek.tabId : nil }
    let ordered = (peekTabId.map { [$0] } ?? []) + (split?.tabIds ?? selectedTabId.map { [$0] } ?? [])
    let visible = Set(ordered.filter { state.tabs[$0]?.windowId == windowId })
    self.pageFacts = pageFacts.filter { visible.contains($0.key) }
    fullscreenTabId = ordered.first { visible.contains($0) && pageFacts[$0]?.fullscreen == true }
    self.windowFullscreen = windowFullscreen ?? window.fullScreen.map { $0 != 0 } ?? false
    windowFullscreenTransition = windowTransitioning
    self.toolbarHolds = toolbarHolds.intersection(visible)
    showSidebarButton = state.settings["showSidebarButton"]?.bool ?? true
    hideToolbarWhileScrolling = state.settings.bool("hideToolbarWhileScrolling")
    bookmarksBar = state.settings.string("bookmarksBar") ?? "newTab"
    let topTabs = (window.tabLayout ?? state.settings.string("tabLayout") ?? "sidebar") == "top"
    let rail = !topTabs && window.effectiveSidebarIconsOnly(state.settings)
    let address = !topTabs && !rail && state.settings.string("addressBar") == "sidebar"
    let fullscreen = fullscreenTabId != nil
    var modes: [String: ToolbarAutoHideMode] = [:]
    var tops: [String: CGFloat] = [:]
    for id in visible {
      let hidden = address || id == fullscreenTabId
      let hasPage = state.tabs[id]?.url.isEmpty == false
      let needsBar = state.windowUi[windowId]?.panelOpen == true || state.find[id]?.json["open"]?.truthy == true || self.toolbarHolds.contains(id)
      modes[id] = ToolbarAutoHideInput(enabled: hideToolbarWhileScrolling && !hidden, hasPage: hasPage,
        scrolledDown: self.pageFacts[id]?.scrolledDown == true, peek: self.pageFacts[id]?.peek == true, needsBar: needsBar).mode
      let bookmarks = id != fullscreenTabId && split == nil && !window.incognito
        && (bookmarksBar == "always" || bookmarksBar == "newTab" && !hasPage)
      tops[id] = (hidden ? 0 : ShellMetrics.toolbarHeight) + (bookmarks ? 30 : 0)
    }
    toolbarModes = modes
    shownTops = tops
    layout = DockedLayoutInput(
      size: self.bounds.size, dock: window.sidebarOpen ? 1 : 0,
      sidebarWidth: rail ? CGFloat(SidebarRail.width) : CGFloat(window.effectiveSidebarWidth(state.settings)),
      topTabs: topTabs, fullscreen: fullscreen, addressBarInSidebar: address,
      sidebarSide: sidebarPositionAllowed ? SidebarSide(position: window.effectiveSidebarPosition(state.settings)) : .left)
    var sample = presentation ?? layout
    sample.size = self.bounds.size
    sample.topTabs = topTabs
    sample.sidebarSide = layout.sidebarSide
    sample.addressBarInSidebar = address
    sample.fullscreen = fullscreen
    self.presentation = sample
    let dots = !window.incognito && profileCount > 1
    let downloads = state.downloads.contains { download in
      let session = download.offTheRecord ? download.profile ?? "" : download.profile.flatMap { Ids.isIncognitoProfile($0) ? state.privateSession($0) : nil }
      return window.incognito ? session != nil && session == state.privateSession(window.profileId) : session == nil && (download.profile ?? "") == state.engineProfile(window.profileId)
    }
    sidebarHeaderHeight = rail ? (window.incognito || profileCount > 1 ? SidebarChromeMetrics.railHeader : 0) : SidebarChromeMetrics.headerHeight(addressBar: address)
    sidebarFooterHeight = (rail ? (dots ? SidebarChromeMetrics.footer : 0) + (downloads ? SidebarChromeMetrics.footer : 0) : (dots || (address && downloads) ? SidebarChromeMetrics.footer : 0)) + max(0, sidebarUpdateHeight)
    let leading = self.windowFullscreen ? 8 : ShellMetrics.topStripLeadingReservation
    let room = StripControlsLayout.profileRoom(width: self.bounds.width, leading: leading)
    let indicator = StripControlsLayout.indicator(textWidth: profileNameWidth, room: room, incognito: window.incognito, profiles: profileCount)
    stripControlsWidth = StripControlsLayout.downloadsBox
    stripProfileSlotWidth = StripControlsLayout.profileSlot(indicator: indicator.width)
  }

  public func hasSameLayout(as other: Self) -> Bool {
    windowId == other.windowId && bounds == other.bounds && backingScale == other.backingScale
      && profileId == other.profileId && profileTitle == other.profileTitle && profileNameWidth == other.profileNameWidth
      && profileCount == other.profileCount && selectedTabId == other.selectedTabId && split == other.split
      && windowFullscreen == other.windowFullscreen && windowFullscreenTransition == other.windowFullscreenTransition
      && peekTabId == other.peekTabId && fullscreenTabId == other.fullscreenTabId
      && toolbarHolds == other.toolbarHolds && toolbarModes == other.toolbarModes && shownTops == other.shownTops
      && showSidebarButton == other.showSidebarButton
      && hideToolbarWhileScrolling == other.hideToolbarWhileScrolling && bookmarksBar == other.bookmarksBar
      && layout == other.layout && presentation == other.presentation && pageFacts == other.pageFacts
      && sidebarHeaderHeight == other.sidebarHeaderHeight && sidebarFooterHeight == other.sidebarFooterHeight
      && stripControlsWidth == other.stripControlsWidth && stripProfileSlotWidth == other.stripProfileSlotWidth
  }
}
