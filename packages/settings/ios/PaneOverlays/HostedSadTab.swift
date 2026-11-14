import AppKit
import Foundation
import SolaraUI

@MainActor
enum HostedSadTab {
  private static var registered = false
  #if DEBUG
    private static var entries: [HostedSadTabEntry] = []
  #endif

  static func register() {
    guard !registered else { return }
    registered = true
    HostedViews.register("sadTab") { windowId, json in
      let entry = HostedSadTabEntry(windowId: windowId)
      #if DEBUG
        entries.append(entry)
      #endif
      entry.update(json)
      return HostedContent(
        view: entry.view,
        onUnmount: {
          entry.end()
          #if DEBUG
            entries.removeAll { $0 === entry }
          #endif
        },
        takesFocus: false,
        onState: { json in entry.update(json) })
    }
  }

  #if DEBUG
    static func describe(_ windowId: String) -> [String: Any]? {
      let matches = entries.filter { $0.windowId == windowId && !$0.tabId.isEmpty }
      guard !matches.isEmpty else { return nil }
      var tabs: [String: [String: Any]] = [:]
      for entry in matches {
        let view = entry.view
        func inWindow(_ rect: CGRect) -> [Double] {
          let frame = view.convert(rect, to: nil)
          let height = view.window?.contentView?.bounds.height ?? 0
          return [frame.minX, height - frame.maxY, frame.width, frame.height]
        }
        tabs[entry.tabId, default: [:]]["sadTab"] = [
          "mode": view.showing.map { $0.rawValue as Any } ?? NSNull(),
          "hidden": view.isHiddenOrHasHiddenAncestor,
          "frame": inWindow(view.bounds),
          "controls": view.controlFrames.mapValues(inWindow),
        ]
      }
      return ["top": false, "inCard": false, "tabs": tabs]
    }
  #endif
}

@MainActor
private final class HostedSadTabEntry {
  let windowId: String
  let view = SadTabView(frame: .zero)
  private(set) var tabId = ""
  private var ended = false

  init(windowId: String) {
    self.windowId = windowId
    view.isHidden = true
    view.onAction = { [weak self] action in
      guard let self, !ended, !tabId.isEmpty, view.showing != nil else { return }
      let tabId = tabId
      Task { @MainActor in _ = await SettingsAdapters.js("pane.sadTab", windowId, tabId, action.rawValue) }
    }
  }

  func update(_ json: String) {
    guard !ended else { return }
    guard let data = json.data(using: .utf8),
      let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
      let tabId = object["tabId"] as? String, !tabId.isEmpty,
      let state = SadTabState.decode(json)
    else {
      tabId = ""
      view.isHidden = true
      return
    }
    self.tabId = tabId
    view.update(state)
  }

  func end() {
    ended = true
    tabId = ""
    view.isHidden = true
  }
}
