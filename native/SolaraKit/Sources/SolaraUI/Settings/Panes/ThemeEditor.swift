import SwiftUI

struct ThemeEditorState {
  let stored: ProfileThemeValue?
  let editsDark: Bool
  let custom: ProfileThemeValue?
  let shown: ShownThemeLook?

  init(stored: ProfileThemeValue?, appDark: Bool, source: ThemeLookSource) {
    self.stored = stored
    let dark = stored.map { ThemeMath.requestedDark($0, appDark: appDark, source: source) } ?? false
    editsDark = dark
    custom = stored.map { $0.dark != nil ? ThemeMath.resolve($0, dark: dark) : $0 }
    shown = stored.map { ThemeMath.shown($0, appDark: appDark, source: source) }
  }

  func colorDescription(preset: ProfileColorValue) -> String {
    if stored?.dark != nil { return "Separate light and dark looks. Editing keeps the \(editsDark ? "dark" : "light") one." }
    if custom != nil { return "Custom gradient" }
    return preset.name
  }
}

struct ThemeSection: View {
  @Environment(\.settingsContext) private var context
  let model: ProfilesPaneModel
  let profile: ProfileSummary

  var body: some View {
    let state = ThemeEditorState(stored: model.editedTheme(profile.id), appDark: model.services.appDark, source: model.lookSource)
    let fileTheme = context?.store.fileTheme(profile: profile.id)
    SettingsSection("Theme", description: "Tints this profile's windows, New Tab page and highlights.") {
      Menu("Import from Arc…") {
        if let choices = model.arcChoices, !choices.isEmpty {
          ForEach(choices) { choice in
            Button {
              model.importArcTheme(profile.id, choice)
            } label: {
              Label {
                Text(choice.title)
              } icon: {
                Image(systemName: "circle.fill")
              }
              .foregroundStyle(Color(themeHex: ThemeMath.accent(choice.theme)))
            }
          }
        } else {
          Button("No Arc spaces with a theme found") {}
            .disabled(true)
        }
      }
      .fixedSize()
      .disabled(fileTheme != nil)
    } content: {
      if let fileTheme {
        SettingRow(title: "From a theme file", description: .none) {
          SettingsFileNote(source: fileTheme)
        }
      }
      SettingRow(title: "Colour", description: .text(state.colorDescription(preset: profile.color))) {
        HStack(spacing: 7) {
          ForEach(ProfileColorValue.allCases, id: \.self) { color in
            Button {
              model.choosePreset(profile.id, color)
            } label: {
              ThemeSwatchRing(selected: state.custom == nil && profile.color == color, ring: Color(themeHex: color.swatch)) {
                Circle().fill(Color(themeHex: color.swatch))
              }
            }
            .buttonStyle(.plain)
            .help(color.name)
          }
          Button {
            if state.custom == nil {
              model.changeTheme(profile.id, ThemeMath.starting(swatch: profile.color.swatch), settle: true)
            }
          } label: {
            ThemeSwatchRing(selected: state.custom != nil, ring: Color(themeHex: state.custom.map(ThemeMath.accent) ?? "#8E8E93")) {
              let theme = state.custom ?? ThemeMath.rainbow
              ThemeSwatchLayer(services: model.services, spec: ThemeSwatchSpec(colors: ThemeMath.flatColors(theme), angle: state.custom.map(ThemeMath.lookAngle) ?? ThemeMath.defaultAngle))
                .clipShape(Circle())
            }
          }
          .buttonStyle(.plain)
          .help("Custom")
        }
        .disabled(fileTheme != nil)
      }
      if let custom = state.custom, let shown = state.shown {
        ThemeEditor(
          services: model.services,
          theme: custom,
          shown: shown,
          followsApp: model.lookSource == .app,
          change: { model.changeTheme(profile.id, $0, settle: $1) }
        )
        .disabled(fileTheme != nil)
        .onAppear { model.services.holdThemedWindowsKeyLook(true) }
        .onDisappear { model.services.holdThemedWindowsKeyLook(false) }
      }
    }
    .task(id: profile.id) { await model.loadArcChoices() }
  }
}

