import AppKit
import SwiftUI

struct ProfileIconPicker: NSViewRepresentable {
  @Environment(\.colorScheme) private var scheme
  let profileId: String
  let current: String?
  var tint: String? = nil
  let onEvent: (SidebarIconPickerView.Event) -> Void

  static func state(profileId: String, current: String?, dark: Bool) -> SidebarIconPickerState {
    SidebarIconPickerState(id: profileId, kind: "profile", current: current, anchor: nil, sidebarWidth: 0, dark: dark, shadowOpacity: 0, theme: [:])
  }

  func makeNSView(context: Context) -> ProfileIconPickerView {
    let view = ProfileIconPickerView()
    view.setAccessibilityLabel("Profile Icon")
    DispatchQueue.main.async { [weak view] in view?.focus() }
    return view
  }

  func updateNSView(_ view: ProfileIconPickerView, context: Context) {
    view.onEvent = onEvent
    view.configure(profileId: profileId, current: current, dark: scheme == .dark, tint: tint.flatMap { CSSColor($0)?.ns } ?? .controlAccentColor)
  }

  func sizeThatFits(_ proposal: ProposedViewSize, nsView view: ProfileIconPickerView, context: Context) -> CGSize? {
    view.intrinsicContentSize
  }
}
