import AppKit

extension NSView {
  public func fullScreenPoint(_ point: NSPoint, from source: NSView? = nil) -> NSPoint {
    guard let shell = windowShell else { return convert(point, from: source) }
    var local = shell.convert(point, from: source)
    let sourceOffset = source.map { shell.fullScreenPresentationOffset(for: $0) } ?? 0
    local.y += sourceOffset - shell.fullScreenPresentationOffset(for: self)
    return convert(local, from: shell)
  }

  public func fullScreenRect(_ rect: NSRect, to destination: NSView? = nil) -> NSRect {
    guard let shell = windowShell else { return convert(rect, to: destination) }
    var local = shell.convert(rect, from: self)
    let destinationOffset = destination.map { shell.fullScreenPresentationOffset(for: $0) } ?? 0
    local.origin.y += shell.fullScreenPresentationOffset(for: self) - destinationOffset
    return destination.map { $0.convert(local, from: shell) } ?? shell.convert(local, to: nil)
  }
}
