#if SOLARA_PROBES && canImport(AppKit)
import AppKit
import QuartzCore

@MainActor
public final class ProbeCapture {
  public typealias Restore = @MainActor () -> Void
  public static let shared = ProbeCapture()

  private struct Entry {
    weak var view: NSView?
    let prepare: @MainActor (NSView) throws -> Restore
  }

  private var entries: [Entry] = []

  public init() {}

  public func register<View: NSView>(_ view: View, prepare: @escaping @MainActor (View) throws -> Restore) {
    entries.removeAll { $0.view == nil }
    entries.append(Entry(view: view, prepare: { view in
      guard let view = view as? View else { return {} }
      return try prepare(view)
    }))
  }

  public func withPreparedWindow<Result>(_ window: NSWindow, render: () throws -> Result) throws -> Result {
    CATransaction.begin()
    CATransaction.setDisableActions(true)
    var restores: [Restore] = []
    defer {
      for restore in restores.reversed() { restore() }
      CATransaction.commit()
    }
    window.contentView?.layoutSubtreeIfNeeded()
    window.contentView?.displayIfNeeded()
    entries.removeAll { $0.view == nil }
    for entry in entries {
      guard let view = entry.view, view.window === window else { continue }
      restores.append(try entry.prepare(view))
    }
    return try render()
  }
}
#endif
