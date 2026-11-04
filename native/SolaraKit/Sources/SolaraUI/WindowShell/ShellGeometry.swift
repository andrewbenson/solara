import CoreGraphics
import SolaraModel
import SolaraStore

public struct SplitDivider: Equatable, Sendable {
  public enum Kind: Equatable, Sendable {
    case root(index: Int)
    case stack
  }

  public var kind: Kind
  public var rect: CGRect
  public var vertical: Bool
}

public struct SplitGeometry: Equatable, Sendable {
  public var panes: [String: CGRect]
  public var dividers: [SplitDivider]
}

public struct ToolbarGeometry: Equatable, Sendable {
  public var sidebarButton: CGFloat?
  public var back: CGFloat
  public var forward: CGFloat
  public var reload: CGFloat
  public var urlLeft: CGFloat

  public static let none = ToolbarGeometry(sidebarButton: nil, back: 21, forward: 21, reload: 21, urlLeft: 8)

  public static func of(sidebarButton: Bool) -> ToolbarGeometry {
    let c = ShellMetrics.toolbarIconCenters
    if sidebarButton {
      return ToolbarGeometry(sidebarButton: c[0], back: c[1], forward: c[2], reload: c[3], urlLeft: ShellMetrics.breadcrumbX - 8)
    }
    let shift = c[1] - c[0]
    return ToolbarGeometry(sidebarButton: nil, back: c[1] - shift, forward: c[2] - shift, reload: c[3] - shift, urlLeft: ShellMetrics.breadcrumbX - 8 - shift)
  }
}

public enum ShellGeometry {
  static func cut(_ total: CGFloat, _ sizes: [Double], _ gap: CGFloat) -> [(start: CGFloat, size: CGFloat)] {
    let free = max(0, total - gap * CGFloat(sizes.count - 1))
    var at: CGFloat = 0
    return sizes.map { f in
      let size = DockMotion.jsRound(free * CGFloat(f))
      defer { at += size + gap }
      return (at, size)
    }
  }

  public static func split(_ split: SplitView, width: CGFloat, height: CGFloat, gap: CGFloat = ShellMetrics.paneGap) -> SplitGeometry {
    let horizontal = split.orientation == "horizontal"
    let slots = Splits.slotsOf(split)
    let sizes = split.sizes.count == slots.count ? split.sizes : slots.map { _ in 1 / Double(slots.count) }
    var panes: [String: CGRect] = [:]
    var dividers: [SplitDivider] = []
    let main = cut(horizontal ? width : height, sizes, gap)
    for (i, slot) in slots.enumerated() {
      let (start, size) = main[i]
      let slotRect = horizontal ? CGRect(x: start, y: 0, width: size, height: height) : CGRect(x: 0, y: start, width: width, height: size)
      if slot.count == 1 {
        panes[slot[0]] = slotRect
      } else {
        let inner = cut(horizontal ? slotRect.height : slotRect.width, split.stack?.sizes ?? [0.5, 0.5], gap)
        for (j, id) in slot.enumerated() where j < inner.count {
          let (s, z) = inner[j]
          panes[id] = horizontal
            ? CGRect(x: slotRect.minX, y: s, width: slotRect.width, height: z)
            : CGRect(x: s, y: slotRect.minY, width: z, height: slotRect.height)
        }
        let d = inner[0]
        dividers.append(
          SplitDivider(
            kind: .stack, rect: horizontal
              ? CGRect(x: slotRect.minX, y: d.size, width: slotRect.width, height: gap)
              : CGRect(x: d.size, y: slotRect.minY, width: gap, height: slotRect.height),
            vertical: !horizontal))
      }
      if i < slots.count - 1 {
        dividers.append(
          SplitDivider(
            kind: .root(index: i),
            rect: horizontal ? CGRect(x: start + size, y: 0, width: gap, height: height) : CGRect(x: 0, y: start + size, width: width, height: gap),
            vertical: horizontal))
      }
    }
    return SplitGeometry(panes: panes, dividers: dividers)
  }

  public static func resize(_ sizes: [Double], _ a: Int, delta: Double, total: Double, gap: Double = Double(ShellMetrics.paneGap)) -> [Double] {
    let free = max(1, total - gap * Double(sizes.count - 1))
    let px = sizes.map { $0 * free }
    let pair = px[a] + px[a + 1]
    let low = min(Double(ShellMetrics.minPane), px[a], px[a + 1])
    let left = min(max(px[a] + delta, low), pair - low)
    var next = px
    next[a] = left
    next[a + 1] = pair - left
    return next.map { $0 / free }
  }
}

public struct DockedLayoutInput: Equatable, Sendable {
  public var size: CGSize
  public var dock: CGFloat
  public var sidebarWidth: CGFloat
  public var topTabs: Bool
  public var fullscreen: Bool
  public var peeking: Bool
  public var peekSlide: CGFloat
  public var addressBarInSidebar: Bool
  public var away: Bool
  public var sidePanel: CGFloat
  public var railProgress: CGFloat?

