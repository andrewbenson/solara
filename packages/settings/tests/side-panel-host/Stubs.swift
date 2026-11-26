import AppKit
import SolaraCore
import SolaraModel
import SolaraStore
import SolaraShell
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
final class TabPoolHost {
  static let shared = TabPoolHost()
  func pageView(_ tabId: String) -> NSView? { nil }
}

@MainActor
final class NativeAppIntegration {
  static func preparePageFocus(_ page: NSView) -> FocusMoves.PageFocus? { nil }
}

@MainActor
enum NativeWindowShell {
  static var hosts: [String: SidePanelHarnessShell] = [:]
  static func host(_ windowId: String) -> SidePanelHarnessShell? { hosts[windowId] }
}

@MainActor
final class SidePanelHarnessShell {
  let panel: SidePanelHost
  let shell: WindowShellView
  init(_ panel: SidePanelHost, shell: WindowShellView) { self.panel = panel; self.shell = shell }
  func setSidePanel(_ state: SidePanelState?) { panel.apply(state) }

  func stop() {
    NativeExtensionSidePanel.close(shell.windowId)
    panel.stop()
  }
}


@MainActor
enum NativeExtensionCatalog {
  static var path = "panel.html"

  static func profile(_ windowId: String) -> String {
    guard let state = NativeStoreHandle.store?.state, let window = state.windows[windowId] else { return "" }
    return state.engineProfile(window.profileId)
  }

  static func page(_ tabId: String) -> SolaraCoreWebView? { nil }

  static func visible(_ windowId: String) -> [JSONObject] {
    [["id": "fixture", "name": "Fixture", "sidePanel": .string(path)]]
  }
}

@MainActor
enum NativeExtensionCommands {
  static func run(_ command: JSONValue) {}
}
