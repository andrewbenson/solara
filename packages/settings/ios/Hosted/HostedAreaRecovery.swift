import AppKit
import Foundation
import SolaraUI

@MainActor
enum HostedAreaRecovery {
  nonisolated static let kind = "areaRecovery"
  #if DEBUG
    private static var entries: [UUID: Entry] = [:]
  #endif

  @MainActor
  private final class Entry {
    let windowId: String
    let view = AreaRecoveryView(frame: .zero)
    var ended = false
    init(windowId: String) { self.windowId = windowId }

    func send(_ name: String, _ payload: [String: Any] = [:]) {
      guard !ended, let state = view.state else { return }
      var body = payload
      body["recoveryId"] = state.recoveryId
      HostedViews.send(HostedAreaRecovery.kind, windowId: windowId, name, body)
    }
  }

  static func register() {
    HostedViews.register(kind) { windowId, json in
      let entry = Entry(windowId: windowId)
      let view = entry.view
      #if DEBUG
        let id = UUID()
        entries[id] = entry
      #endif
      view.onReload = { [weak entry] in entry?.send("reload") }
      view.onHeight = { [weak entry] height in entry?.send("height", ["height": height]) }
      view.update(AreaRecoveryState.decode(json))
      return HostedContent(view: view, onUnmount: {
        entry.ended = true
        view.update(nil)
        view.onReload = {}
        view.onHeight = { _ in }
        #if DEBUG
          entries[id] = nil
        #endif
      }, takesFocus: false, onState: { json in
        guard !entry.ended else { return }
        view.update(AreaRecoveryState.decode(json))
      })
    }
  }

  #if DEBUG
    static func drive(_ windowId: String, _ action: String) -> [String: Any] {
      guard let entry = entries.values.first(where: { $0.windowId == windowId && !$0.ended && $0.view.window != nil }),
        let state = entry.view.state else { return ["found": false] }
      let view = entry.view
      let control = view.reloadControl
      func frame(_ target: NSView) -> [Double] {
        let rect = target.convert(target.bounds, to: nil)
        let height = target.window?.contentView?.bounds.height ?? 0
        return [rect.minX, height - rect.maxY, rect.width, rect.height]
      }
      switch action {
      case "press": return ["accepted": control.accessibilityPerformPress()]
      case "Space", "Return", "Enter":
        let pair: (String, UInt16) = action == "Space" ? (" ", 49) : action == "Return" ? ("\r", 36) : ("\u{3}", 76)
        view.window?.makeFirstResponder(control)
        for type in [NSEvent.EventType.keyDown, .keyUp] {
          let event = NSEvent.keyEvent(with: type, location: .zero, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: view.window?.windowNumber ?? 0, context: nil, characters: pair.0, charactersIgnoringModifiers: pair.0, isARepeat: false, keyCode: pair.1)!
          if type == .keyDown { control.keyDown(with: event) } else { control.keyUp(with: event) }
        }
        return ["accepted": true]
      default:
        return ["found": true, "recoveryId": state.recoveryId, "fill": state.fill, "plain": state.plain, "detail": view.detailText, "frame": frame(view), "reload": frame(control), "label": control.accessibilityLabel() ?? "", "role": control.accessibilityRole()?.rawValue ?? "", "firstMouse": control.acceptsFirstMouse(for: nil), "canFocus": control.acceptsFirstResponder]
      }
    }
  #endif
}