struct ThemeSwatchRing<Content: View>: View {
  let selected: Bool
  let ring: Color
  var size: CGFloat = 20
  @ViewBuilder let content: Content

  var body: some View {
    content
      .padding(4)
      .overlay(Circle().strokeBorder(selected ? ring : Color.clear, lineWidth: 2))
      .frame(width: size, height: size)
      .contentShape(Circle())
  }
}

struct ThemeSwatchLayer: View {
  let services: ProfilesServices
  let spec: ThemeSwatchSpec

  var body: some View {
    if let provided = services.themeSwatch(spec) {
      provided.allowsHitTesting(false)
    } else {
      ThemeSwatchFallback(spec: spec).allowsHitTesting(false)
    }
  }
}

struct ThemeSwatchFallback: View {
  let spec: ThemeSwatchSpec

  var body: some View {
    if spec.padLightness >= 0 {
      padWheel
    } else if spec.colors.count >= 4 {
      gradient
    } else if spec.grain > 0 {
      Color.gray.opacity(spec.grain * 0.25)
    } else {
      Color.clear
    }
  }

  private var colors: [Color] {
    stride(from: 0, to: spec.colors.count - 3, by: 4).map { i in
      Color(themeRGBA: ThemeRGBA(r: spec.colors[i], g: spec.colors[i + 1], b: spec.colors[i + 2], a: spec.colors[i + 3]))
    }
  }

  private var gradient: some View {
    let radians = spec.angle * .pi / 180
    let dx = sin(radians) / 2, dy = -cos(radians) / 2
    let stops = colors
    return ZStack {
      LinearGradient(colors: Array(stops.prefix(2)).count == 1 ? [stops[0], stops[0]] : Array(stops.prefix(2)), startPoint: UnitPoint(x: 0.5 - dx, y: 0.5 - dy), endPoint: UnitPoint(x: 0.5 + dx, y: 0.5 + dy))
      if stops.count > 2 {
        let overlay = (spec.angle + 45) * .pi / 180
        let ox = sin(overlay) / 2, oy = -cos(overlay) / 2
        LinearGradient(colors: [stops[2].opacity(0), stops[2]], startPoint: UnitPoint(x: 0.5 - ox, y: 0.5 - oy), endPoint: UnitPoint(x: 0.5 + ox, y: 0.5 + oy))
      }
    }
  }

  private var padWheel: some View {
    let hues = stride(from: 0.0, through: 1.0, by: 1.0 / 12).map { hue -> Color in
      let (r, g, b) = ThemeMath.hslToRgb(hue.truncatingRemainder(dividingBy: 1), 1, spec.padLightness)
      return Color(.sRGB, red: r, green: g, blue: b)
    }
    let gray = Color(.sRGB, white: spec.padLightness)
    return ZStack {
      AngularGradient(colors: hues, center: .center)
      RadialGradient(colors: [gray, gray.opacity(0)], center: .center, startRadius: 0, endRadius: 86)
    }
  }
}

struct ThemeEditor: View {
  static let pad: CGFloat = 172
  static let knob: CGFloat = 22
  static let label: CGFloat = 112

  let services: ProfilesServices
  let theme: ProfileThemeValue
  let shown: ShownThemeLook
  let followsApp: Bool
  let change: (ProfileThemeValue, Bool) -> Void
  @State private var selected = 0

