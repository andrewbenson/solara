import AppKit
import ExpoModulesCore

final class SolaraHostedView: ExpoView {
  var kind = ""
  var windowId = ""
  var active = true
  var state = ""
  private var mount: HostedMount?
  private var mountedKey: String?

  override var isFlipped: Bool { true }

  override func hitTest(_ point: NSPoint) -> NSView? {
    let hit = super.hitTest(point)
    return hit === self ? nil : hit
  }

  func propsDidUpdate() {
    sync()
  }

  override func viewDidMoveToWindow() {
    super.viewDidMoveToWindow()
    sync()
  }

  override func viewWillMove(toWindow newWindow: NSWindow?) {
    if newWindow == nil { unmount() }
    super.viewWillMove(toWindow: newWindow)
  }

  func sync() {
    let key = "\(kind)\u{1}\(windowId)"
    guard active, !kind.isEmpty, let window else { return unmount() }
    if mount != nil && mountedKey == key { return deliverState() }
    unmount()
    guard let content = HostedViews.make(kind, windowId: windowId, state: state) else { return }
    mountedKey = key
    mount = HostedMount(content: content, in: self, window: window)
    deliverState()
  }

  private func deliverState() {
    mount?.content.onState?(state)
  }

  func unmount() {
    let current = mount
    mount = nil
    mountedKey = nil
    current?.end()
  }

  var mountedView: NSView? { mount?.content.view }
}
