import AppKit
import SwiftUI

enum PageButtonKind {
  case standard, primary, destructive, plain
}

struct PageButton: View {
  @Environment(\.pageTheme) private var theme
  let title: String
  var kind: PageButtonKind = .standard
  var disabled = false
  var icon: String?
  let action: () -> Void
  @State private var hovered = false

  var body: some View {
    Button(action: action) { EmptyView() }
      .buttonStyle(PageButtonStyle(title: title, kind: kind, icon: icon, hovered: hovered, theme: theme))
      .disabled(disabled)
      .opacity(disabled ? 0.45 : 1)
      .onHover { hovered = $0 }
      .focusEffectDisabled()
      .accessibilityLabel(title)
      .pageProbe(title)
  }
}

private struct PageButtonStyle: ButtonStyle {
  let title: String
  let kind: PageButtonKind
  let icon: String?
  let hovered: Bool
  let theme: PageTheme

  func makeBody(configuration: Configuration) -> some View {
    let pressed = configuration.isPressed
    let text: Color =
      switch kind {
      case .primary: .white
      case .destructive: theme.destructive
      case .plain: theme.accent
      case .standard: theme.textPrimary
      }
    let fill: Color? =
      switch kind {
      case .plain: nil
      case .primary: pressed ? theme.accentPressed : theme.accent
      default: pressed ? theme.controlPressed : hovered ? theme.controlHover : theme.control
      }
    let bordered = kind == .standard || kind == .destructive
    return HStack(spacing: 5) {
      if let icon {
        Image(systemName: icon).font(.system(size: 11)).foregroundStyle(text).frame(width: 13, height: 13)
      }
      Text(title)
        .font(.system(size: 13))
        .foregroundStyle(text)
        .underline(kind == .plain && hovered)
        .lineLimit(1)
        .fixedSize()
    }
    .offset(y: -0.5)
    .padding(.horizontal, kind == .plain ? 0 : bordered ? 11 : 10)
    .frame(height: kind == .plain ? nil : 22)
    .background {
      if let fill { RoundedRectangle(cornerRadius: 5.5, style: .circular).fill(fill) }
    }
    .overlay {
      if bordered { RoundedRectangle(cornerRadius: 5.5, style: .circular).strokeBorder(theme.controlBorder, lineWidth: 1) }
    }
    .contentShape(Rectangle())
  }
}

struct PageIconButton: View {
  @Environment(\.pageTheme) private var theme
  let icon: String
  var size: CGFloat = 15
  var box: CGFloat = 30
  var radius: CGFloat = 7
  var nudge: CGFloat = -0.5
  var tooltip: String?
  let action: () -> Void
  @State private var hovered = false

  var body: some View {
    Button(action: action) { EmptyView() }
      .buttonStyle(PageIconButtonStyle(icon: icon, size: size, box: box, radius: radius, nudge: nudge, hovered: hovered, theme: theme))
      .onHover { hovered = $0 }
      .focusEffectDisabled()
      .help(tooltip ?? "")
      .accessibilityLabel(tooltip ?? icon)
      .pageProbe(tooltip ?? icon)
  }
}

private struct PageIconButtonStyle: ButtonStyle {
  let icon: String
  let size: CGFloat
  let box: CGFloat
  let radius: CGFloat
  let nudge: CGFloat
  let hovered: Bool
  let theme: PageTheme

  func makeBody(configuration: Configuration) -> some View {
    let fill: Color = configuration.isPressed ? theme.toolbarPressed : hovered ? theme.toolbarHover : .clear
    return Image(systemName: icon)
      .font(.system(size: size))
      .foregroundStyle(theme.icon)
      .offset(y: nudge)
      .frame(width: box, height: box)
      .background(RoundedRectangle(cornerRadius: radius, style: .circular).fill(fill))
      .contentShape(Rectangle())
  }
}

struct PageCheckbox: View {
  @Environment(\.pageTheme) private var theme
  let on: Bool
  var label: String?
  var disabled = false
  let toggle: () -> Void

  var body: some View {
    Button(action: toggle) {
      HStack(spacing: 7) {
        ZStack {
          RoundedRectangle(cornerRadius: 3.5, style: .circular).fill(on ? theme.accent : theme.control)
          if !on { RoundedRectangle(cornerRadius: 3.5, style: .circular).strokeBorder(theme.controlBorder, lineWidth: 1) }
          if on { Image(systemName: "checkmark").font(.system(size: 9, weight: .bold)).foregroundStyle(.white) }
        }
        .frame(width: 14, height: 14)
        if let label { OnboardingText(label, size: 13, color: theme.textPrimary, lines: 1).fixedSize() }
      }
      .contentShape(Rectangle())
    }
    .buttonStyle(.plain)
    .focusEffectDisabled()
    .disabled(disabled)
    .opacity(disabled ? 0.45 : 1)
    .accessibilityElement(children: .ignore)
    .accessibilityLabel(label ?? "Select")
    .accessibilityAddTraits(.isToggle)
    .accessibilityValue(on ? "1" : "0")
    .pageProbe(label ?? "Select")
  }
}