  var body: some View {
    let index = min(selected, theme.stops.count - 1)
    HStack(alignment: .top, spacing: 18) {
      VStack(spacing: 8) {
        ThemeColorPad(services: services, theme: theme, selected: index, select: { selected = $0 }, change: change)
        ThemeLightnessBar(theme: theme, index: index, change: change)
        HStack {
          Text("\(theme.stops.count) of \(ThemeMath.maxStops) colors")
            .font(.system(size: 11.5))
            .foregroundStyle(.secondary)
          Spacer()
          HStack(spacing: 4) {
            Button {
              change(ThemeMath.withoutStop(theme, at: index), true)
              selected = max(0, index - 1)
            } label: {
              Image(systemName: "minus").frame(width: 12, height: 12)
            }
            .help("Remove Colour")
            .disabled(theme.stops.count <= 1)
            Button {
              change(ThemeMath.withAddedStop(theme), true)
              selected = theme.stops.count
            } label: {
              Image(systemName: "plus").frame(width: 12, height: 12)
            }
            .help("Add Colour")
            .disabled(theme.stops.count >= ThemeMath.maxStops)
          }
          .controlSize(.small)
        }
      }
      .frame(width: Self.pad)
      VStack(alignment: .leading, spacing: 11) {
        ThemePreview(services: services, shown: shown)
        ThemeSliderRow(label: "Intensity", value: theme.intensity) { v, settle in
          var next = theme
          next.intensity = v
          change(next, settle)
        }
        ThemeSliderRow(label: "Pass-through blur", value: theme.translucency) { v, settle in
          var next = theme
          next.translucency = v
          change(next, settle)
        }
        ThemeSliderRow(label: "Noise", value: theme.grain, change: { v, settle in
          var next = theme
          next.grain = v
          change(next, settle)
        }) {
          Picker("", selection: Binding(get: { theme.texture }, set: { texture in
            var next = theme
            next.texture = texture
            next.grain = theme.grain == 0 ? 0.5 : theme.grain
            change(next, true)
          })) {
            ForEach(ThemeTextureValue.allCases, id: \.self) { Text($0.title).tag($0) }
          }
          .labelsHidden()
          .pickerStyle(.menu)
          .fixedSize()
        }
        HStack(spacing: 0) {
          Text("Direction")
            .font(.system(size: 12))
            .frame(width: Self.label + 10, alignment: .leading)
          ThemeDirectionDial(angle: ThemeMath.lookAngle(theme)) { angle, settle in
            change(ThemeMath.withAngle(theme, angle), settle)
          }
        }
        HStack(spacing: 0) {
          Text("Appearance")
            .font(.system(size: 12))
            .frame(width: Self.label + 10, alignment: .leading)
          if followsApp {
            Text("Follows Settings › Appearance")
              .font(.system(size: 11))
              .foregroundStyle(.secondary)
              .lineLimit(2)
              .frame(maxWidth: .infinity, alignment: .leading)
          } else {
            Picker("", selection: Binding(get: { theme.mode }, set: { mode in
              var next = theme
              next.mode = mode
              change(next, true)
            })) {
              Image(systemName: "sun.max").help("Light").tag(ThemeModeValue.light)
              Image(systemName: "moon").help("Dark").tag(ThemeModeValue.dark)
              Image(systemName: "circle.lefthalf.filled").help("Match System").tag(ThemeModeValue.auto)
            }
            .labelsHidden()
            .pickerStyle(.segmented)
            .fixedSize()
          }
          if shown.dark != shown.requestedDark {
            Text("Kept \(shown.dark ? "dark" : "light") so text stays readable")
              .font(.system(size: 11))
              .foregroundStyle(.secondary)
              .lineLimit(2)
              .padding(.leading, 8)
              .frame(maxWidth: .infinity, alignment: .leading)
          }
        }
      }
      .frame(maxWidth: .infinity)
    }
    .padding(.vertical, 4)
  }
}

struct ThemePreview: View {
  let services: ProfilesServices
  let shown: ShownThemeLook

