import AppKit
import ExpoModulesCore
import Foundation
import SolaraModel
import SolaraCore
import SolaraUI

public class SitePanelModule: Module {
  public func definition() -> ModuleDefinition {
    Name("SolaraSitePanel")

    #if DEBUG
    Function("devPanels") { (windowId: String) -> String in
      guard SolaraCoreTestHooksAllowed() else { return "[]" }
      if Thread.isMainThread { return MainActor.assumeIsolated { NativeSiteControls.shared.describe(windowId: windowId) } }
      return DispatchQueue.main.sync { MainActor.assumeIsolated { NativeSiteControls.shared.describe(windowId: windowId) } }
    }
    #endif

    View(NativeSitePanelView.self) {
      Events("onSitePanelClosed")

      Prop("request") { (view: NativeSitePanelView, v: String) in MainActor.assumeIsolated { view.setRequest(v) } }
    }
  }
}

final class NativeSitePanelView: ExpoView {
  let onSitePanelClosed = EventDispatcher()
  private var siteMenu: NativeSiteMenu?
  private var pendingRequest: JSONValue?

  private var mountedMenu: NativeSiteMenu? {
    guard let siteMenu, siteMenu.popover.superview === self else { return nil }
    return siteMenu
  }

  override var isFlipped: Bool { true }

  required init(appContext: AppContext? = nil) {
    super.init(appContext: appContext)
  }

  func setRequest(_ json: String) {
    guard let data = json.data(using: .utf8), let request = try? JSONValue.parse(data) else { return }
    if request["open"]?.bool != true {
      pendingRequest = nil
      mountedMenu?.close()
      return
    }
    pendingRequest = request
    applyRequest()
  }

  private func applyRequest() {
    guard let request = pendingRequest, let window, !bounds.isEmpty, let tabId = request["tabId"]?.string else { return }
    pendingRequest = nil
    if let menu = mountedMenu, !menu.popover.isClosing, menu.tabId == tabId {
      menu.update(request)
      menu.popover.layoutSubtreeIfNeeded()
      return
    }
    mountedMenu?.popover.removeFromSuperview()
    let controls = NativeSiteControls.shared
    let reused = controls.reusableMenu(tabId: tabId, window: window)
    let next = reused ?? NativeSiteMenu(input: request)
    siteMenu = next
    next.onClosed = { [weak self, weak next] in
      guard let self, let next, self.mountedMenu === next else { return }
      next.popover.removeFromSuperview()
      self.siteMenu = nil
      self.onSitePanelClosed([:])
    }
    next.popover.autoresizingMask = [.width, .height]
    addSubview(next.popover)
    next.popover.frame = bounds
    if reused == nil { controls.register(next); next.refresh() } else { next.update(request) }
    next.popover.layoutSubtreeIfNeeded()
  }

  override func hitTest(_ point: NSPoint) -> NSView? { mountedMenu?.popover.hitTest(point) }

  override func setFrameSize(_ newSize: NSSize) {
    super.setFrameSize(newSize)
    applyRequest()
  }

  override func viewDidMoveToWindow() {
    super.viewDidMoveToWindow()
    applyRequest()
  }

  override func viewWillMove(toWindow newWindow: NSWindow?) {
    if newWindow == nil, let menu = mountedMenu {
      if let window, NativeSiteControls.shared.park(menu, anchor: self, window: window) { siteMenu = nil }
      else { menu.close() }
    }
    super.viewWillMove(toWindow: newWindow)
  }
}
