import AppKit

@MainActor
public enum ShellDrag {
  public static func windowId(of window: NSWindow) -> String? {
    WindowManager.shared.windows.first { $0.value === window }?.key
  }

  public static func window(_ id: String) -> NSWindow? {
    WindowManager.shared.windows[id]
  }

  public static func previewBegin(windowId: String, chip: NSRect, grab: NSPoint) {
    DragPreview.shared.begin(windowId: windowId, chip: chip, grab: grab)
  }

  public static func previewUpdate(_ shape: String, at local: NSPoint) {
    DragPreview.shared.update(shape: shape, at: local)
  }

  public static func previewEnd(windowId: String?, fallback: NSRect?) {
    DragPreview.shared.end(windowId: windowId, fallback: fallback)
  }

  public static func previewCancel() {
    DragPreview.shared.cancel()
  }

  public static func previewPage(base64: String, frame: [Double]) {
    guard frame.count == 4, let data = Data(base64Encoded: base64) else { return }
    DragPreview.shared.setPage(data, frame: NSRect(x: frame[0], y: frame[1], width: frame[2], height: frame[3]))
  }

  public static func previewPlaceholder(title: String, favicon: String?) {
    DragPreview.shared.setPlaceholder(title: title, favicon: favicon)
  }

  public static func hapticTick() {
    ShellHaptics.alignment()
    HapticLog.note("alignment")
  }

  public static func focus(_ id: String) {
    WindowManager.shared.focus(id: id)
  }
}
