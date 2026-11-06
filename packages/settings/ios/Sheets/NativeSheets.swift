import AppKit
import Foundation
import QuartzCore
import SolaraShell
import SolaraUI

@MainActor
enum NativeSheets {
  nonisolated static let kind = "extensionSheet"
  fileprivate static var hosts: [String: SheetHost] = [:]

  static func set(_ windowId: String, _ json: String?) {
    guard let json, !json.isEmpty else {
      hosts[windowId]?.end()
      return
    }
    guard let state = WindowSheetState.decode(json) else { return }
    let host = hosts[windowId] ?? SheetHost(windowId: windowId)
    hosts[windowId] = host
    host.apply(state)
  }

  fileprivate static func ended(_ windowId: String, host: SheetHost) {
    if hosts[windowId] === host { hosts[windowId] = nil }
  }

  #if DEBUG
  static func devWatchingForWindow(_ windowId: String) -> Bool { hosts[windowId]?.watchingForWindow ?? false }
  #endif
}

fileprivate struct WindowSheetState: Decodable {
  struct Style: Decodable {
    let dark: Bool
    let panel: String
    let panelBorder: String
    let panelShadowOpacity: Double

    var sheet: SheetStyle {
      SheetStyle(dark: dark, panel: panel, panelBorder: panelBorder, panelShadowOpacity: panelShadowOpacity)
    }
  }

  let kind: String
  let key: String
  let title: String
  let busy: Bool
  let style: Style
  let install: ExtensionInstallState?
  let pins: ExtensionPinsState?

  static func decode(_ json: String) -> WindowSheetState? {
    guard let data = json.data(using: .utf8), let state = try? JSONDecoder().decode(Self.self, from: data),
      (state.kind == "install" && state.install != nil) || (state.kind == "pins" && state.pins != nil)
    else { return nil }
    return state
  }
}

