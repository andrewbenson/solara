import AppKit
import SolaraUI

@MainActor
enum HostedViews {
  struct Event {
    let kind: String
    let windowId: String
    let name: String
    let payload: [String: Any]
  }

  static var events: [Event] = []

  static func send(_ kind: String, windowId: String, _ name: String, _ payload: [String: Any]) {
    events.append(Event(kind: kind, windowId: windowId, name: name, payload: payload))
  }
}

@MainActor
final class ShellHost {
  let shell: WindowShellView
  init(_ windowId: String) { shell = WindowShellView(windowId: windowId) }
}

@MainActor
enum NativeWindowShell {
  static func host(_ windowId: String) -> ShellHost? { nil }
}
