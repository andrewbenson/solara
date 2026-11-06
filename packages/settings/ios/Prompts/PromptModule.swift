import AppKit
import ExpoModulesCore
import Foundation
import SolaraUI

public class PromptModule: Module {
  public func definition() -> ModuleDefinition {
    Name("SolaraPrompt")

    View(NativePromptView.self) {
      Events("onPromptEvent", "onPromptHeight")

      Prop("state") { (view: NativePromptView, v: String) in MainActor.assumeIsolated { view.setState(v) } }
    }
  }
}

final class NativePromptView: ExpoView {
  let onPromptEvent = EventDispatcher()
  let onPromptHeight = EventDispatcher()
  let body = PromptBodyView(frame: .zero)
  private var json = ""
  private lazy var host = PromptPopoverHost(owner: self, body: body) { [weak self] in self?.onPromptEvent(["kind": "dismiss"]) }

  override var isFlipped: Bool { true }

  override func hitTest(_ point: NSPoint) -> NSView? {
    let hit = super.hitTest(point)
    return hit === self ? nil : hit
  }

  required init(appContext: AppContext? = nil) {
    super.init(appContext: appContext)
    body.onHeight = { [weak self] h in
      guard let self else { return }
      if !self.host.report(h) { self.onPromptHeight(["height": h]) }
    }
    body.onEvent = { [weak self] e in
      switch e {
      case .button(let id): self?.onPromptEvent(["kind": "button", "id": id])
      case .choice(let id): self?.onPromptEvent(["kind": "choice", "id": id])
      case .toggle(let on): self?.onPromptEvent(["kind": "toggle", "value": on])
      case .close: self?.onPromptEvent(["kind": "close"])
      case .row(let id): self?.onPromptEvent(["kind": "row", "id": id])
      }
    }
  }

  func setState(_ next: String) {
    guard next != json, let state = PromptState.decode(next) else { return }
    json = next
    host.mount(next)
    body.update(state)
  }
}

@MainActor
final class PromptPopoverHost {
  private weak var owner: NSView?
  private let body: NSView
  private let dismiss: () -> Void
  private var popover: PopoverView?
  private var mounted = false
  private var bodyHeight: CGFloat = 0

  init(owner: NSView, body: NSView, dismiss: @escaping () -> Void) {
    self.owner = owner
    self.body = body
    self.dismiss = dismiss
  }

  func mount(_ json: String) {
    guard let owner, let data = json.data(using: .utf8) else { return }
    let placement = PanelPopover.placement(data)
    if !mounted {
      mounted = true
      if placement != nil {
        let made = PopoverView(body: body)
        made.autoresizingMask = [.width, .height]
        made.frame = owner.bounds
        made.onDismiss = { [weak self] in self?.dismiss() }
        owner.addSubview(made)
        popover = made
      } else {
        body.autoresizingMask = [.width, .height]
        body.frame = owner.bounds
        owner.addSubview(body)
      }
    }
    guard let popover, let placement else { return }
    popover.set(placement: placement, dark: PanelPopover.dark(data))
    if bodyHeight > 0 { popover.set(bodyHeight: bodyHeight) }
  }

  func report(_ height: CGFloat) -> Bool {
    bodyHeight = height
    guard let popover else { return false }
    DispatchQueue.main.async { popover.set(bodyHeight: height) }
    return true
  }
}

public class DeviceChooserModule: Module {
  public func definition() -> ModuleDefinition {
    Name("SolaraDeviceChooser")

    View(NativeDeviceChooserView.self) {
      Events("onChooserEvent", "onChooserHeight")

      Prop("state") { (view: NativeDeviceChooserView, v: String) in MainActor.assumeIsolated { view.setState(v) } }
    }
  }
}

final class NativeDeviceChooserView: ExpoView {
  let onChooserEvent = EventDispatcher()
  let onChooserHeight = EventDispatcher()
  let body = DeviceChooserView(frame: .zero)
  private var json = ""
  private lazy var host = PromptPopoverHost(owner: self, body: body) { [weak self] in self?.onChooserEvent(["kind": "dismiss"]) }

  override var isFlipped: Bool { true }

  override func hitTest(_ point: NSPoint) -> NSView? {
    let hit = super.hitTest(point)
    return hit === self ? nil : hit
  }

  required init(appContext: AppContext? = nil) {
    super.init(appContext: appContext)
    body.onHeight = { [weak self] h in
      guard let self else { return }
      if !self.host.report(h) { self.onChooserHeight(["height": h]) }
    }
    body.onEvent = { [weak self] e in
      switch e {
      case .select(let i): self?.onChooserEvent(["kind": "select", "index": i])
      case .choose(let i): self?.onChooserEvent(["kind": "choose", "index": i ?? -1])
      case .cancel: self?.onChooserEvent(["kind": "cancel"])
      case .refresh: self?.onChooserEvent(["kind": "refresh"])
      case .openSettings: self?.onChooserEvent(["kind": "openSettings"])
      }
    }
  }

  func setState(_ next: String) {
    guard next != json, let state = DeviceChooserState.decode(next) else { return }
    json = next
    host.mount(next)
    body.update(state)
  }
}

