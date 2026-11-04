import AppKit
import SolaraModel
import SolaraStore

@MainActor
final class SidebarDragGhostView: NSView {
  private let surface = SurfaceLayer()
  private let icon = TabIconView()
  private let mosaic = FolderMosaicView()
  private let regularLabel = FadeLabel(fontSize: 13)
  private let mediumLabel = FadeLabel(fontSize: 13, weight: .medium)
  private var label: FadeLabel { boxed ? mediumLabel : regularLabel }
  private var boxed = false
  private let badge = NSTextField(labelWithString: "")
  private let badgeBox = CALayer()
  private var tile = false
  private var rail = false

  override var isFlipped: Bool { true }

  init() {
    super.init(frame: .zero)
    identifier = NSUserInterfaceItemIdentifier(SidebarDragTrace.ghostIdentifier)
    wantsLayer = true
    layer?.masksToBounds = false
    layer?.addSublayer(surface)
    surface.radius = 10
    surface.border = 0.5
    surface.glowColor = .black
    surface.glowRadius = 10
    surface.glowOffset = CGSize(width: 0, height: 4)
    addSubview(icon)
    addSubview(mosaic)
    addSubview(regularLabel)
    addSubview(mediumLabel)
    badgeBox.cornerRadius = 9
    badgeBox.actions = SurfaceLayer.noActions
    badge.font = .systemFont(ofSize: 11, weight: .bold)
    badge.textColor = .white
    badge.alignment = .center
    addSubview(badge)
    layer?.addSublayer(badgeBox)
  }

  required init?(coder: NSCoder) { fatalError() }

  override func hitTest(_ point: NSPoint) -> NSView? { nil }

  func show(_ item: DragItem, count: Int, context: SidebarContext, rail: Bool = false) {
    let palette = context.palette
    let dark = palette.dark
    tile = item.kind == .tile
    self.rail = rail
    surface.radius = rail ? SidebarRail.radius : 10
    let folderTile = tile && item.folderId != nil
    surface.fill = dark ? NSColor(srgbRed: 0x0F / 255, green: 0x0F / 255, blue: 0x14 / 255, alpha: 1) : .white
    surface.borderTint = palette.dragBorder
    surface.glowOpacity = dark ? 0.45 : 0.18
    surface.opacity = 0.96
    let tab = item.tabIds.first.flatMap { context.state.tabs[$0] }
    let group = item.kind == .group ? item.groupId.flatMap { context.state.groups[$0] } : nil
    let live = item.kind == .live ? item.liveFolderId.flatMap { context.live?.header(SidebarLiveMetrics.headerKey($0)) } : nil
    boxed = item.boxed
    regularLabel.isHidden = true
    mediumLabel.isHidden = true
    mosaic.isHidden = !folderTile
    if folderTile { mosaic.render(members: item.tabIds, context: context) }
    icon.isHidden = folderTile || (tab == nil && group?.icon == nil && live == nil)
    if let live {
      let (site, glyph) = SidebarLive.folderIcon(live.folder)
      icon.favicons = context.favicons
      icon.set(TabIconSpec(url: site, favicon: nil, customIcon: glyph, profileId: live.folder.profileId), palette: palette)
    } else if let tab, !folderTile {
      icon.favicons = context.favicons
      icon.set(context.iconSpec(tab), palette: palette)
    }
    label.isHidden = tile || rail
    label.color = palette.textPrimary
    if let live {
      label.text = live.folder.name
    } else if let group, let id = item.groupId {
      label.text = context.query.groupLabel(id)
      _ = group
    } else if let tab {
      label.text = context.title(tab)
    } else {
      label.text = ""
    }
    badge.isHidden = count <= 1 || folderTile
    badgeBox.isHidden = badge.isHidden
    badge.stringValue = "\(count)"
    badgeBox.backgroundColor = palette.accent.cgColor
    needsLayout = true
  }

