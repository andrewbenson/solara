import AppKit
import SwiftUI

public struct ToolTourView: View {
  let model: ToolTourModel
  @State private var presence = 0.0
  @State private var hole = CGRect.zero
  @State private var radius = 0.0
  @State private var card = CGPoint.zero
  @State private var placedSession: Int?

  static let moveSpring = Animation.rnSpring(friction: 10, tension: 70)

  public init(model: ToolTourModel) {
    self.model = model
  }

  public var body: some View {
    ZStack(alignment: .topLeading) {
      if model.visible, let stop = model.stop {
        let theme = model.theme
        TourScrimShape(hole: hole, radius: radius)
          .fill(Color.black.opacity(theme.dark ? 128.0 / 255 : 77.0 / 255), style: FillStyle(eoFill: true))
          .allowsHitTesting(false)
        if stop.anchored { TourRing(hole: hole, radius: radius) }
        TourCoachMark(model: model, stop: stop)
          .frame(width: ToolTourLayout.cardWidth)
          .fixedSize(horizontal: false, vertical: true)
          .onGeometryChange(for: Double.self, of: { Double($0.size.height.rounded()) }, action: { model.cardHeight = $0 })
          .offset(x: card.x, y: card.y)
      }
    }
    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    #if SOLARA_PROBES
    .coordinateSpace(name: "ToolTourProbe")
    #endif
    .opacity(placedSession == model.session ? presence : 0)
    .environment(\.colorScheme, model.theme.dark ? .dark : .light)
    .onGeometryChange(for: CGSize.self, of: { $0.size }, action: { model.size = $0 })
    .onChange(of: model.visible, initial: true) { _, visible in
      if visible {
        withAnimation(.rn(240, .outQuad)) { presence = 1 }
      } else {
        presence = 0
        placedSession = nil
      }
    }
    .onChange(of: Placement(model: model), initial: true) { _, next in place(next) }
  }

  struct Placement: Equatable {
    var hole: ToolTourHole
    var card: CGPoint
    var session: Int
    var measured: Bool
    var visible: Bool

    @MainActor init(model: ToolTourModel) {
      hole = model.hole
      card = model.cardOrigin
      session = model.session
      measured = model.cardHeight != nil
      visible = model.visible && model.size.width > 0
    }
  }

  private func place(_ next: Placement) {
    guard next.visible, next.measured else { return }
    if placedSession != next.session {
      var instant = Transaction()
      instant.disablesAnimations = true
      withTransaction(instant) {
        hole = next.hole.rect
        radius = next.hole.radius
        card = next.card
        placedSession = next.session
      }
      return
    }
    withAnimation(Self.moveSpring) {
      hole = next.hole.rect
      radius = next.hole.radius
      card = next.card
    }
  }
}

struct TourScrimShape: Shape {
  var hole: CGRect
  var radius: Double

  var animatableData: AnimatablePair<CGRect.AnimatableData, Double> {
    get { AnimatablePair(hole.animatableData, radius) }
    set {
      hole.animatableData = newValue.first
      radius = newValue.second
    }
  }

  func path(in rect: CGRect) -> Path {
    var path = Path(rect)
    let r = max(0, min(radius, min(hole.width, hole.height) / 2))
    path.addRoundedRect(in: hole, cornerSize: CGSize(width: r, height: r), style: .circular)
    return path
  }
}

struct TourRing: View {
  let hole: CGRect
  let radius: Double
  @State private var start = Date()

  static let outset = 3.0
  static let halfPeriod = 1.1

  static func opacity(at elapsed: TimeInterval) -> Double {
    let phase = elapsed.truncatingRemainder(dividingBy: halfPeriod * 2)
    let u = phase < halfPeriod ? phase / halfPeriod : 2 - phase / halfPeriod
    let eased = (1 - cos(Double.pi * u)) / 2
    return 0.45 + 0.55 * eased
  }

  var body: some View {
    TimelineView(.animation) { context in
      RoundedRectangle(cornerRadius: max(0, radius) + Self.outset, style: .circular)
        .strokeBorder(Color.white.opacity(179.0 / 255), lineWidth: 1.5)
        .opacity(Self.opacity(at: context.date.timeIntervalSince(start)))
    }
    .frame(width: hole.width + Self.outset * 2, height: hole.height + Self.outset * 2)
    .offset(x: hole.minX - Self.outset, y: hole.minY - Self.outset)
    .allowsHitTesting(false)
  }
}

struct TourCoachMark: View {
  let model: ToolTourModel
  let stop: ToolTourStop