  var body: some View {
    let look = shown.look
    let dark = shown.dark
    ZStack(alignment: .topLeading) {
      Color(themeHex: ThemeMath.underColor(look, dark: dark))
      ThemeSwatchLayer(services: services, spec: ThemeSwatchSpec(colors: ThemeMath.flatColors(look), angle: ThemeMath.lookAngle(look)))
        .opacity(ThemeMath.layerAlpha(look))
      ThemeSwatchLayer(services: services, spec: ThemeSwatchSpec(colors: [], grain: ThemeMath.grainAlpha(look), texture: look.texture))
      VStack(alignment: .leading, spacing: 5) {
        ForEach([1.0, 0.7, 0.85], id: \.self) { width in
          Capsule(style: .circular)
            .fill(dark ? Color.white.opacity(0.35) : Color.black.opacity(0.18))
            .frame(width: 34 * width, height: 4)
        }
      }
      .padding(.leading, 8)
      .padding(.top, 10)
      GeometryReader { proxy in
        RoundedRectangle(cornerRadius: 6)
          .fill(dark ? Color(.sRGB, red: 18 / 255, green: 18 / 255, blue: 18 / 255, opacity: 0.72) : Color.white.opacity(0.82))
          .frame(width: max(0, proxy.size.width - 56), height: max(0, proxy.size.height - 12))
          .offset(x: 50, y: 6)
      }
    }
    .frame(height: 58)
    .clipShape(RoundedRectangle(cornerRadius: 9))
  }
}

struct ThemeSliderRow<Accessory: View>: View {
  let label: String
  let value: Double
  let change: (Double, Bool) -> Void
  let accessory: Accessory
  @State private var editing: Double?

  init(label: String, value: Double, change: @escaping (Double, Bool) -> Void, @ViewBuilder accessory: () -> Accessory) {
    self.label = label
    self.value = value
    self.change = change
    self.accessory = accessory()
  }

  var body: some View {
    HStack(spacing: 10) {
      Text(label)
        .font(.system(size: 12))
        .lineLimit(1)
        .frame(width: ThemeEditor.label, alignment: .leading)
      Slider(
        value: Binding(get: { editing ?? value }, set: { v in
          editing = v
          change(v, false)
        }),
        in: 0...1,
        onEditingChanged: { active in
          if !active, let last = editing {
            change(last, true)
            editing = nil
          }
        }
      )
      .labelsHidden()
      accessory
    }
  }
}

extension ThemeSliderRow where Accessory == EmptyView {
  init(label: String, value: Double, change: @escaping (Double, Bool) -> Void) {
    self.init(label: label, value: value, change: change) { EmptyView() }
  }
}

struct ThemeColorPad: View {
  let services: ProfilesServices
  let theme: ProfileThemeValue
  let selected: Int
  let select: (Int) -> Void
  let change: (ProfileThemeValue, Bool) -> Void
  @State private var dragging: Int?

  var body: some View {
    let pad = ThemeEditor.pad
    let knob = ThemeEditor.knob
    ZStack(alignment: .topLeading) {
      ThemeSwatchLayer(services: services, spec: ThemeSwatchSpec(colors: [], padLightness: ThemeMath.padLightness))
        .frame(width: pad, height: pad)
        .clipShape(Circle())
      ForEach(Array(theme.stops.enumerated()), id: \.offset) { i, stop in
        Circle()
          .fill(Color(themeRGBA: stop.color))
          .overlay(Circle().strokeBorder(Color.white, lineWidth: i == selected ? 3 : 2))
          .background(Circle().strokeBorder(Color.black.opacity(0.25), lineWidth: 1).padding(-3))
          .frame(width: knob, height: knob)
          .offset(x: stop.x * pad - knob / 2, y: stop.y * pad - knob / 2)
          .allowsHitTesting(false)
      }
    }
    .frame(width: pad, height: pad)
    .contentShape(Rectangle())
    .gesture(
      DragGesture(minimumDistance: 0)
        .onChanged { value in
          let point = Self.unit(value.location, pad: pad)
          if dragging == nil {
            let hit = Self.hit(theme.stops, at: point, pad: pad, knob: knob)
            let index = hit ?? selected
            dragging = index
            select(index)
            if hit != nil { return }
          }
          move(to: point, settle: false)
        }
        .onEnded { value in
          move(to: Self.unit(value.location, pad: pad), settle: true)
          dragging = nil
        }
    )
  }

  private func move(to point: (x: Double, y: Double), settle: Bool) {
    guard let index = dragging else { return }
    let p = ThemeMath.insidePad(x: point.x, y: point.y)
    change(ThemeMath.withStop(theme, at: index, x: p.x, y: p.y), settle)
  }