  override func layout() {
    super.layout()
    let height = rail ? SidebarRail.rowHeight : tile ? SidebarMetrics.tileHeight : bounds.height
    CATransaction.begin()
    CATransaction.setDisableActions(true)
    surface.frame = rail ? SidebarRail.tileFrame(in: bounds) : CGRect(x: 0, y: 0, width: bounds.width, height: height)
    let side = FolderMosaicView.side
    mosaic.frame = NSRect(x: (bounds.width - side) / 2, y: (height - side) / 2, width: side, height: side)
    if tile || rail {
      icon.frame = NSRect(x: (bounds.width - 16) / 2, y: (height - 16) / 2, width: 16, height: 16)
    } else {
      icon.frame = NSRect(x: 9, y: (height - 16) / 2, width: 16, height: 16)
      let left: CGFloat = icon.isHidden ? 9 : 9 + 16 + 7
      label.frame = NSRect(x: left, y: (height - 18) / 2, width: max(0, bounds.width - left - 6), height: 18)
    }
    let width = max(18, badge.fittingSize.width + 10)
    badgeBox.frame = CGRect(x: bounds.width + 4 - width, y: -6, width: width, height: 18)
    badge.frame = NSRect(x: badgeBox.frame.minX, y: -6 + (18 - badge.fittingSize.height) / 2, width: width, height: badge.fittingSize.height)
    CATransaction.commit()
  }
}

@MainActor
final class SidebarPinSlotView: NSView {
  private let box = CAShapeLayer()
  private let glyph = SymbolView()

  override var isFlipped: Bool { true }

  init() {
    super.init(frame: .zero)
    wantsLayer = true
    box.lineWidth = 1.5
    box.lineDashPattern = [4, 3]
    box.actions = SurfaceLayer.noActions
    layer?.addSublayer(box)
    addSubview(glyph)
    alphaValue = 0
  }

  required init?(coder: NSCoder) { fatalError() }

  override func hitTest(_ point: NSPoint) -> NSView? { nil }

  func paint(_ palette: SidebarPalette) {
    box.strokeColor = palette.accent.cgColor
    box.fillColor = (palette.dark ? NSColor(white: 1, alpha: 0.06) : NSColor(white: 0, alpha: 0.04)).cgColor
    glyph.set("pin", size: 13, color: palette.accent)
  }

  override func layout() {
    super.layout()
    CATransaction.begin()
    CATransaction.setDisableActions(true)
    box.frame = bounds
    box.path = CGPath(roundedRect: bounds.insetBy(dx: 0.75, dy: 0.75), cornerWidth: 10, cornerHeight: 10, transform: nil)
    CATransaction.commit()
    glyph.frame = NSRect(x: (bounds.width - 16) / 2, y: (bounds.height - 16) / 2, width: 16, height: 16)
  }
}

@MainActor
final class SidebarFolderRing: CALayer {
  static let outset: CGFloat = 3

  override init() {
    super.init()
    borderWidth = 2
    opacity = 0
    actions = SurfaceLayer.noActions
  }

  override init(layer: Any) { super.init(layer: layer) }

  required init?(coder: NSCoder) { fatalError() }

  func show(_ on: Bool, palette: SidebarPalette, around bounds: CGRect) {
    let o = Self.outset
    frame = bounds.insetBy(dx: -o, dy: -o)
    cornerRadius = SidebarMetrics.tileRadius + o
    borderColor = palette.accent.cgColor
    backgroundColor = (palette.dark ? NSColor(white: 1, alpha: 0.08) : NSColor(white: 0, alpha: 0.05)).cgColor
    let from = presentation()?.opacity ?? opacity
    let to: Float = on ? 1 : 0
    guard from != to || opacity != to else { return }
    opacity = to
    let fade = SidebarSpring.make("opacity", from: from, to: to)
    add(fade, forKey: "ring")
    let scale = SidebarSpring.make("transform.scale", from: on ? 0.92 : 1, to: on ? 1 : 0.92)
    add(scale, forKey: "ringScale")
  }
}

enum SidebarSpring {
  static func make(_ keyPath: String, from: Any, to: Any) -> CASpringAnimation {
    let spring = CASpringAnimation(keyPath: keyPath)
    spring.mass = 1
    spring.stiffness = 8100
    spring.damping = 180
    spring.initialVelocity = 0
    spring.fromValue = from
    spring.toValue = to
    spring.duration = spring.settlingDuration
    return spring
  }

  static func restDuration(distance: CGFloat) -> CFTimeInterval {
    let omega = (8100.0 as Double).squareRoot()
    let d = Double(abs(distance))
    var t = 0.0
    while t < 1 {
      let decay = exp(-omega * t)
      if d * (1 + omega * t) * decay < 0.25 && d * omega * omega * t * decay < 2 { return t }
      t += 1.0 / 240
    }
    return t
  }
}
