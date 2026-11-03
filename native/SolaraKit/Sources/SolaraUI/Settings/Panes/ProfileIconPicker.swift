import AppKit
import SwiftUI

struct ProfileIconPicker: NSViewRepresentable {
  @Environment(\.colorScheme) private var scheme
  let profileId: String
  let current: String?
  let onEvent: (SidebarIconPickerView.Event) -> Void

  static func state(profileId: String, current: String?, dark: Bool) -> SidebarIconPickerState {
    SidebarIconPickerState(id: profileId, kind: "profile", current: current, anchor: nil, sidebarWidth: 0, dark: dark, shadowOpacity: 0, theme: [:])
  }

  func makeNSView(context: Context) -> SidebarIconPickerView {
    let view = SidebarIconPickerView()
    view.embedded = true
    view.setAccessibilityLabel("Profile Icon")
    DispatchQueue.main.async { [weak view] in view?.focus() }
    return view
  }

  func updateNSView(_ view: SidebarIconPickerView, context: Context) {
    view.onEvent = onEvent
    let next = Self.state(profileId: profileId, current: current, dark: scheme == .dark)
    if view.state != next { view.set(next) }
  }

  func sizeThatFits(_ proposal: ProposedViewSize, nsView view: SidebarIconPickerView, context: Context) -> CGSize? {
    view.intrinsicContentSize
  }
}
