import AppKit
import Foundation
import SolaraUI

@MainActor
enum NativeShareBand {
  static let topic = "media.shareBand"

  private static var started = false
  private static var windows: [String: WindowBand] = [:]

  @MainActor
  final class WindowBand {
    let windowId: String
    let band = ShareBand()
    var clips: [String: ShareBandClip] = [:]
    var targets: [String: (capturer: String, tabId: String)] = [:]
    var shown: Set<String> = []

    init(windowId: String) {
      self.windowId = windowId
      band.onChange = { [weak self] heights in self?.apply(heights) }
    }

    func update(_ states: [String: ShareBarState]) {
      for (tabId, state) in states {
        let clip = clips[tabId] ?? make(tabId)
        targets[tabId] = (state.capturer, state.tabId)
        clip.bar.update(state)
        band.target(tabId, shown: true)
      }
      for tabId in shown.subtracting(states.keys) { band.target(tabId, shown: false) }
      shown = Set(states.keys)
    }

    private func make(_ tabId: String) -> ShareBandClip {
      let clip = ShareBandClip()
      clip.bar.onAction = { [weak self] action in
        guard let self, let target = self.targets[tabId] else { return }
        NativeMedia.action(self.windowId, "shareBar", target.tabId, ["action": action.rawValue, "capturer": target.capturer])
      }
      clips[tabId] = clip
      NativeSplitChrome.setShareBandClip(clip, windowId: windowId, tabId: tabId)
      return clip
    }

    private func apply(_ heights: [String: CGFloat]) {
      NativeSplitChrome.setShareBands(heights, windowId: windowId)
      for (tabId, clip) in clips where heights[tabId] == nil && !shown.contains(tabId) {
        clips[tabId] = nil
        targets[tabId] = nil
        NativeSplitChrome.setShareBandClip(nil, windowId: windowId, tabId: tabId)
        clip.removeFromSuperview()
      }
    }

    func end() {
      band.stop()
      NativeSplitChrome.setShareBands([:], windowId: windowId)
      for clip in clips.values { clip.removeFromSuperview() }
      for tabId in clips.keys { NativeSplitChrome.setShareBandClip(nil, windowId: windowId, tabId: tabId) }
      clips = [:]
      targets = [:]
      shown = []
    }

    func describe() -> [String: Any] {
      ["heights": band.heights.mapValues(Double.init), "shown": shown.sorted(), "moving": band.isMoving, "ticking": band.isTicking]
    }
  }

  static func start() {
    guard !started else { return }
    started = true
    _ = SettingsJS.shared.observe(topic) { value in apply(value) }
    apply(SettingsJS.shared.latestValue(topic))
  }

  private static func apply(_ value: Any?) {
    guard let o = value as? [String: Any], o["v"] as? Int == 1, let all = o["windows"] as? [String: [String: Any]] else { return }
    for (windowId, entry) in all {
      var states: [String: ShareBarState] = [:]
      for (tabId, raw) in entry {
        guard let data = try? JSONSerialization.data(withJSONObject: raw), let json = String(data: data, encoding: .utf8), let state = ShareBarState.decode(json) else { continue }
        states[tabId] = state
      }
      if windows[windowId] == nil, states.isEmpty || NativeWindowShell.host(windowId) == nil { continue }
      let window = windows[windowId] ?? {
        let made = WindowBand(windowId: windowId)
        windows[windowId] = made
        return made
      }()
      window.update(states)
    }
    for (windowId, window) in windows where all[windowId] == nil { window.update([:]) }
  }

  static func windowEnded(_ windowId: String) {
    windows.removeValue(forKey: windowId)?.end()
  }

  static var windowIds: [String] { windows.keys.sorted() }

  static func describe(_ windowId: String) -> [String: Any]? { windows[windowId]?.describe() }

  static func bars(_ windowId: String) -> [NSView] { windows[windowId].map { $0.clips.values.map(\.bar) } ?? [] }
}