public class PanelModule: Module {
  public func definition() -> ModuleDefinition {
    Name("SolaraPanel")

    View(NativePanelView.self) {
      Events("onPanelEvent", "onPanelHeight")

      Prop("kind") { (view: NativePanelView, v: String) in MainActor.assumeIsolated { view.kind = v } }
      Prop("state") { (view: NativePanelView, v: String) in MainActor.assumeIsolated { view.setState(v) } }
    }
  }
}

final class NativePanelView: ExpoView {
  let onPanelEvent = EventDispatcher()
  let onPanelHeight = EventDispatcher()
  var kind = "" { didSet { if kind != oldValue { apply() } } }
  private var json = ""
  private var applied = ""
  private var zoom: ZoomPanelView?
  private var history: HistoryPanelView?
  private var markUri: String?
  private var popover: PopoverView?

  override var isFlipped: Bool { true }

  override func hitTest(_ point: NSPoint) -> NSView? {
    let hit = super.hitTest(point)
    return hit === self ? nil : hit
  }

  private var bodyHeight: CGFloat = 0

  private func reportHeight(_ h: CGFloat) {
    bodyHeight = h
    if popover != nil {
      DispatchQueue.main.async { [weak self] in self?.popover?.set(bodyHeight: h) }
    } else {
      onPanelHeight(["height": h])
    }
  }

  func setState(_ next: String) {
    json = next
    apply()
  }

  private func apply() {
    let key = kind + "\u{1}" + json
    guard !kind.isEmpty, key != applied, let data = json.data(using: .utf8) else { return }
    applied = key
    defer { placePopover(data) }
    switch kind {
    case "zoom":
      guard let state = try? JSONDecoder().decode(ZoomPanelState.self, from: data) else { return }
      let body = zoom ?? make { ZoomPanelView(frame: .zero) }
      zoom = body
      body.onEvent = { [weak self] e in
        switch e {
        case .step(let step): self?.onPanelEvent(["kind": "step", "step": step])
        }
      }
      body.update(state)
    case "history":
      guard let state = try? JSONDecoder().decode(HistoryPanelState.self, from: data) else { return }
      let body = history ?? make { HistoryPanelView(frame: .zero) }
      if history == nil {
        body.favicons.loader = { request in try await NativeSidebar.favicon(request) }
        body.onHeight = { [weak self] h in self?.reportHeight(h) }
      }
      history = body
      body.onEvent = { [weak self] e in
        switch e {
        case .open(let index, let click):
          self?.onPanelEvent(["kind": "open", "index": index, "metaKey": click.meta, "shiftKey": click.shift, "altKey": click.alt, "middle": click.middle])
        case .fullHistory: self?.onPanelEvent(["kind": "fullHistory"])
        }
      }
      loadMark((try? JSONSerialization.jsonObject(with: data) as? [String: Any])?["newTabMark"] as? String, into: body)
      body.update(state)
    default:
      break
    }
  }

  private func loadMark(_ uri: String?, into body: HistoryPanelView) {
    guard let uri, uri != markUri else { return }
    markUri = uri
    HistoryPanelMark.load(uri, into: body)
  }

  private func make<Body: NSView>(_ build: () -> Body) -> Body {
    let body = build()
    if let zoom = body as? ZoomPanelView { zoom.onHeight = { [weak self] h in self?.reportHeight(h) } }
    if let data = json.data(using: .utf8), PanelPopover.placement(data) != nil {
      let made = PopoverView(body: body)
      made.autoresizingMask = [.width, .height]
      made.frame = bounds
      made.onDismiss = { [weak self] in self?.onPanelEvent(["kind": "dismiss"]) }
      addSubview(made)
      popover = made
    } else {
      body.autoresizingMask = [.width, .height]
      body.frame = bounds
      addSubview(body)
    }
    return body
  }

  private func placePopover(_ data: Data) {
    guard let popover, let placement = PanelPopover.placement(data) else { return }
    popover.set(placement: placement, dark: PanelPopover.dark(data))
    if bodyHeight > 0 { popover.set(bodyHeight: bodyHeight) }
  }
}

@MainActor
enum HistoryPanelMark {
  static func load(_ uri: String, into body: HistoryPanelView) {
    if let image = SettingsAdapters.image(uri) {
      image.isTemplate = true
      body.favicons.newTabMark = image
      return body.rebuildIcons()
    }
    guard let url = URL(string: uri) else { return }
    Task { @MainActor [weak body] in
      let image = await Task.detached { (try? Data(contentsOf: url)).flatMap(NSImage.init(data:)) }.value
      guard let body, let image else { return }
      image.isTemplate = true
      body.favicons.newTabMark = image
      body.rebuildIcons()
    }
  }
}

enum PanelPopover {
  private struct Envelope: Decodable {
    let popover: PopoverPlacement?
    let dark: Bool?
  }

  static func placement(_ data: Data) -> PopoverPlacement? { (try? JSONDecoder().decode(Envelope.self, from: data))?.popover }

  static func dark(_ data: Data) -> Bool { (try? JSONDecoder().decode(Envelope.self, from: data))?.dark ?? false }
}
