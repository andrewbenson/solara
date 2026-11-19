import AppKit
import SwiftUI

public struct SidebarSurfaceLook: Decodable, Equatable, Sendable {
  public var dark: Bool
  public var panel: String
  public var panelBorder: String
  public var shadowOpacity: Double

  public init(dark: Bool, panel: String, panelBorder: String, shadowOpacity: Double) {
    self.dark = dark
    self.panel = panel
    self.panelBorder = panelBorder
    self.shadowOpacity = shadowOpacity
  }
}

public class SidebarHoverSurfaceView: NSView {
  public static let padding: CGFloat = 12
  public static let border: CGFloat = 0.5
  static var inset: CGFloat { padding + border }
  public var onPointer: ((Bool) -> Void)?
  public var onResize: (() -> Void)?
  private let surface = SurfaceLayer()
  private let controller = NSHostingController(rootView: AnyView(EmptyView()))
  private var hosting: NSView { controller.view }
  private var tracking: NSTrackingArea?
  private var inside = false
  private var bodyHeight: CGFloat = 0

  public override var isFlipped: Bool { true }

  init() {
    controller.sizingOptions = []
    super.init(frame: .zero)
    wantsLayer = true
    layer?.masksToBounds = false
    surface.radius = 12
    surface.border = Self.border
    surface.glowColor = .black
    surface.glowRadius = 16
    surface.glowOffset = CGSize(width: 0, height: 6)
    layer?.addSublayer(surface)
    addSubview(hosting)
    DevPointer.observe(self, #selector(devPointer(_:)))
  }

  required init?(coder: NSCoder) { fatalError() }

  public var height: CGFloat { frame.height }

  func present(_ content: some View, width: CGFloat, look: SidebarSurfaceLook) {
    controller.rootView = AnyView(content)
    surface.fill = CSSColor(look.panel)?.ns
    surface.borderTint = CSSColor(look.panelBorder)?.ns
    surface.glowOpacity = look.shadowOpacity * 0.8
    hosting.appearance = NSAppearance(named: look.dark ? .darkAqua : .aqua)
    let inner = width - Self.inset * 2
    bodyHeight = controller.sizeThatFits(in: NSSize(width: inner, height: 10_000)).height
    setFrameSize(NSSize(width: width, height: bodyHeight + Self.inset * 2))
    needsLayout = true
  }

  func bodyChanged(_ height: CGFloat) {
    guard abs(height - bodyHeight) > 0.25 else { return }
    bodyHeight = height
    setFrameSize(NSSize(width: frame.width, height: height + Self.inset * 2))
    needsLayout = true
    onResize?()
  }

  public override func layout() {
    super.layout()
    PrimitiveMotion.setInstantly { surface.frame = bounds }
    hosting.frame = bounds.insetBy(dx: Self.inset, dy: Self.inset)
  }

  public override func updateTrackingAreas() {
    super.updateTrackingAreas()
    if let tracking { removeTrackingArea(tracking) }
    let area = NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect], owner: self)
    addTrackingArea(area)
    tracking = area
  }

  public override func mouseEntered(with event: NSEvent) { pointer(isHitBy(event)) }
  public override func mouseExited(with event: NSEvent) { pointer(false) }

  public override func viewDidMoveToWindow() {
    super.viewDidMoveToWindow()
    if window == nil { pointer(false) }
  }

  @objc private func devPointer(_ note: Notification) { pointer(DevPointer.inside(self, note)) }

  private func pointer(_ on: Bool) {
    guard on != inside else { return }
    inside = on
    onPointer?(on)
  }

  public override func mouseDown(with event: NSEvent) {}
}

public final class SidebarCalendarCardView: SidebarHoverSurfaceView {
  public static let width: CGFloat = 300
  public var onEvent: ((LiveCardEvent) -> Void)?
  public private(set) var state: LiveCardModel.State?
  public private(set) var tabId: String?

  public override init() { super.init() }

  required init?(coder: NSCoder) { fatalError() }

  public func set(tabId: String, state next: LiveCardModel.State, look: SidebarSurfaceLook) {
    self.tabId = tabId
    state = next
    let body = SidebarCalendarCardBody(state: next, onEvent: { [weak self] in self?.onEvent?($0) }, onHeight: { [weak self] in self?.bodyChanged($0) })
    present(body, width: Self.width, look: look)
  }
}

struct SidebarCalendarCardBody: View {
  let state: LiveCardModel.State
  let onEvent: (LiveCardEvent) -> Void
  let onHeight: (CGFloat) -> Void

  var body: some View {
    CalendarPreviewCard(state: state, onEvent: onEvent)
      .frame(maxWidth: .infinity, alignment: .topLeading)
      .fixedSize(horizontal: false, vertical: true)
      .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { onHeight($0) }
      .preferredColorScheme(state.dark ? .dark : .light)
  }
}
