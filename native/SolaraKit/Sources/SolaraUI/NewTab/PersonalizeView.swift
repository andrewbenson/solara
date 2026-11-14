import AppKit
import SwiftUI

public struct PersonalizeState: Decodable, Equatable, Sendable {
  public var open: Bool
  public var dark: Bool
  public var tokens: [String: String]
  public var color: String?
  public var layout: String
  public var canPickColor: Bool
  public var profileId: String?

  public static func decode(_ json: String) -> PersonalizeState? {
    guard let data = json.data(using: .utf8), let value = try? JSONDecoder().decode(Self.self, from: data), ["sidebar", "top"].contains(value.layout) else { return nil }
    return value
  }
}

public final class PersonalizeView: NSView {
  public private(set) var state: PersonalizeState?
  public var onOpen: (Bool) -> Void = { _ in }
  public var onColor: (String) -> Void = { _ in }
  public var onLayout: (String) -> Void = { _ in }
  private let palette = PersonalizeControl()
  private let glyph = NSImageView()
  private var panel: NSHostingView<PersonalizePanel>?
  private var hovered = false
  private var pressed = false
  private var presentation = UUID()
  public var buttonFrame: CGRect { palette.frame }
  public var panelFrame: CGRect? { panel?.frame }
  public override var isFlipped: Bool { true }

  public override init(frame: NSRect) {
    super.init(frame: frame)
    wantsLayer = true
    palette.wantsLayer = true
    palette.layer?.cornerRadius = 15
    palette.setAccessibilityLabel("Personalize")
    palette.toolTip = "Personalize"
    palette.onPress = { [weak self] in
      guard let self, let state = self.state else { return }
      self.onOpen(!state.open)
    }
    palette.onHover = { [weak self] in self?.hovered = $0; self?.refreshPalette() }
    palette.onPressed = { [weak self] in self?.pressed = $0; self?.refreshPalette() }
    glyph.image = NSImage(systemSymbolName: "paintpalette", accessibilityDescription: nil)?.withSymbolConfiguration(.init(pointSize: 14, weight: .regular))
    glyph.imageScaling = .scaleNone
    glyph.setAccessibilityElement(false)
    palette.addSubview(glyph)
    addSubview(palette)
    isHidden = true
  }

  public required init?(coder: NSCoder) { nil }

  public func update(_ state: PersonalizeState?) {
    if self.state?.profileId != state?.profileId || self.state?.open != state?.open || self.state?.canPickColor != state?.canPickColor { presentation = UUID() }
    self.state = state
    isHidden = state == nil
    guard let state else {
      if let focused = window?.firstResponder as? NSView, focused === self || focused.isDescendant(of: self) { window?.makeFirstResponder(nil) }
      panel?.removeFromSuperview()
      panel = nil
      return
    }
    if state.open {
      let presented = presentation
      let root = PersonalizePanel(state: state, onColor: { [weak self] color in
        guard let self, self.presentation == presented, self.state?.open == true else { return }
        self.onColor(color.rawValue)
      }, onLayout: { [weak self] layout in
        guard let self, self.presentation == presented, self.state?.open == true else { return }
        self.onLayout(layout)
      })
      if let panel { panel.rootView = root }
      else {
        let hosting = NSHostingView(rootView: root)
        hosting.safeAreaRegions = []
        hosting.wantsLayer = true
        panel = hosting
        addSubview(hosting)
      }
    } else if let panel {
      if let focused = window?.firstResponder as? NSView, focused === panel || focused.isDescendant(of: panel) { window?.makeFirstResponder(palette) }
      panel.removeFromSuperview()
      self.panel = nil
    }
    needsLayout = true
    layoutSubtreeIfNeeded()
    refreshPalette()
    window?.recalculateKeyViewLoop()
  }

  public override func layout() {
    super.layout()
    palette.frame = CGRect(x: bounds.width - 46, y: bounds.height - 44.5, width: 30, height: 30)
    glyph.frame = palette.bounds
    if let panel {
      panel.frame.size = CGSize(width: 352, height: 400)
      let height = panel.fittingSize.height
      panel.frame = CGRect(x: bounds.width - 368, y: bounds.height - 54 - height, width: 352, height: height)
    }
  }

