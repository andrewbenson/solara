import AppKit
import SwiftUI

private struct IntroClockKey: EnvironmentKey {
  static let defaultValue: Double? = nil
}

extension EnvironmentValues {
  var onboardingIntroClock: Double? {
    get { self[IntroClockKey.self] }
    set { self[IntroClockKey.self] = newValue }
  }
}

struct OnboardingVisualEffect: NSViewRepresentable {
  func makeNSView(context: Context) -> NSVisualEffectView {
    let view = NSVisualEffectView()
    view.material = .fullScreenUI
    view.blendingMode = .withinWindow
    view.state = .followsWindowActiveState
    return view
  }

  func updateNSView(_ view: NSVisualEffectView, context: Context) {}
}

final class WindowDragNSView: NSView {
  var draggable = true
  override var mouseDownCanMoveWindow: Bool { draggable }
}

struct WindowDragArea: NSViewRepresentable {
  let draggable: Bool

  func makeNSView(context: Context) -> WindowDragNSView {
    let view = WindowDragNSView()
    view.draggable = draggable
    return view
  }

  func updateNSView(_ view: WindowDragNSView, context: Context) { view.draggable = draggable }
}

struct OnboardingCardDriver: ViewModifier, @MainActor Animatable {
  var card: Double

  var animatableData: Double {
    get { card }
    set { card = newValue }
  }

  func body(content: Content) -> some View {
    content
      .scaleEffect(rnInterpolate(card, [0, 1, 2], [0.97, 1, 1.03]))
      .offset(y: rnInterpolate(card, [0, 1, 2], [24, 0, 0]))
      .opacity(rnInterpolate(card, [0, 1, 2], [0, 1, 0]))
  }
}

public struct OnboardingOverlayView: View {
  let model: OnboardingModel
  let windowId: String

  public init(model: OnboardingModel, windowId: String) {
    self.model = model
    self.windowId = windowId
  }

  public var body: some View {
    if model.isActive(in: windowId) {
      OnboardingOverlay(model: model, session: model.session).id(model.session)
    }
  }
}

struct OnboardingOverlay: View {
  static let card = (width: 880.0, height: 560.0, margin: 40.0)

  @Environment(\.colorScheme) private var scheme
  @Environment(\.onboardingSettled) private var settled
  let model: OnboardingModel
  let session: Int
  @State private var presence = 0.0
  @State private var card = 0.0

  var body: some View {
    let colors = OnboardingColors.of(scheme)
    let intro = model.step == .intro && model.syncRoute == .setup
    GeometryReader { proxy in
      let width = min(Self.card.width, max(0, proxy.size.width - Self.card.margin * 2))
      let height = min(Self.card.height, max(0, proxy.size.height - Self.card.margin * 2))
      ZStack {
        OnboardingVisualEffect()
        Rectangle().fill(colors.overlay)
        WindowDragArea(draggable: true)
        if !intro && width > 0 {
          ZStack {
            WindowDragArea(draggable: false)
            if model.syncRoute == .setup {
              OnboardingStepView(model: model).id(stepIdentity)
            } else {
              OnboardingSyncView(model: model)
            }
          }
          .frame(width: width, height: height)
          .background(RoundedRectangle(cornerRadius: 20, style: .continuous).fill(colors.card))
          .clipShape(RoundedRectangle(cornerRadius: 20, style: .continuous))
          .overlay(RoundedRectangle(cornerRadius: 20, style: .continuous).strokeBorder(colors.cardBorder, lineWidth: 0.5))
          .background(RoundedRectangle(cornerRadius: 20, style: .continuous).fill(colors.card).shadow(color: .black.opacity(0.28), radius: 40, x: 0, y: 18))
          .modifier(OnboardingCardDriver(card: settled ? 1 : card))
        }
        if intro {
          OnboardingIntroView(model: model) {
            if model.step == .intro, model.syncRoute == .setup { model.go(.source) }
          }
        }
      }
      .frame(width: proxy.size.width, height: proxy.size.height)
      .overlay(alignment: .topTrailing) {
        if model.syncRoute == .setup, model.isFirstRunOnboarding {
          Button("Use Sync Instead…") { model.discoverSync() }
            .buttonStyle(.plain)
            .font(.system(size: 12))
            .padding(24)
        }
      }
    }
    .opacity(settled ? 1 : presence)
    .onAppear {
      withAnimation(.rn(260, .outQuad)) { presence = 1 }
      if !intro { withAnimation(.rnSpring(friction: 9, tension: 60)) { card = 1 } }
    }
    .onChange(of: intro) { _, now in
      if now {
        card = 0
      } else {
        withAnimation(.rnSpring(friction: 9, tension: 60)) { card = 1 }
      }
    }
    .onChange(of: model.leaving) { _, leaving in
      guard leaving else { return }
      withAnimation(.rn(420, .inCubic)) {
        presence = 0
        card = 2
      } completion: {
        model.dismiss(session: session)
      }
    }
  }

  var stepIdentity: String { model.step == .home ? "home-\(model.sub)" : model.step.rawValue }
}

struct OnboardingIntroView: View {
  @Environment(\.colorScheme) private var scheme
  @Environment(\.onboardingIntroClock) private var frozen
  let model: OnboardingModel
  let onDone: () -> Void
  @State private var start = Date()
  @State private var skipped: (at: Double, exit: Double, date: Date)?
  @State private var done = false
  @State private var timer: Task<Void, Never>?