  static func unit(_ location: CGPoint, pad: CGFloat) -> (x: Double, y: Double) {
    (ThemeMath.clamp01(location.x / pad), ThemeMath.clamp01(location.y / pad))
  }

  static func hit(_ stops: [ThemeStopValue], at point: (x: Double, y: Double), pad: CGFloat, knob: CGFloat) -> Int? {
    stops.firstIndex { hypot(($0.x - point.x) * pad, ($0.y - point.y) * pad) <= knob / 2 + 3 }
  }
}

struct ThemeLightnessBar: View {
  static let steps = 24

  let theme: ProfileThemeValue
  let index: Int
  let change: (ProfileThemeValue, Bool) -> Void

  var body: some View {
    let stop = theme.stops[index]
    let value = ThemeMath.stopLightness(stop)
    GeometryReader { proxy in
      let width = max(1, proxy.size.width)
      ZStack(alignment: .leading) {
        HStack(spacing: 0) {
          ForEach(0..<Self.steps, id: \.self) { i in
            Rectangle().fill(Color(themeRGBA: ThemeMath.padColor(stop.x, stop.y, lightness: Double(i) / Double(Self.steps - 1))))
          }
        }
        .frame(height: 8)
        .clipShape(Capsule(style: .circular))
        Circle()
          .fill(Color(themeRGBA: stop.color))
          .overlay(Circle().strokeBorder(Color.white, lineWidth: 2))
          .background(Circle().strokeBorder(Color.black.opacity(0.25), lineWidth: 1).padding(-3))
          .frame(width: 14, height: 14)
          .offset(x: value * width - 7)
      }
      .frame(maxHeight: .infinity)
      .contentShape(Rectangle())
      .gesture(
        DragGesture(minimumDistance: 0)
          .onChanged { change(ThemeMath.withStopLightness(theme, at: index, ThemeMath.clamp01($0.location.x / width)), false) }
          .onEnded { change(ThemeMath.withStopLightness(theme, at: index, ThemeMath.clamp01($0.location.x / width)), true) }
      )
    }
    .frame(width: ThemeEditor.pad, height: 20)
    .help("Brightness")
  }
}

struct ThemeDirectionDial: View {
  static let size: CGFloat = 28

  let angle: Double
  let change: (Double, Bool) -> Void

  var body: some View {
    let size = Self.size
    HStack(spacing: 10) {
      ZStack {
        Circle()
          .fill(Color(nsColor: .controlColor))
          .overlay(Circle().strokeBorder(Color.primary.opacity(0.15), lineWidth: 1))
        Capsule(style: .circular)
          .fill(Color.accentColor)
          .frame(width: 2, height: size / 2 - 4)
          .offset(y: -(size / 2 - 4) / 2)
          .rotationEffect(.degrees(angle))
        Circle()
          .fill(Color.accentColor)
          .frame(width: 5, height: 5)
      }
      .frame(width: size, height: size)
      .contentShape(Circle())
      .gesture(
        DragGesture(minimumDistance: 0)
          .onChanged { change(Self.angle(at: $0.location), false) }
          .onEnded { change(Self.angle(at: $0.location), true) }
      )
      .help("Drag to turn the gradient")
      .accessibilityElement()
      .accessibilityLabel("Direction")
      .accessibilityValue("\(Int(ThemeMath.jsRound(angle)))°")
      .accessibilityAdjustableAction { direction in
        let by: Double = direction == .increment ? 1 : -1
        change((ThemeMath.jsRound(angle / 45) + by) * 45, true)
      }
      Text("\(Int(ThemeMath.jsRound(angle)))°")
        .font(.system(size: 11.5).monospacedDigit())
        .foregroundStyle(.secondary)
    }
  }

  static func angle(at location: CGPoint) -> Double {
    ThemeMath.snappedDialAngle(dx: location.x - size / 2, dy: location.y - size / 2)
  }
}
