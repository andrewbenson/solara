import CoreGraphics

public struct WindowLayoutSnapshot: Equatable, Sendable {
  public let input: WindowLayoutInput
  public let generation: UInt64
  public let frames: DockedLayoutFrames
  public let content: CGRect
  public let contentPanes: [String: CGRect]
  public let panes: [String: CGRect]
  public let pages: [String: CGRect]
  public let toolbars: [String: CGRect]
  public let sidebarHeader: CGRect?
  public let sidebarFooter: CGRect?
  public let stripAvailableWidth: CGFloat
  public let anchors: [String: CGRect]
  public var logicalFrames: DockedLayoutFrames { .of(input.layout) }

  public static func of(_ input: WindowLayoutInput, generation: UInt64) -> Self {
    let frames = DockedLayoutFrames.of(input.presentation)
    var contentInput = input.presentation
    contentInput.railProgress = 0
    if input.presentation.railFraction == 1 { contentInput.sidebarWidth = ShellMetrics.legacySidebarRailWidth }
    let content = DockedLayoutFrames.of(contentInput).card
    let rail = input.presentation.railFraction
    let fullscreenTab = input.pageFacts.first { $0.value.fullscreen }?.key
    let contentPanes = SplitLayout.panes(split: input.split, activeId: input.selectedTabId, fullscreenTab: fullscreenTab, bounds: content).panes
    let area = CGRect(
      x: frames.page.minX, y: frames.card.minY + (frames.page.minY - frames.card.minY) * rail,
      width: frames.page.width, height: max(0, frames.card.height + (frames.page.height - frames.card.height) * rail))
    let panes = SplitLayout.panes(split: input.split, activeId: input.selectedTabId, fullscreenTab: fullscreenTab, bounds: area).panes
    var pages: [String: CGRect] = [:]
    var toolbars: [String: CGRect] = [:]
    var anchors: [String: CGRect] = ["card": frames.card, "content": content, "page": frames.page]
    if input.layout.sidebarSide == .right && !input.layout.topTabs && !input.layout.fullscreen {
      anchors["caption"] = CGRect(x: 0, y: 0, width: ShellMetrics.railLightsTrailing + ShellMetrics.chromeCaptionTrailingMargin, height: ShellMetrics.toolbarHeight + ShellMetrics.cardTop)
    }
    for (id, pane) in panes {
      let hidden = input.layout.addressBarInSidebar || id == fullscreenTab
      let toolbar = hidden ? 0 : min(pane.height, ShellMetrics.toolbarHeight * (1 - rail))
      let captionTop: CGFloat = input.layout.sidebarSide == .right && input.layout.addressBarInSidebar && id != fullscreenTab && pane.minX == area.minX && pane.minY == area.minY ? ShellMetrics.toolbarHeight : 0
      let toolbarTop = min(pane.height, max(captionTop, input.pageFacts[id]?.top.map { $0 * (1 - rail) } ?? toolbar))
      let band = id == fullscreenTab ? 0 : max(0, input.pageFacts[id]?.band ?? 0)
      let top = min(pane.height, toolbarTop + band)
      let page = CGRect(x: pane.minX, y: pane.minY + top, width: pane.width, height: max(0, pane.height - top))
      let bar = rail > 0 && id == input.selectedTabId && !hidden
        ? CGRect(x: frames.card.minX, y: frames.card.minY, width: frames.card.width, height: min(frames.card.height, ShellMetrics.toolbarHeight + ShellMetrics.railToolbarTop * rail))
        : CGRect(x: pane.minX, y: pane.minY, width: pane.width, height: toolbar)
      pages[id] = page
      toolbars[id] = bar
      anchors["pane:\(id)"] = pane
      anchors["page:\(id)"] = page
      anchors["toolbar:\(id)"] = bar
    }
    let sidebar = frames.sidebar.map { $0.offsetBy(dx: frames.sidebarShift, dy: 0) }
    let header = sidebar.map { CGRect(x: $0.minX, y: $0.minY, width: $0.width, height: min($0.height, input.sidebarHeaderHeight)) }
    let footer = sidebar.map { CGRect(x: $0.minX, y: max($0.minY, $0.maxY - input.sidebarFooterHeight), width: $0.width, height: min($0.height, input.sidebarFooterHeight)) }
    if let sidebar { anchors["sidebar"] = sidebar }
    if input.presentation.peeking, let coverage = frames.sidebarCoverage(in: input.bounds) { anchors["sidebarPeekCoverage"] = coverage }
    if let header { anchors["sidebarHeader"] = header }
    if let footer { anchors["sidebarFooter"] = footer }
    if let strip = frames.topStrip { anchors["topStrip"] = strip }
    if input.presentation.peeking, input.layout.addressBarInSidebar, let sidebar,
      let selected = input.selectedTabId.flatMap({ contentPanes[$0] }) {
      for (name, width): (String, CGFloat) in [("siteControls", 288), ("popups", 360), ("zoom", 236)] {
        let origin = SidebarAttachment.origin(anchor: sidebar, size: CGSize(width: width, height: 0), visible: selected, side: input.layout.sidebarSide)
        anchors["peekPopover:\(name)"] = CGRect(x: origin.x, y: selected.minY + 8, width: width, height: 0)
      }
    }
    let stripAvailableWidth = max(0, input.bounds.width - ShellMetrics.topStripLeadingReservation - max(84, input.stripControlsWidth + 14))
    return Self(input: input, generation: generation, frames: frames, content: content, contentPanes: contentPanes, panes: panes, pages: pages, toolbars: toolbars, sidebarHeader: header, sidebarFooter: footer, stripAvailableWidth: stripAvailableWidth, anchors: anchors)
  }

  public func residualURLBand(tabId: String, trailingReservation: CGFloat) -> CGRect? {
    guard !input.layout.addressBarInSidebar, let pane = contentPanes[tabId] else { return nil }
    let leading = pane.minX == content.minX && pane.minY == content.minY
    let geometry = ToolbarGeometry.of(sidebarButton: leading && !input.layout.topTabs && input.showSidebarButton)
    let captionReservation = input.layout.sidebarSide == .right && leading && !input.layout.topTabs && !input.layout.fullscreen ? ShellMetrics.railToolbarLeadingInset : 0
    return CGRect(
      x: pane.minX + geometry.urlLeft + captionReservation, y: pane.minY,
      width: max(0, pane.width - geometry.urlLeft - captionReservation - max(0, trailingReservation)), height: min(pane.height, ShellMetrics.toolbarHeight))
  }

  public func endpointError(observed: [String: CGRect], names: [String]) -> CGFloat? {
    var error: CGFloat = 0
    for name in names {
      guard let expected = anchors[name], let actual = observed[name] else { return nil }
      error = max(error, abs(expected.minX - actual.minX), abs(expected.minY - actual.minY), abs(expected.maxX - actual.maxX), abs(expected.maxY - actual.maxY))
    }
    return error
  }
}