struct PageOption: Identifiable, Equatable {
  let value: String
  let title: String
  var id: String { value }
}

struct PagePopUp: View {
  @Environment(\.pageTheme) private var theme
  let value: String
  let options: [PageOption]
  var minWidth: CGFloat = 120
  let onChange: (String) -> Void
  @State private var hovered = false

  var body: some View {
    Button { open() } label: { EmptyView() }
      .buttonStyle(PagePopUpStyle(title: options.first { $0.value == value }?.title ?? "", minWidth: minWidth, hovered: hovered, theme: theme))
      .onHover { hovered = $0 }
      .focusEffectDisabled()
      .accessibilityLabel(options.first { $0.value == value }?.title ?? "")
      .accessibilityAddTraits(.isButton)
  }

  private func open() {
    let menu = NSMenu()
    let target = PagePopUpTarget(onChange)
    for option in options {
      let item = NSMenuItem(title: option.title, action: #selector(PagePopUpTarget.pick(_:)), keyEquivalent: "")
      item.target = target
      item.representedObject = option.value
      item.state = option.value == value ? .on : .off
      menu.addItem(item)
    }
    objc_setAssociatedObject(menu, &PagePopUpTarget.key, target, .OBJC_ASSOCIATION_RETAIN)
    let event = NSApp.currentEvent
    guard let window = event?.window, let view = window.contentView else { return }
    menu.popUp(positioning: nil, at: view.convert(event?.locationInWindow ?? .zero, from: nil), in: view)
  }
}

final class PagePopUpTarget: NSObject {
  nonisolated(unsafe) static var key = 0
  let pick: (String) -> Void

  init(_ pick: @escaping (String) -> Void) {
    self.pick = pick
  }

  @objc func pick(_ item: NSMenuItem) {
    if let value = item.representedObject as? String { pick(value) }
  }
}

private struct PagePopUpStyle: ButtonStyle {
  let title: String
  let minWidth: CGFloat
  let hovered: Bool
  let theme: PageTheme

  func makeBody(configuration: Configuration) -> some View {
    let fill = configuration.isPressed ? theme.controlPressed : hovered ? theme.controlHover : theme.control
    return HStack(spacing: 6) {
      Text(title).font(.system(size: 13)).foregroundStyle(theme.textPrimary).lineLimit(1).frame(maxWidth: .infinity, alignment: .leading)
      ZStack {
        RoundedRectangle(cornerRadius: 4, style: .circular).fill(theme.accent)
        Image(systemName: "chevron.up.chevron.down").font(.system(size: 8, weight: .bold)).foregroundStyle(.white)
      }
      .frame(width: 16, height: 16)
    }
    .padding(.leading, 10)
    .padding(.trailing, 5)
    .frame(minWidth: minWidth, minHeight: 22, maxHeight: 22)
    .fixedSize()
    .background(RoundedRectangle(cornerRadius: 5.5, style: .circular).fill(fill))
    .overlay(RoundedRectangle(cornerRadius: 5.5, style: .circular).strokeBorder(theme.controlBorder, lineWidth: 1))
    .contentShape(Rectangle())
  }
}

struct PageSearchField: View {
  @Environment(\.pageTheme) private var theme
  @Binding var text: String
  let placeholder: String
  var focus: Int = 0
  @FocusState private var focused: Bool

  var body: some View {
    HStack(spacing: 8) {
      Image(systemName: "magnifyingglass").font(.system(size: 12)).foregroundStyle(theme.textSecondary).frame(width: 14, height: 14)
      TextField("", text: $text, prompt: Text(placeholder).foregroundStyle(theme.textTertiary))
        .textContentType(.solaraPlainText)
        .textFieldStyle(.plain)
        .font(.system(size: 13))
        .foregroundStyle(theme.textPrimary)
        .focused($focused)
        .onExitCommand { text = "" }
        .accessibilityLabel(placeholder)
      if !text.isEmpty {
        Button { text = "" } label: {
          Image(systemName: "xmark.circle.fill").font(.system(size: 12)).foregroundStyle(theme.textTertiary).frame(width: 16, height: 16)
        }
        .buttonStyle(.plain)
        .help("Clear")
        .accessibilityLabel("Clear")
      }
    }
    .padding(.horizontal, 8)
    .frame(height: 28)
    .background(RoundedRectangle(cornerRadius: 8, style: .circular).fill(theme.field))
    .overlay(RoundedRectangle(cornerRadius: 8, style: .circular).strokeBorder(theme.fieldBorder, lineWidth: 1))
    .onChange(of: focus) { _, _ in focused = true }
    .pageProbe(placeholder)
  }
}