  public override func hitTest(_ point: NSPoint) -> NSView? {
    guard !isHidden, let state else { return nil }
    let local = convert(point, from: superview)
    if palette.frame.contains(local) { return palette }
    if let panel, panel.frame.contains(local) { return panel.hitTest(local) ?? panel }
    return state.open && bounds.contains(local) ? self : nil
  }

  public override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
  public override func mouseDown(with event: NSEvent) { if state?.open == true { onOpen(false) } }
  public override func keyDown(with event: NSEvent) {
    if event.keyCode == 53, state?.open == true { onOpen(false) }
    else { super.keyDown(with: event) }
  }

  private func refreshPalette() {
    guard let state else { return }
    let theme = NewTabTheme(dark: state.dark, tokens: state.tokens)
    palette.layer?.backgroundColor = pressed ? theme.toolbarPressed.cg : hovered || state.open ? theme.toolbarHover.cg : nil
    glyph.contentTintColor = (hovered || state.open ? theme.icon : theme.textTertiary).ns
    palette.setAccessibilityValue(state.open ? 1 : 0)
  }


}

private struct PersonalizePanel: View {
  let state: PersonalizeState
  let onColor: (ProfileColorValue) -> Void
  let onLayout: (String) -> Void
  @State private var shown = 0.0

  private func color(_ key: String, _ fallback: String) -> Color { (state.tokens[key].flatMap(CSSColor.init) ?? CSSColor(fallback)!).color }

  var body: some View {
    VStack(alignment: .leading, spacing: 16) {
      VStack(alignment: .leading, spacing: 4) {
        OnboardingText(PersonalizeCopy.title, size: 15, weight: 600, color: color("textPrimary", state.dark ? "#FFFFFF" : "#000000"))
        OnboardingText(PersonalizeCopy.subtitle, size: 12, color: color("textSecondary", state.dark ? "#999999" : "#666666"), lineHeight: 17)
      }
      if state.canPickColor { ThemeColorPicker(current: state.color.flatMap(ProfileColorValue.init), size: 28, onPick: onColor) }
      VStack(alignment: .leading, spacing: 8) {
        OnboardingText(PersonalizeCopy.layouts, size: 12, color: color("textSecondary", state.dark ? "#999999" : "#666666"))
        TabLayoutPicker(layout: state.layout, onPick: onLayout)
      }
    }
    .padding(18.5)
    .frame(width: 352, alignment: .leading)
    .background { PersonalizeSurface(state: state).accessibilityHidden(true) }
    .environment(\.colorScheme, state.dark ? .dark : .light)
    .fixedSize(horizontal: false, vertical: true)
    .opacity(min(1, max(0, shown)))
    .scaleEffect(0.97 + 0.03 * shown)
    .offset(y: 8 * (1 - shown))
    .onAppear {
      if NSWorkspace.shared.accessibilityDisplayShouldReduceMotion { shown = 1 }
      else { withAnimation(.rnSpring(friction: 9, tension: 90)) { shown = 1 } }
    }
  }
}

private struct PersonalizeSurface: NSViewRepresentable {
  let state: PersonalizeState

  func makeNSView(context: Context) -> BarSurfaceView {
    let view = BarSurfaceView(frame: .zero)
    updateNSView(view, context: context)
    return view
  }

  func updateNSView(_ view: BarSurfaceView, context: Context) {
    view.fill = (state.tokens["panel"].flatMap(CSSColor.init) ?? CSSColor(state.dark ? "#2A2A2A" : "#FFFFFF")!).ns
    view.radius = 16
    view.borderColor = (state.tokens["panelBorder"].flatMap(CSSColor.init) ?? CSSColor(state.dark ? "#FFFFFF1A" : "#0000001A")!).ns
    view.borderWidth = 0.5
    view.shadowColor = .black
    view.shadowOpacity = Double(state.tokens["panelShadowOpacity"] ?? "") ?? (state.dark ? 0.5 : 0.18)
    view.shadowRadius = 24
    view.shadowOffset = CGSize(width: 0, height: 10)
  }
}
