import AppKit
import Foundation
import SolaraUI

@MainActor
enum NativeShareBand {
  private static var windows: [String: WindowBand] = [:]

  @MainActor
  final class WindowBand {
    let windowId: String
    let band = ShareBand()
    var clips: [String: ShareBandClip] = [:]
    var targets: [String: ShareBarState] = [:]
    var shown: Set<String> = []

    init(windowId: String) {
      self.windowId = windowId
      band.onChange = { [weak self] heights in self?.apply(heights) }
    }

    func update(_ states: [String: ShareBarState]) {
      for (tabId, state) in states {
        let clip = clips[tabId] ?? make(tabId)
        if clip.superview == nil { NativeSplitChrome.setShareBandClip(clip, windowId: windowId, tabId: tabId) }
        if targets[tabId] != state { clip.bar.update(state) }
        targets[tabId] = state
        band.target(tabId, shown: true)
      }
      for tabId in shown.subtracting(states.keys) { band.target(tabId, shown: false) }
      shown = Set(states.keys)
    }

    private func make(_ tabId: String) -> ShareBandClip {
      let clip = ShareBandClip()
      clip.bar.onAction = { [weak self] action in
        guard let self, self.shown.contains(tabId), let target = self.targets[tabId] else { return }
        NativeDisplayCapture.barAction(action, row: target)
      }
      clips[tabId] = clip
      return clip
    }

    private func apply(_ heights: [String: CGFloat]) {
      NativeSplitChrome.setShareBands(heights, windowId: windowId)
      NativeWindowShell.host(windowId)?.scheduleLayoutProjection()
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

  static func update(_ all: [String: [String: ShareBarState]]) {
    for (windowId, states) in all {
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

  static func height(windowId: String, tabId: String) -> CGFloat { windows[windowId]?.band.heights[tabId] ?? 0 }

  static var windowIds: [String] { windows.keys.sorted() }

  static func describe(_ windowId: String) -> [String: Any]? { windows[windowId]?.describe() }

  static func bars(_ windowId: String) -> [NSView] {
    windows[windowId].map { $0.clips.values.filter { $0.window != nil && $0.bounds.height > 0 }.map(\.bar) } ?? []
  }
}