@MainActor
fileprivate final class SheetHost {
  let sheet = SheetView(frame: .zero)
  private let view = SheetHostView(frame: .zero)
  private let windowId: String
  private weak var window: NSWindow?
  private weak var shell: WindowShellView?
  private var state: WindowSheetState?
  private var body: ExtensionDialogBody?
  private var bodyKey: String?
  private var bodyKind: String?
  private var bodyHeight: CGFloat = 0
  private var retries = 0
  private var appearing: [NSObjectProtocol] = []
  private var closing: NSObjectProtocol?
  private var mounted = false
  private var ended = false
  private var placement = "window"

  init(windowId: String) {
    self.windowId = windowId
    sheet.autoresizingMask = [.width, .height]
    view.autoresizingMask = [.width, .height]
    view.addSubview(sheet)
    view.onWindowChanged = { [weak self] in
      guard let self, self.mounted, self.view.window !== self.window else { return }
      self.end()
    }
    sheet.onDismiss = { [weak self] in self?.send("dismiss") }
    sheet.onSubmit = { [weak self] in self?.send("submit") }
  }

  fileprivate func apply(_ next: WindowSheetState) {
    guard !ended else { return }
    state = next
    if mounted {
      guard let window, view.window === window else { return end() }
      render()
    } else if !mount() {
      retries = 0
      waitForWindow()
    }
  }

  private func mount() -> Bool {
    guard !ended, !mounted, state != nil else { return false }
    let shell = NativeWindowShell.host(windowId)?.shell
    let parent: NSView
    if let shell {
      guard shell.overlay.window != nil else { return false }
      parent = shell.overlay
    } else {
      guard let content = ShellDrag.window(windowId)?.contentView, content.window != nil else { return false }
      parent = Self.embeddedView(in: content) ?? content
    }
    guard let window = parent.window else { return false }
    stopWatching()
    self.window = window
    self.shell = shell
    placement = shell == nil ? "window" : "shell"
    view.frame = parent.bounds
    sheet.frame = view.bounds
    mounted = true
    parent.addSubview(view, positioned: .above, relativeTo: nil)
    shell?.setModal(NativeSheets.kind, shown: true)
    closing = NotificationCenter.default.addObserver(forName: NSWindow.willCloseNotification, object: window, queue: .main) { [weak self] _ in
      MainActor.assumeIsolated { self?.end() }
    }
    render()
    return true
  }

  private static func embeddedView(in content: NSView) -> NSView? {
    guard content.responds(to: NSSelectorFromString("solaraEmbeddedView")),
      let embedded = content.value(forKey: "solaraEmbeddedView") as? NSView,
      embedded.superview === content, !embedded.isHidden
    else { return nil }
    return embedded
  }

  private func waitForWindow() {
    guard retries < 40 else { return watchForWindow() }
    retries += 1
    DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) { [weak self] in
      MainActor.assumeIsolated {
        guard let self, !self.ended, !self.mounted, self.state != nil else { return }
        if !self.mount() { self.waitForWindow() }
      }
    }
  }

  private func watchForWindow() {
    guard appearing.isEmpty else { return }
    for name in [NSWindow.didBecomeKeyNotification, NSWindow.didBecomeMainNotification, NSWindow.didChangeOcclusionStateNotification] {
      appearing.append(NotificationCenter.default.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
        MainActor.assumeIsolated {
          guard let self, !self.ended, !self.mounted, self.state != nil else { return }
          _ = self.mount()
        }
      })
    }
  }

  #if DEBUG
  var watchingForWindow: Bool { !appearing.isEmpty }
  #endif

  private func stopWatching() {
    for observer in appearing { NotificationCenter.default.removeObserver(observer) }
    appearing = []
  }

  private func render() {
    guard !ended, mounted, let state else { return }
    let replacing = body != nil && (bodyKey != state.key || bodyKind != state.kind)
    if body == nil || replacing {
      body?.onEvent = { _ in }
      body?.onHeight = { _ in }
      let next: ExtensionDialogBody = state.kind == "install" ? ExtensionInstallView(frame: .zero) : ExtensionPinsView(frame: .zero)
      body = next
      bodyKey = state.key
      bodyKind = state.kind
      bodyHeight = 0
      let key = state.key
      let kind = state.kind
      next.onHeight = { [weak self, weak next] height in
        guard let self, !self.ended, self.body === next, self.state?.key == key, self.state?.kind == kind else { return }
        self.bodyHeight = height
        self.sheet.setBodyHeight(height)
      }
      next.onEvent = { [weak self, weak next] event in
        guard let self, !self.ended, self.body === next, self.state?.key == key, self.state?.kind == kind else { return }
        switch event {
        case .confirm: self.send("confirm")
        case .cancel: self.send("cancel")
        case .done: self.send("done")
        case .toggle(let id, let pinned): self.send("toggle", ["id": id, "pinned": pinned])
        }
      }
      if replacing { stopAppearance(in: sheet.layer) }
    }
    guard let body else { return }
    body.setFrameSize(NSSize(width: 340, height: bodyHeight))
    if let install = body as? ExtensionInstallView, let next = state.install { install.update(next) }
    if let pins = body as? ExtensionPinsView, let next = state.pins { pins.update(next) }
    sheet.busy = state.busy
    sheet.present(body: body, bodyHeight: bodyHeight, style: state.style.sheet, accessibilityTitle: state.title, animated: !replacing)
  }

  private func stopAppearance(in layer: CALayer?) {
    layer?.removeAnimation(forKey: "sheet.opacity")
    layer?.removeAnimation(forKey: "sheet.transform")
    for child in layer?.sublayers ?? [] { stopAppearance(in: child) }
  }

  private func send(_ name: String, _ payload: [String: Any] = [:]) {
    guard !ended, mounted, let state else { return }
    var body = payload
    body["key"] = state.key
    HostedViews.send(NativeSheets.kind, windowId: windowId, name, body)
  }

  func end() {
    guard !ended else { return }
    ended = true
    stopWatching()
    let key = mounted ? state?.key : nil
    if let closing { NotificationCenter.default.removeObserver(closing) }
    closing = nil
    body?.onEvent = { _ in }
    body?.onHeight = { _ in }
    view.removeFromSuperview()
    shell?.setModal(NativeSheets.kind, shown: false)
    body = nil
    state = nil
    NativeSheets.ended(windowId, host: self)
    if let key { HostedViews.send(NativeSheets.kind, windowId: windowId, "closed", ["key": key]) }
  }

  #if SOLARA_PROBES
  func snapshot() -> [String: Any]? {
    guard !ended, mounted, let state, let window, let content = window.contentView, sheet.window === window else { return nil }
    func rect(_ frame: CGRect) -> [Double] {
      let box = sheet.convert(frame, to: nil)
      return [Double(box.minX), Double(content.bounds.height - box.maxY), Double(box.width), Double(box.height)]
    }
    let focused = window.firstResponder as? NSView
    let editor = focused as? NSTextView
    let responder = editor?.isFieldEditor == true ? (editor?.delegate as? NSView) : focused
    return ["kind": state.kind, "key": state.key, "busy": state.busy, "host": placement,
      "card": rect(sheet.cardFrame), "scrim": rect(sheet.bounds),
      "focusInSheet": responder.map { $0.isDescendant(of: sheet) } ?? false]
  }
  #endif
}

@MainActor
private final class SheetHostView: NSView {
  var onWindowChanged: () -> Void = {}

  override var isFlipped: Bool { true }

  override func viewDidMoveToWindow() {
    super.viewDidMoveToWindow()
    onWindowChanged()
  }
}

#if SOLARA_PROBES
@MainActor
public enum SheetRead {
  public static func snapshot(windowId: String) -> [String: Any]? {
    NativeSheets.hosts[windowId]?.snapshot()
  }
}
#endif
