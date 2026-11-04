import AppKit

@objc(SolaraShareMenu)
public final class ContextShareMenu: NSObject {
  static let anchors: [String: [String]] = [
    "share:selection": ["copy"],
    "share:link": ["copyLink"],
    "share:image": ["copyImage", "copyImageLink"],
    "share:media": ["copyMediaLink"],
    "share:page": ["print"],
  ]

  @objc(menuItemForContext:)
  public static func menuItem(forContext fields: [String: Any]) -> [String: Any]? {
    guard let item = ShareContent.menuItem(for: ShareContext(fields)) else { return nil }
    var described: [String: Any] = ["id": item.id, "title": item.title, "after": anchors[item.id] ?? []]
    if item.id == "share:image" { described["needs"] = "image" }
    return described
  }

  @objc(shareContext:fromView:)
  public static func share(context fields: [String: Any], from view: NSView) {
    guard let content = ShareContent.choose(ShareContext(fields)) else { return }
    let point = NSPoint(x: (fields["x"] as? NSNumber)?.doubleValue ?? view.bounds.midX, y: (fields["y"] as? NSNumber)?.doubleValue ?? 40)
    SharePicker.show(content, imagePath: fields["imagePath"] as? String, view: view, at: point)
  }
}
