import AppKit
import ExpoModulesCore
import Foundation
import SolaraCore
import SolaraModel
import SolaraStore
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

    AsyncFunction("setStyle") { (windowId: String, tabId: String, generation: Double, json: String) in
      MainActor.assumeIsolated {
        guard generation.isFinite, generation > 0,
          generation == Double(NativeWindowShell.nativeLayoutGeneration(windowId)),
          let data = json.data(using: .utf8), let state = try? JSONDecoder().decode(AutoHideStyleState.self, from: data) else { return }
        AutoHideHost.setStyle(windowId: windowId, tabId: tabId, state: state)
      }
    }.runOnQueue(.main)

    #if DEBUG
    AsyncFunction("devStripHost") { (windowId: String, tabId: String) -> String? in
      MainActor.assumeIsolated {
        guard SolaraCoreTestHooksAllowed() else { return nil }
        return AutoHideHost.devStripHost(windowId: windowId, tabId: tabId)
      }
    }.runOnQueue(.main)
    #endif

    AsyncFunction("remove") { (windowId: String, tabId: String) in
      MainActor.assumeIsolated { AutoHideHost.remove(windowId: windowId, tabId: tabId) }
    }.runOnQueue(.main)
  }
}

struct AutoHideStyleState: Decodable {
  let held: Bool?
  let card: String
  let band: String?
  let divider: String
  let secondary: String
  let stripes: String?