  var body: some View {
    let theme = model.theme
    let colors = OnboardingColors.of(theme.dark ? .dark : .light)
    let index = model.index
    let last = model.last
    VStack(alignment: .leading, spacing: 7) {
      OnboardingText("\(index + 1) OF \(model.stops.count)", size: 10.5, weight: 600, color: theme.textTertiary, kerning: 0.4)
      OnboardingText(stop.title, size: 15, weight: 600, color: theme.textPrimary, kerning: -0.1)
      OnboardingText(stop.body, size: 12.5, color: theme.textSecondary, lineHeight: 18)
      HStack(spacing: 6) {
        if !last {
          TourTextButton(title: "Skip Tour", theme: theme) { model.send("skip") }
            #if SOLARA_PROBES
            .modifier(TourControlProbe(model: model, label: "Skip Tour"))
            #endif
        }
        Spacer(minLength: 0)
        if last && model.video {
          TourPillButton(title: "Watch Video Tour", primary: false, colors: colors) { model.send("video") }
            #if SOLARA_PROBES
            .modifier(TourControlProbe(model: model, label: "Watch Video Tour"))
            #endif
        }
        if index > 0 && !last {
          TourPillButton(title: "Back", primary: false, colors: colors) { model.send("back") }
            #if SOLARA_PROBES
            .modifier(TourControlProbe(model: model, label: "Back"))
            #endif
        }
        TourPillButton(title: last ? "Done" : "Next", primary: true, colors: colors) { model.send("next") }
          #if SOLARA_PROBES
          .modifier(TourControlProbe(model: model, label: last ? "Done" : "Next"))
          #endif
      }
      .padding(.top, 7)
    }
    .padding(.horizontal, 18)
    .padding(.top, 15)
    .padding(.bottom, 14)
    .padding(0.5)
    .background {
      RoundedRectangle(cornerRadius: 14, style: .circular)
        .fill(theme.panel.color)
        .overlay { RoundedRectangle(cornerRadius: 14, style: .circular).strokeBorder(theme.panelBorder.color, lineWidth: 0.5) }
        .shadow(color: .black.opacity(theme.panelShadowOpacity), radius: 24, y: 10)
    }
  }
}

#if SOLARA_PROBES
private struct TourControlProbe: ViewModifier {
  let model: ToolTourModel
  let label: String

  func body(content: Content) -> some View {
    let session = model.session
    let index = model.index
    return content.onGeometryChange(for: ToolTourControlSample.self, of: { proxy in
      ToolTourControlSample(frame: proxy.frame(in: .named("ToolTourProbe")), session: session, index: index)
    }, action: { sample in
      model.recordControlFrame(label, frame: sample.frame, session: sample.session, index: sample.index)
    })
  }
}
#endif

struct TourPillButton: View {
  let title: String
  let primary: Bool
  let colors: OnboardingColors
  let action: () -> Void

  var body: some View {
    OnboardingPressable(action: action) { hovered, pressed in
      OnboardingText(title, size: 12, weight: 600, color: primary ? colors.primaryText : colors.buttonText)
        .padding(.horizontal, 13)
        .frame(height: 28)
        .background(Capsule(style: .circular).fill(primary ? (hovered ? colors.primaryHover : colors.primary) : hovered ? colors.buttonHover : colors.button))
        .scaleEffect(pressed ? 0.97 : 1)
        .contentShape(Capsule(style: .circular))
    }
    .accessibilityLabel(title)
  }
}

struct TourTextButton: View {
  let title: String
  let theme: PageTheme
  let action: () -> Void

  var body: some View {
    OnboardingPressable(action: action) { hovered, _ in
      OnboardingText(title, size: 12, weight: 500, color: hovered ? theme.textPrimary : theme.textTertiary)
        .padding(.vertical, 6)
        .contentShape(Rectangle())
    }
    .accessibilityLabel(title)
  }
}

@MainActor
public final class ToolTourHost: NSHostingView<ToolTourView> {
  public let model: ToolTourModel

  public init(model: ToolTourModel = ToolTourModel()) {
    self.model = model
    super.init(rootView: ToolTourView(model: model))
    sizingOptions = []
    safeAreaRegions = []
  }

  @available(*, unavailable)
  public required init(rootView: ToolTourView) { fatalError() }

  @available(*, unavailable)
  public required init?(coder: NSCoder) { nil }

  override public func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

  override public func hitTest(_ point: NSPoint) -> NSView? {
    let local = convert(point, from: superview)
    guard bounds.contains(local), !model.passesThrough(local) else { return nil }
    return super.hitTest(point) ?? self
  }
}
