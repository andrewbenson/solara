import AppKit
import Foundation
import SolaraModel
import SolaraUI

@MainActor
enum HostedCheckInBanner {
  nonisolated static let kind = "checkInBanner"
  #if DEBUG
    private static var entries: [UUID: Entry] = [:]
  #endif

  @MainActor
  private final class Entry {
    let windowId: String
    let view = CheckInBannerView(frame: .zero)
    let focus = HostedFocusRestoration()
    let context: HostedNoticeContext
    var payload: JSONObject?
    var ended = false
    var iconURI: String?
    var imageTask: Task<Void, Never>?

    init(windowId: String) {
      self.windowId = windowId
      context = HostedNoticeContext(windowId: windowId)
      view.onAction = { [weak self] action, profileId, token in
        guard let self, !self.ended, let state = self.view.state, state.visible, state.profileId == profileId, state.token == token,
          let receipt = self.payload?["token"]?.string, let current = self.context.current(token) else { return }
        self.focus.updateContext(current.focusContext)
        self.focus.restore()
        HostedViews.send(kind, windowId: self.windowId, "action", ["action": action, "token": receipt])
      }
    }

    func update(_ json: String) {
      guard !ended else { return }
      payload = (try? JSONValue.parse(json))?.object
      refresh()
    }

    func refresh() {
      guard !ended else { return }
      let state = payload.flatMap { payload in
        payload["token"]?.string.flatMap { context.project(payload, receipt: $0, receiptKey: "token") }
      }.flatMap(CheckInBannerState.decode)
      focus.updateContext(state?.focusContext)
      if state?.visible != true { focus.restore() }
      view.update(state)
      guard iconURI != state?.icon else { return }
      imageTask?.cancel()
      imageTask = nil
      iconURI = state?.icon
      view.appIcon = nil
      guard let uri = state?.icon, let url = URL(string: uri) else { return }
      if url.isFileURL { view.appIcon = NSImage(contentsOf: url); return }
      guard url.scheme == "http", let host = url.host, ["localhost", "127.0.0.1", "::1"].contains(host) else { return }
      imageTask = Task { [weak self] in
        guard let (data, _) = try? await URLSession.shared.data(from: url), !Task.isCancelled,
          let self, !self.ended, self.iconURI == uri else { return }
        self.view.appIcon = NSImage(data: data)
        self.imageTask = nil
      }
    }

    func end() {
      ended = true
      context.stop()
      focus.cancel()
      imageTask?.cancel()
      imageTask = nil
      view.update(nil)
      view.appIcon = nil
      view.onAction = { _, _, _ in }
    }
  }

  static func register() {
    HostedViews.register(kind) { windowId in
      let entry = Entry(windowId: windowId)
      entry.context.onChange = { [weak entry] in entry?.refresh() }
      entry.context.observe()
      #if DEBUG
        let id = UUID()
        entries[id] = entry
      #endif
      return HostedContent(view: entry.view, onUnmount: {
        entry.end()
        #if DEBUG
          entries[id] = nil
        #endif
      }, takesFocus: false, focusRestoration: entry.focus, onState: { json in entry.update(json) })
    }
  }

  #if DEBUG
    static func drive(_ windowId: String, _ action: String, _ argument: String?) -> [String: Any] {
      guard let entry = entries.values.first(where: { $0.windowId == windowId && !$0.ended && $0.view.window != nil })
        ?? entries.values.first(where: { $0.windowId == windowId && !$0.ended }),
        let state = entry.view.state else { return ["active": false, "found": false] }
      let view = entry.view
      view.layoutSubtreeIfNeeded()
      func frame(_ control: NSView) -> [Double] {
        let rect = control.convert(control.bounds, to: nil)
        let height = view.window?.contentView?.bounds.height ?? view.bounds.height
        return [rect.minX, height - rect.maxY, rect.width, rect.height]
      }
      func describe(_ control: CheckInControl) -> [String: Any] {
        ["label": control.accessibilityLabel() ?? "", "frame": frame(control), "role": control.accessibilityRole()?.rawValue ?? "", "firstClick": control.acceptsFirstMouse(for: nil), "enabled": control.isEnabled && control.interactionEnabled, "found": true]
      }
      let controls = state.visible ? [view.card, view.close] : []
      let target = controls.first { $0.accessibilityLabel() == argument?.components(separatedBy: "|").first }
      switch action {
      case "find": return target.map(describe) ?? ["found": false]
      case "hover": view.devHover(argument == "true"); return ["accepted": true]
      case "press": return ["accepted": target?.accessibilityPerformPress() ?? false]
      case "focus": return ["accepted": target.map { view.window?.makeFirstResponder($0) ?? false } ?? false]
      case "key":
        guard let target, let key = argument?.components(separatedBy: "|").last else { return ["accepted": false] }
        let keys: [String: (String, UInt16)] = ["Space": (" ", 49), "Return": ("\r", 36), "Enter": ("\u{3}", 76), "Tab": ("\t", 48)]
        guard let pair = keys[key] else { return ["accepted": false] }
        view.window?.makeFirstResponder(target)
        for type in [NSEvent.EventType.keyDown, .keyUp] {
          let event = NSEvent.keyEvent(with: type, location: .zero, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: view.window?.windowNumber ?? 0, context: nil, characters: pair.0, charactersIgnoringModifiers: pair.0, isARepeat: false, keyCode: pair.1)!
          if type == .keyDown { target.keyDown(with: event) } else { target.keyUp(with: event) }
        }
        return ["accepted": true]
      default:
        return ["active": true, "visible": state.visible, "dark": state.dark, "profileId": state.profileId, "hovered": view.hovered, "leaving": view.motion?.leaving ?? false, "scale": view.motion?.scale ?? 1, "opacity": view.motion?.opacity ?? 0, "card": frame(view.card), "close": frame(view.close), "controls": controls.map(describe), "trace": view.trace]
      }
    }
  #endif
}