  static let skipDuration = 280.0
  static let iconSpring = SpringParams.origami(friction: 7, tension: 50)

  var cues: IntroMusicCues { IntroMusicCues(letterCount: model.copy.wordmark.count) }

  var body: some View {
    TimelineView(.animation(minimumInterval: nil, paused: frozen != nil || done)) { context in
      frame(at: context.date)
    }
    .onAppear {
      guard frozen == nil else { return }
      start = Date()
      model.services.playIntroMusic(cues, muted: model.introMusicMuted)
      let end = cues.end
      timer = Task { @MainActor in
        try? await Task.sleep(for: .milliseconds(Int(end * 1000)))
        guard !Task.isCancelled else { return }
        if skipped == nil { finish() }
      }
    }
    .onDisappear {
      timer?.cancel()
      done = true
    }
  }

  func finish() {
    if done { return }
    done = true
    onDone()
  }

  func skip() {
    guard skipped == nil, !done else { return }
    model.services.stopIntroMusic(fade: 0.35)
    let elapsed = Date().timeIntervalSince(start)
    skipped = (elapsed, values(at: elapsed).exit, Date())
    timer?.cancel()
    timer = Task { @MainActor in
      try? await Task.sleep(for: .milliseconds(Int(Self.skipDuration)))
      guard !Task.isCancelled else { return }
      finish()
    }
  }

  struct Values {
    var icon: Double
    var letters: [Double]
    var tagline: Double
    var exit: Double
  }

  func values(at t: Double) -> Values {
    let cues = cues
    let icon = t < cues.icon ? 0 : RNSpring.solve(Self.iconSpring, from: 0, to: 1, initialVelocity: 0, t: t - cues.icon).0
    let letters = (0..<cues.letterCount).map { i in RNEasing.outCubic((t - cues.letters - Double(i) * cues.letterStep) / IntroMusicCues.letterDuration) }
    let tagline = RNEasing.outCubic((t - cues.tagline) / IntroMusicCues.taglineDuration)
    let exit = RNEasing.inOutCubic((t - cues.exit) / IntroMusicCues.exitDuration)
    return Values(icon: icon, letters: letters, tagline: tagline, exit: exit)
  }

  func current(_ date: Date) -> Values {
    if let frozen { return values(at: frozen) }
    if let skipped {
      var v = values(at: skipped.at)
      let p = RNEasing.outQuad(date.timeIntervalSince(skipped.date) * 1000 / Self.skipDuration)
      v.exit = skipped.exit + (1 - skipped.exit) * p
      return v
    }
    return values(at: date.timeIntervalSince(start))
  }

  @ViewBuilder
  func frame(at date: Date) -> some View {
    let colors = OnboardingColors.of(scheme)
    let v = current(date)
    let wordmark = Array(model.copy.wordmark)
    ZStack {
      colors.background
      Group {
        if let provider = model.powerUpView {
          provider(PowerUpSpec(palette: PowerUpSpec.diaSpectrum, speed: 0.8, origin: 0.5))
        } else {
          PowerUpFallback(palette: PowerUpSpec.diaSpectrum)
        }
      }
      .opacity(scheme == .dark ? 0.9 : 0.6)
      .allowsHitTesting(false)
      VStack(spacing: 18) {
        OnboardingAppIconImage(model: model, size: 96)
          .scaleEffect(0.6 + 0.4 * v.icon)
          .opacity(rnInterpolate(v.icon, [0, 0.4, 1], [0, 1, 1], clamp: true))
        HStack(spacing: 0) {
          ForEach(wordmark.indices, id: \.self) { i in
            Text(String(wordmark[i]))
              .font(OnboardingFont.system(64, 200))
              .kerning(-1.5)
              .foregroundStyle(colors.title)
              .opacity(v.letters[i])
              .offset(y: 14 * (1 - v.letters[i]))
          }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(model.copy.wordmark)
        Text("Your new home on the internet")
          .font(OnboardingFont.system(17, 300))
          .foregroundStyle(colors.subtitle)
          .opacity(v.tagline)
          .offset(y: 6 * (1 - v.tagline))
      }
      .scaleEffect(1 + 0.08 * v.exit)
      VStack {
        Spacer()
        HStack {
          OnboardingCircleButton(
            symbol: model.introMuted ? "speaker.slash.fill" : "speaker.wave.3.fill", size: 13, box: 20, weight: .medium,
            label: model.introMuted ? "Unmute intro music" : "Mute intro music"
          ) { model.toggleIntroMute() }
          .help(model.introMuted ? "Unmute intro music" : "Mute intro music")
          Spacer()
          OnboardingSecondaryButton(title: "Skip") { skip() }
            .accessibilityHint("Button that skips the onboarding intro animation")
        }
        .padding(28)
      }
    }
    .opacity(rnInterpolate(v.exit, [0, 0.6, 1], [1, 1, 0]))
  }
}

struct PowerUpFallback: View {
  let palette: [String]

  var body: some View {
    let colors = palette.map(PreviewColor.color)
    ZStack {
      RadialGradient(colors: colors.map { $0.opacity(0.35) } + [.clear], center: .bottom, startRadius: 0, endRadius: 700)
      LinearGradient(colors: [.clear, colors.first?.opacity(0.18) ?? .clear], startPoint: .top, endPoint: .bottom)
    }
  }
}
