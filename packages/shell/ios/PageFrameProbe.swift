#if DEBUG
import AppKit
import QuartzCore

@MainActor
enum PageFrameProbe {
  static let pageClasses: Set<String> = ["SolaraCoreWebView"]

  struct Page {
    let view: NSView
    let order: Int
  }

  static func pages(in root: NSView) -> [Page] {
    var out: [Page] = []
    var order = 0
    func walk(_ view: NSView) {
      order += 1
      if pageClasses.contains(NSStringFromClass(type(of: view))) {
        out.append(Page(view: view, order: order))
        return
      }
      for sub in view.subviews { walk(sub) }
    }
    walk(root)
    return out
  }

  static func key(_ view: NSView) -> String {
    (view.value(forKey: "transferKey") as? String) ?? ""
  }

  static func onScreen(_ view: NSView) -> Bool {
    guard view.window != nil, !view.isHiddenOrHasHiddenAncestor else { return false }
    var v: NSView? = view
    while let current = v {
      if current.alphaValue <= 0.01 { return false }
      v = current.superview
    }
    return true
  }

  static func drawn(_ layer: CALayer?) -> Bool {
    guard let layer, !layer.isHidden, layer.opacity > 0.01 else { return false }
    if layer.contents != nil { return true }
    let name = NSStringFromClass(type(of: layer))
    if name.contains("LayerHost") { return true }
    return (layer.sublayers ?? []).contains { drawn($0) }
  }

  static func layers(_ layer: CALayer?, depth: Int = 0) -> [[String: Any]] {
    guard let layer, depth < 10 else { return [] }
    var me: [String: Any] = [
      "depth": depth, "class": NSStringFromClass(type(of: layer)), "contents": layer.contents.map { String(describing: type(of: $0)) } ?? NSNull(),
      "hidden": layer.isHidden, "opacity": layer.opacity, "bounds": [layer.bounds.width, layer.bounds.height],
      "background": layer.backgroundColor.map { $0.components ?? [] } ?? NSNull(),
    ]
    if let host = layer.value(forKey: "contextId") { me["contextId"] = host }
    return [me] + (layer.sublayers ?? []).flatMap { layers($0, depth: depth + 1) }
  }

  static func describe(_ root: NSView) -> [[String: Any]] {
    pages(in: root).map { page in
      let rect = page.view.convert(page.view.bounds, to: nil)
      return [
        "key": key(page.view), "class": NSStringFromClass(type(of: page.view)), "order": page.order,
        "onScreen": onScreen(page.view), "alpha": page.view.alphaValue, "drawn": drawn(page.view.layer),
        "frame": [rect.minX, rect.minY, rect.width, rect.height], "superview": page.view.superview.map { NSStringFromClass(type(of: $0)) } ?? NSNull(),
        "layers": layers(page.view.layer),
      ]
    }
  }

  static func look(_ layer: CALayer?) -> (background: String, hosts: [String]) {
    var background = "", hosts: [String] = []
    func walk(_ layer: CALayer?) {
      guard let layer, !layer.isHidden, layer.opacity > 0.01 else { return }
      if let color = layer.backgroundColor, color.alpha > 0.01, let c = color.components, c.count >= 3 {
        background = String(format: "%02X%02X%02X", Int(c[0] * 255), Int(c[1] * 255), Int(c[2] * 255))
      }
      if NSStringFromClass(type(of: layer)).contains("LayerHost") { hosts.append("\(layer.value(forKey: "contextId") ?? "?")") }
      for sub in layer.sublayers ?? [] { walk(sub) }
    }
    walk(layer)
    return (background, hosts)
  }

  static func frame(_ root: NSView) -> [String: Any] {
    let shown = pages(in: root).filter { onScreen($0.view) && $0.view.bounds.width > 100 }
    let top = shown.max { $0.order < $1.order }
    return [
      "shown": shown.map { key($0.view) }, "top": top.map { key($0.view) } ?? NSNull(),
      "topDrawn": top.map { drawn($0.view.layer) } ?? false, "anyDrawn": shown.contains { drawn($0.view.layer) },
      "background": top.map { look($0.view.layer).background } ?? "", "hosts": top.map { look($0.view.layer).hosts } ?? [],
      "held": shown.filter { ($0.view.value(forKey: "held") as? Bool) == true }.map { key($0.view) },
      "drawn": Dictionary(pages(in: root).compactMap { page -> (String, String)? in
        guard page.view.responds(to: NSSelectorFromString("drawnReport")), let report = page.view.value(forKey: "drawnReport") as? String, !report.isEmpty else { return nil }
        return (key(page.view), report)
      }, uniquingKeysWith: { first, _ in first }),
    ]
  }

  static func trace(_ window: NSWindow, seconds: Double, done: @escaping @MainActor ([[String: Any]]) -> Void) {
    guard let root = window.contentView else { return done([]) }
    let start = CACurrentMediaTime()
    var samples: [[String: Any]] = []
    let timer = Timer(timeInterval: 1.0 / 120, repeats: true) { timer in
      MainActor.assumeIsolated {
        var sample = frame(root)
        sample["t"] = Int((CACurrentMediaTime() - start) * 1000)
        samples.append(sample)
        if CACurrentMediaTime() - start >= seconds {
          timer.invalidate()
          done(samples)
        }
      }
    }
    RunLoop.main.add(timer, forMode: .common)
  }
}
#endif
