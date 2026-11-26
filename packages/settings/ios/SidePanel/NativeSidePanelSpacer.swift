import AppKit
import ExpoModulesCore
import React

final class NativeSidePanelSpacer: ExpoView {
  var windowId = "" {
    didSet { if windowId != oldValue { updateRoom() } }
  }

  required init(appContext: AppContext? = nil) {
    super.init(appContext: appContext)
    NotificationCenter.default.addObserver(self, selector: #selector(roomChanged(_:)), name: NativeExtensionSidePanel.roomDidChange, object: nil)
  }

  override func viewDidMoveToWindow() {
    super.viewDidMoveToWindow()
    updateRoom()
  }

  override func hitTest(_ point: NSPoint) -> NSView? { nil }

  @objc private func roomChanged(_ note: Notification) {
    if note.object as? String == windowId { updateRoom() }
  }

  private func updateRoom() {
    guard reactTag != nil else { return }
    let room = NativeExtensionSidePanel.room(windowId)
    appContext?.reactBridge?.uiManager.setIntrinsicContentSize(CGSize(width: room, height: NSView.noIntrinsicMetric), for: self)
  }
}
