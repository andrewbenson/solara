import AppKit
import SolaraShell
import Foundation
import SolaraUI

@MainActor
enum NativeToolTour {
  nonisolated static let kind = "toolTour"

  static func register() {
    HostedViews.register(kind) { windowId in
      let host = ToolTourHost()
      host.model.send = { name in HostedViews.send(kind, windowId: windowId, name, [:]) }
      return HostedContent(view: host, takesFocus: false, onState: { [weak host] json in host?.model.apply(json) })
    }
  }
}

#if SOLARA_PROBES
@MainActor
public enum ToolTourRead {
  public static func snapshot(windowId: String) -> [String: Any]? {
    guard let root = WindowHost.window(id: windowId)?.contentView else { return nil }
    func find(_ view: NSView) -> ToolTourHost? {
      if let host = view as? ToolTourHost { return host }
      for child in view.subviews {
        if let host = find(child) { return host }
      }
      return nil
    }
    guard let host = find(root) else { return nil }
    let model = host.model
    func rect(_ frame: CGRect) -> [CGFloat] { [frame.minX, frame.minY, frame.width, frame.height] }
    let card = model.cardHeight.map { CGRect(origin: model.cardOrigin, size: CGSize(width: ToolTourLayout.cardWidth, height: $0)) }
    return ["active": model.active, "visible": model.visible && !host.isHiddenOrHasHiddenAncestor,
      "index": model.index, "stops": model.stops.map(\.id),
      "card": card.map(rect) ?? NSNull(), "hole": rect(model.hole.rect),
      "target": model.target.map(rect) ?? NSNull(), "controls": model.controlFrames.mapValues(rect)]
  }

}
#endif
