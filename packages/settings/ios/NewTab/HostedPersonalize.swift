import AppKit
import Foundation
import SolaraUI

@MainActor
enum HostedPersonalize {
  nonisolated static let kind = "personalize"
  #if DEBUG
    private static var entries: [UUID: Entry] = [:]
  #endif

  private final class Entry {
    let windowId: String
    weak var view: PersonalizeView?
    var ended = false
    init(windowId: String, view: PersonalizeView) { self.windowId = windowId; self.view = view }
  }

  static func register() {
    HostedViews.register(kind) { windowId in
      let view = PersonalizeView(frame: .zero)
      let entry = Entry(windowId: windowId, view: view)
      #if DEBUG
        let id = UUID()
        entries[id] = entry
      #endif
      view.onOpen = { [weak entry] open in
        guard let entry, !entry.ended, entry.view?.state != nil else { return }
        HostedViews.send(kind, windowId: entry.windowId, "open", ["open": open])
      }
      view.onColor = { [weak entry] color in
        guard let entry, !entry.ended, let state = entry.view?.state, state.open, state.canPickColor else { return }
        HostedViews.send(kind, windowId: entry.windowId, "color", ["color": color, "profileId": state.profileId as Any? ?? NSNull()])
      }
      view.onLayout = { [weak entry] layout in
        guard let entry, !entry.ended, let state = entry.view?.state, state.open, state.layout != layout else { return }
        HostedViews.send(kind, windowId: entry.windowId, "layout", ["layout": layout, "profileId": state.profileId as Any? ?? NSNull()])
      }
      return HostedContent(view: view, onUnmount: {
        entry.ended = true
        view.update(nil)
        view.onOpen = { _ in }
        view.onColor = { _ in }
        view.onLayout = { _ in }
        #if DEBUG
          entries[id] = nil
        #endif
      }, takesFocus: false, onState: { [weak view] json in
        guard !entry.ended else { return }
        view?.update(PersonalizeState.decode(json))
      })
    }
  }

  #if DEBUG
    static func drive(_ windowId: String, _ action: String, _ argument: String?) -> [String: Any] {
      guard let view = entries.values.first(where: { $0.windowId == windowId && !$0.ended && $0.view?.window != nil })?.view
        ?? entries.values.first(where: { $0.windowId == windowId && !$0.ended })?.view,
        let state = view.state else { return ["active": false, "found": false] }
      view.layoutSubtreeIfNeeded()
      func controls(_ root: NSView) -> [NSView] {
        let own: [NSView] = root is PersonalizeControl && !root.isHiddenOrHasHiddenAncestor ? [root] : []
        return own + root.subviews.flatMap(controls)
      }
      let all = controls(view)
      func frame(_ rect: CGRect, from source: NSView) -> [Double] {
        let native = source.convert(rect, to: nil)
        let height = source.window?.contentView?.bounds.height ?? view.bounds.height
        return [native.minX, height - native.maxY, native.width, native.height]
      }
      func item(_ control: NSView) -> [String: Any] {
        ["label": control.accessibilityLabel() ?? "", "frame": frame(control.bounds, from: control), "role": control.accessibilityRole()?.rawValue ?? "", "value": control.accessibilityValue() ?? NSNull(), "enabled": true, "found": true]
      }
      let target = all.first { $0.accessibilityLabel() == argument?.components(separatedBy: "|").first }
      switch action {
      case "find": return target.map(item) ?? ["found": false]
      case "press": return ["accepted": target?.accessibilityPerformPress() ?? false]
      case "focus": return ["accepted": target.map { view.window?.makeFirstResponder($0) ?? false } ?? false]
      case "key":
        guard let target, let key = argument?.components(separatedBy: "|").last else { return ["accepted": false] }
        let keys: [String: (String, UInt16)] = ["Space": (" ", 49), "Return": ("\r", 36), "Enter": ("\u{3}", 76), "Tab": ("\t", 48), "Escape": ("\u{1b}", 53)]
        guard let pair = keys[key] else { return ["accepted": false] }
        view.window?.makeFirstResponder(target)
        for type in [NSEvent.EventType.keyDown, .keyUp] {
          let event = NSEvent.keyEvent(with: type, location: .zero, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: view.window?.windowNumber ?? 0, context: nil, characters: pair.0, charactersIgnoringModifiers: pair.0, isARepeat: false, keyCode: pair.1)!
          if type == .keyDown { target.keyDown(with: event) } else { target.keyUp(with: event) }
        }
        return ["accepted": true]
      case "close": view.onOpen(false); return ["accepted": true]
      default:
        return ["active": true, "open": state.open, "dark": state.dark, "color": state.color as Any? ?? NSNull(), "layout": state.layout, "profileId": state.profileId as Any? ?? NSNull(), "button": frame(view.buttonFrame, from: view), "panel": view.panelFrame.map { frame($0, from: view) } as Any? ?? NSNull(), "controls": all.map(item)]
      }
    }
  #endif
}
