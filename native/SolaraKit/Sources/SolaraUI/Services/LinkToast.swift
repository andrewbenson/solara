import AppKit

@MainActor
public final class LinkToast: NSView {
  private let toast = SplitToastView()
  public override func viewWillMove(toSuperview next: NSView?) { if next == nil { toast.stop() } }
  public override var isFlipped: Bool { true }

  public static func show(in host: NSView, title: String, message: String? = nil, quote: Bool = false, action: (() -> Void)? = nil) {
    host.subviews.compactMap { $0 as? LinkToast }.forEach { $0.removeFromSuperview() }
    let view = LinkToast(frame: host.bounds)
    view.autoresizingMask = [.width, .height]
    view.toast.frame = view.bounds
    view.toast.autoresizingMask = [.width, .height]
    view.addSubview(view.toast)
    view.toast.onHidden = { [weak view] _ in view?.removeFromSuperview() }
    view.toast.onAction = { [weak view] _ in view?.removeFromSuperview(); action?() }
    host.addSubview(view)
    view.toast.show(SplitToastSpec(id: 1, title: title, message: message ?? (quote ? "Share a link directly to this text instead?" : nil), icon: "link", action: quote ? "Copy Quote Link" : nil))
  }

  public override func hitTest(_ point: NSPoint) -> NSView? { toast.hitTest(convert(point, from: superview)) }
}
