import AppKit
import ExpoModulesCore
import Foundation
import SolaraModel
import SolaraUI

public class AutoHideModule: Module {
  public func definition() -> ModuleDefinition {
    Name("SolaraAutoHide")

    Events("onAutoHideEvent")

    AsyncFunction("set") { (windowId: String, tabId: String, json: String) in
      let sink = AutoHideSink(self)
      MainActor.assumeIsolated {
        guard let data = json.data(using: .utf8), let state = try? JSONDecoder().decode(AutoHideState.self, from: data) else { return }
        AutoHideHost.set(windowId: windowId, tabId: tabId, state: state) { kind, on in
          sink.module?.sendEvent("onAutoHideEvent", ["windowId": windowId, "tabId": tabId, "kind": kind, "on": on])
        }
      }
    }.runOnQueue(.main)

    AsyncFunction("remove") { (windowId: String, tabId: String) in
      MainActor.assumeIsolated { AutoHideHost.remove(windowId: windowId, tabId: tabId) }
    }.runOnQueue(.main)
  }
}

struct AutoHideState: Decodable {
  struct Rect: Decodable {
    let x: Double
    let y: Double
    let width: Double
    let height: Double
  }

  let mode: String
  let shownTop: Double
  let pane: Rect
  let card: String
  let band: String?
  let divider: String
  let secondary: String
  let host: String
  let hasPage: Bool
  let stripes: String?
}

@MainActor
enum AutoHideHost {
  private static var strips: [String: AutoHideStripView] = [:]

  private static func key(_ windowId: String, _ tabId: String) -> String { windowId + "\u{1}" + tabId }

  static func set(windowId: String, tabId: String, state: AutoHideState, send: @escaping (String, Bool) -> Void) {
    guard let shell = NativeWindowShell.host(windowId)?.shell else { return }
    let created = strips[key(windowId, tabId)] == nil
    let strip = strips[key(windowId, tabId)] ?? {
      let made = AutoHideStripView(frame: .zero)
      strips[key(windowId, tabId)] = made
      return made
    }()
    keepUnderToolbar(strip, windowId: windowId, tabId: tabId)
    strip.onEvent = { event in
      switch event {
      case .reveal: send("reveal", true)
      case .peek(let on): send("peek", on)
      }
    }
    strip.onMotion = { [weak shell, weak strip] _ in
      if let strip { keepUnderToolbar(strip, windowId: windowId, tabId: tabId) }
      shell?.coverChanged()
    }
    strip.onFrame = { frame in
      setLiveTop(CGFloat(frame.liveTop), windowId: windowId, tabId: tabId)
      NativeToolbarHostView.toolbar(windowId: windowId, tabId: tabId)?.setAutoHide(
        opacity: CGFloat(frame.controlsOpacity), scale: CGFloat(frame.toolbarScale), lift: CGFloat(-frame.toolbarLift), interactive: frame.interactive)
    }
    let mode = ToolbarAutoHideMode(rawValue: state.mode) ?? .shown
    let style = AutoHideStripStyle(
      card: CSSColor(state.card) ?? CSSColor("#FFFFFF")!, band: state.band.flatMap { CSSColor($0) },
      divider: CSSColor(state.divider) ?? CSSColor("rgba(0,0,0,0.1)")!, secondary: CSSColor(state.secondary) ?? CSSColor("#00000080")!,
      host: state.host, hasPage: state.hasPage, stripes: state.stripes)
    strip.set(style: style, mode: mode, shownTop: state.shownTop)
    if created { setLiveTop(CGFloat(strip.restingTop), windowId: windowId, tabId: tabId) }
  }

  private static func setLiveTop(_ top: CGFloat?, windowId: String, tabId: String) {
    FrameUpdates.flush()
    PaneOverlays.shared.setLiveTop(top, windowId: windowId, tabId: tabId)
    NativeSplitChrome.setLiveTop(top, windowId: windowId, tabId: tabId)
  }

  static func toolbarReady(windowId: String? = nil, tabId: String, toolbar: ToolbarView? = nil) {
    for (key, strip) in strips {
      let parts = key.split(separator: "\u{1}", maxSplits: 1).map(String.init)
      guard parts.count == 2, parts[1] == tabId else { continue }
      if let windowId, parts[0] != windowId { continue }
      keepUnderToolbar(strip, windowId: parts[0], tabId: tabId, toolbar: toolbar)
    }
  }

  private static func keepUnderToolbar(_ strip: AutoHideStripView, windowId: String, tabId: String, toolbar supplied: ToolbarView? = nil) {
    guard let toolbar = supplied ?? NativeToolbarHostView.host(windowId: windowId, tabId: tabId)?.toolbar,
      toolbar.superview != nil else { return }
    toolbar.placeBackdrop(strip)
  }

  static func remove(windowId: String, tabId: String) {
    guard let strip = strips.removeValue(forKey: key(windowId, tabId)) else { return }
    strip.removeFromSuperview()
    setLiveTop(nil, windowId: windowId, tabId: tabId)
    NativeToolbarHostView.toolbar(windowId: windowId, tabId: tabId)?.setAutoHide(opacity: 1, scale: 1, lift: 0, interactive: true)
  }
}

private final class AutoHideSink: @unchecked Sendable {
  weak var module: AutoHideModule?
  init(_ module: AutoHideModule) { self.module = module }
}
