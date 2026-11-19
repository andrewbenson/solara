import AppKit
import QuartzCore

@MainActor
public final class SidebarDragTrace: NSObject {
  public static let shared = SidebarDragTrace()
  public static let ghostIdentifier = "sidebar-drag-ghost"

  private var link: CADisplayLink?
  private var identifier = ""
  private var started: CFTimeInterval = 0
  private var until: CFTimeInterval = 0
  public private(set) var samples: [[Double]] = []

  public func start(_ identifier: String, milliseconds: Double) {
    #if SOLARA_PROBES
    NativeWorkCounters.unlink(link)
    #endif
    link?.invalidate()
    self.identifier = identifier
    samples = []
    started = CACurrentMediaTime()
    until = started + milliseconds / 1000
    guard let screen = NSScreen.main ?? NSScreen.screens.first else { return }
    let link = screen.displayLink(target: self, selector: #selector(tick(_:)))
    #if SOLARA_PROBES
    NativeWorkCounters.link(link)
    #endif
    link.add(to: .main, forMode: .common)
    self.link = link
  }

  @objc private func tick(_ link: CADisplayLink) {
    let now = CACurrentMediaTime()
    guard now <= until else {
      #if SOLARA_PROBES
      NativeWorkCounters.unlink(link)
      #endif
      link.invalidate()
      self.link = nil
      return
    }
    let t = (now - started) * 1000
    guard let view = NSApp.windows.lazy.compactMap({ $0.contentView.flatMap { Self.find(self.identifier, in: $0) } }).first,
      let frame = Self.shownFrame(view)
    else { return samples.append([t]) }
    samples.append([t, Double(frame.minX), Double(frame.minY), Double(frame.width), Double(frame.height), Double(Self.shownOpacity(view))])
  }

  private static func find(_ identifier: String, in view: NSView) -> NSView? {
    if view.identifier?.rawValue == identifier || view.accessibilityIdentifier() == identifier { return view }
    for child in view.subviews {
      if let hit = find(identifier, in: child) { return hit }
    }
    return nil
  }

  static func shownFrame(_ view: NSView) -> CGRect? {
    guard let window = view.window, let content = window.contentView else { return nil }
    let r = view.convert(view.bounds, to: nil)
    var frame = CGRect(x: r.minX, y: content.bounds.height - r.maxY, width: r.width, height: r.height)
    if let model = view.layer {
      let shown = model.presentation() ?? model
      let dx = shown.position.x - model.position.x + shown.transform.m41
      let dy = shown.position.y - model.position.y + shown.transform.m42
      frame.origin.x += dx
      frame.origin.y += (view.superview?.isFlipped ?? false) ? dy : -dy
    }
    return frame
  }

  #if DEBUG
  private var rowsLink: CADisplayLink?
  private var rowsSource: (() -> [[String: Any]])?
  private var rowsUntil: CFTimeInterval = 0
  public private(set) var rowSamples: [[String: Any]] = []

  public func startRows(milliseconds: Double, _ source: @escaping () -> [[String: Any]]) {
    rowsLink?.invalidate()
    rowSamples = []
    rowsSource = source
    started = CACurrentMediaTime()
    rowsUntil = started + milliseconds / 1000
    guard let screen = NSScreen.main ?? NSScreen.screens.first else { return }
    let link = screen.displayLink(target: self, selector: #selector(rowsTick(_:)))
    link.add(to: .main, forMode: .common)
    rowsLink = link
  }

  @objc private func rowsTick(_ link: CADisplayLink) {
    let now = CACurrentMediaTime()
    guard now <= rowsUntil, let source = rowsSource else {
      link.invalidate()
      rowsLink = nil
      return
    }
    rowSamples.append(["t": (now - started) * 1000, "rows": source()])
  }
  #endif

  private static func shownOpacity(_ view: NSView) -> Float {
    var opacity: Float = 1
    var next: NSView? = view
    while let v = next {
      opacity *= (v.layer?.presentation() ?? v.layer)?.opacity ?? 1
      next = v.superview
    }
    return opacity
  }
}