  public init(
    size: CGSize, dock: CGFloat, sidebarWidth: CGFloat = ShellMetrics.sidebarWidth, topTabs: Bool = false, fullscreen: Bool = false,
    peeking: Bool = false, peekSlide: CGFloat = 0, addressBarInSidebar: Bool = false, away: Bool = false, sidePanel: CGFloat = 0, railProgress: CGFloat? = nil
  ) {
    self.size = size
    self.dock = dock
    self.sidebarWidth = sidebarWidth
    self.topTabs = topTabs
    self.fullscreen = fullscreen
    self.peeking = peeking
    self.peekSlide = peekSlide
    self.addressBarInSidebar = addressBarInSidebar
    self.away = away
    self.sidePanel = sidePanel
    self.railProgress = railProgress
  }

  public var inset: ShellInset { topTabs ? .topTabs : .sidebar }

  public var railFraction: CGFloat {
    guard !topTabs, !fullscreen else { return 0 }
    return min(1, max(0, railProgress ?? (SidebarRail.contains(width: Double(sidebarWidth)) ? 1 : 0)))
  }
}

public struct DockedLayoutFrames: Equatable, Sendable {
  public var card: CGRect
  public var page: CGRect
  public var sidebar: CGRect?
  public var sidebarShift: CGFloat
  public var topStrip: CGRect?
  public var lights: CGPoint?

  public static func of(_ input: DockedLayoutInput) -> DockedLayoutFrames {
    let size = input.size
    let inset = input.inset
    let dock = input.dock
    let rail = input.railFraction
    if input.fullscreen {
      let card = CGRect(origin: .zero, size: size)
      let top = min(ShellMetrics.toolbarHeight, card.height)
      let page = CGRect(x: 0, y: top, width: card.width, height: max(0, card.height - top))
      return DockedLayoutFrames(card: card, page: page, sidebar: nil, sidebarShift: 0, topStrip: nil, lights: DockMotion.sidebarLightsCenter(input))
    }
    let top = input.topTabs ? ShellMetrics.cardTop + (inset.top - ShellMetrics.cardTop) * dock : inset.top
    let left = input.topTabs ? inset.left : inset.left + (input.sidebarWidth - inset.left) * dock * (1 - rail)
    let insetCard = CGRect(x: left, y: top, width: max(0, size.width - left - inset.right - max(0, input.sidePanel)), height: max(0, size.height - top - inset.bottom))
    let windowCard = CGRect(x: 0, y: 0, width: max(0, size.width - max(0, input.sidePanel)), height: size.height)
    let card = input.topTabs ? insetCard : CGRect(
      x: insetCard.minX + (windowCard.minX - insetCard.minX) * rail,
      y: insetCard.minY + (windowCard.minY - insetCard.minY) * rail,
      width: insetCard.width + (windowCard.width - insetCard.width) * rail,
      height: insetCard.height + (windowCard.height - insetCard.height) * rail)
    let pageTop = min(ShellMetrics.toolbarHeight + ShellMetrics.railToolbarTop * rail, card.height)
    let visible = min(1, max(0, input.peeking ? input.peekSlide : dock))
    let gap = ShellMetrics.railPageGap * rail
    let pageLeft = min(card.width, max(0, input.sidebarWidth * rail * visible + gap * (1 - visible)))
    let page = CGRect(x: card.minX + pageLeft, y: card.minY + pageTop, width: max(0, card.width - pageLeft - gap), height: max(0, card.height - pageTop - gap))
    if input.topTabs {
      let strip = CGRect(x: 0, y: -inset.top * (1 - dock), width: size.width, height: inset.top)
      return DockedLayoutFrames(card: card, page: page, sidebar: nil, sidebarShift: 0, topStrip: strip, lights: nil)
    }
    let width = input.sidebarWidth
    let fullSidebar: CGRect
    if input.peeking {
      fullSidebar = CGRect(x: ShellMetrics.peekOrigin.x, y: ShellMetrics.peekOrigin.y, width: width, height: max(0, size.height - ShellMetrics.peekOrigin.y - ShellMetrics.peekBottom))
    } else {
      fullSidebar = CGRect(x: input.away ? -10_000 : 0, y: 0, width: width, height: size.height)
    }
    let railSidebar = CGRect(x: input.away ? -10_000 : card.minX, y: page.minY, width: width, height: max(0, card.maxY - page.minY))
    let sidebar = CGRect(
      x: fullSidebar.minX + (railSidebar.minX - fullSidebar.minX) * rail,
      y: fullSidebar.minY + (railSidebar.minY - fullSidebar.minY) * rail,
      width: width, height: fullSidebar.height + (railSidebar.height - fullSidebar.height) * rail)
    let peekIn = input.peeking ? -12 + (width + 12) * input.peekSlide : 0
    let fullShift = -width * (1 - dock) + peekIn
    let railShift = -width * (1 - visible)
    return DockedLayoutFrames(
      card: card, page: page, sidebar: sidebar, sidebarShift: fullShift + (railShift - fullShift) * rail,
      topStrip: nil, lights: DockMotion.sidebarLightsCenter(input))
  }
}