  var style: AutoHideStripStyle {
    AutoHideStripStyle(card: CSSColor(card) ?? CSSColor("#FFFFFF")!, band: band.flatMap { CSSColor($0) },
      divider: CSSColor(divider) ?? CSSColor("#00000019")!, secondary: CSSColor(secondary) ?? CSSColor("#00000080")!,
      host: "", hasPage: true, stripes: stripes)
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
  let pane: Rect?
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
  private static var styles: [String: AutoHideStripStyle] = [:]
  private static var snapshots: [String: WindowLayoutSnapshot] = [:]

  private static func key(_ windowId: String, _ tabId: String) -> String { windowId + "\u{1}" + tabId }

  static func set(windowId: String, tabId: String, state: AutoHideState, send: @escaping (String, Bool) -> Void) {
    guard let shell = NativeWindowShell.host(windowId)?.shell else { return }
    let style = AutoHideStripStyle(
      card: CSSColor(state.card) ?? CSSColor("#FFFFFF")!, band: state.band.flatMap { CSSColor($0) },
      divider: CSSColor(state.divider) ?? CSSColor("rgba(0,0,0,0.1)")!, secondary: CSSColor(state.secondary) ?? CSSColor("#00000080")!,
      host: state.host, hasPage: state.hasPage, stripes: state.stripes)
    if NativeWindowShell.nativeLayoutActive(windowId) {
      styles[key(windowId, tabId)] = style
      if let snapshot = snapshots[windowId] { install(snapshot) }
      return
    }
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
    let shownTop = NativeWindowShell.host(windowId)?.nativeShownTop(tabId) ?? state.shownTop
    strip.set(style: style, mode: mode, shownTop: shownTop)
    if created { setLiveTop(CGFloat(strip.restingTop), windowId: windowId, tabId: tabId) }
  }

  static func setStyle(windowId: String, tabId: String, state: AutoHideStyleState) {
    guard NativeWindowShell.nativeLayoutActive(windowId),
      NativeStoreHandle.store?.state.tabs[tabId]?.windowId == windowId else { return }
    NativeWindowShell.host(windowId)?.setToolbarHold(tabId, held: state.held == true)
    styles[key(windowId, tabId)] = state.style
    if let snapshot = snapshots[windowId] { install(snapshot) }
  }

  static func install(_ snapshot: WindowLayoutSnapshot) {
    let windowId = snapshot.input.windowId
    snapshots[windowId] = snapshot
    let state = NativeWindowShell.nativeLayoutActive(windowId) ? NativeStoreHandle.store?.state : nil
    let visible = Set(snapshot.toolbarModes.keys.filter { snapshot.input.hideToolbarWhileScrolling && (snapshot.toolbars[$0]?.height ?? 0) > 0 })
    for entry in strips.keys.filter({ $0.hasPrefix(windowId + "\u{1}") }) {
      let tabId = String(entry.dropFirst(windowId.count + 1))
      if !visible.contains(tabId) { remove(windowId: windowId, tabId: tabId) }
    }
    for tabId in visible {
      guard let shell = NativeWindowShell.host(windowId)?.shell, let mode = snapshot.toolbarModes[tabId],
        let top = snapshot.shownTops[tabId] else { continue }
      let entry = key(windowId, tabId)
      let strip = strips[entry] ?? AutoHideStripView(frame: .zero)
      let created = strips[entry] == nil
      strips[entry] = strip
      strip.onEvent = { event in NativeWindowShell.host(windowId)?.toolbarPresentationEvent(tabId, event) }
      strip.onMotion = { [weak shell, weak strip] _ in
        if let strip { keepUnderToolbar(strip, windowId: windowId, tabId: tabId) }
        shell?.coverChanged()
      }
      strip.onFrame = { frame in
        NativeToolbarHostView.toolbar(windowId: windowId, tabId: tabId)?.setAutoHide(
          opacity: CGFloat(frame.controlsOpacity), scale: CGFloat(frame.toolbarScale), lift: CGFloat(-frame.toolbarLift), interactive: frame.interactive)
        NativeWindowShell.host(windowId)?.scheduleLayoutProjection()
      }
      var style = styles[entry] ?? AutoHideStripStyle(card: CSSColor("#FFFFFF")!, band: nil,
        divider: CSSColor("#00000019")!, secondary: CSSColor("#00000080")!, host: "", hasPage: true)
      if let state, let identity = ToolbarPageIdentity.resolve(windowId: windowId, tabId: tabId, state: state) {
        style.host = identity.host
        style.hasPage = identity.hasPage
      }
      keepUnderToolbar(strip, windowId: windowId, tabId: tabId)
      strip.set(style: style, mode: mode, shownTop: Double(top))
      if created { NativeWindowShell.host(windowId)?.scheduleLayoutProjection() }
    }
  }

  static func windowEnded(_ windowId: String) {
    snapshots[windowId] = nil
    for entry in strips.keys.filter({ $0.hasPrefix(windowId + "\u{1}") }) {
      remove(windowId: windowId, tabId: String(entry.dropFirst(windowId.count + 1)))
    }
    styles = styles.filter { !$0.key.hasPrefix(windowId + "\u{1}") }
  }

  #if DEBUG
  static func devStripHost(windowId: String, tabId: String) -> String? {
    guard let strip = strips[key(windowId, tabId)], strip.window != nil else { return nil }
    return strip.devLabelText
  }
  #endif

  static func layoutTop(windowId: String, tabId: String) -> CGFloat? {
    strips[key(windowId, tabId)].map { CGFloat($0.presentationTop) }
  }

  private static func setLiveTop(_ top: CGFloat?, windowId: String, tabId: String) {
    guard !NativeWindowShell.nativeLayoutActive(windowId) else { return }
    FrameUpdates.flush()
    PaneOverlays.shared.setLiveTop(top, windowId: windowId, tabId: tabId)
    NativeSplitChrome.setLiveTop(top, windowId: windowId, tabId: tabId)
    NativeWindowShell.host(windowId)?.scheduleLayoutProjection()
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
    guard let toolbar = supplied ?? NativeToolbarHostView.toolbar(windowId: windowId, tabId: tabId),
      toolbar.superview != nil else { return }
    toolbar.placeBackdrop(strip)
  }

  static func remove(windowId: String, tabId: String) {
    if NativeStoreHandle.store?.state.tabs[tabId]?.windowId != windowId { styles[key(windowId, tabId)] = nil }
    guard let strip = strips.removeValue(forKey: key(windowId, tabId)) else { return }
    strip.removeFromSuperview()
    if NativeWindowShell.nativeLayoutActive(windowId) {
      NativeWindowShell.host(windowId)?.scheduleLayoutProjection()
    } else {
      setLiveTop(nil, windowId: windowId, tabId: tabId)
    }
    NativeToolbarHostView.toolbar(windowId: windowId, tabId: tabId)?.setAutoHide(opacity: 1, scale: 1, lift: 0, interactive: true)
  }
}

private final class AutoHideSink: @unchecked Sendable {
  weak var module: AutoHideModule?
  init(_ module: AutoHideModule) { self.module = module }
}
