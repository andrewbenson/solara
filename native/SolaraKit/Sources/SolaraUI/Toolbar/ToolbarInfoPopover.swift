import AppKit

@MainActor
public final class ToolbarInfoPopover: NSObject, NSPopoverDelegate {
  static let width: CGFloat = 280
  static let inset: CGFloat = 16
  static let gap: CGFloat = 6

  public private(set) static var current: ToolbarInfoPopover?

  public let info: ToolbarInfoState
  let popover = NSPopover()
  private let onAction: () -> Void

  init(info: ToolbarInfoState, onAction: @escaping () -> Void) {
    self.info = info
    self.onAction = onAction
    super.init()
    popover.behavior = .transient
    popover.animates = ProcessInfo.processInfo.environment["SOLARA_BACKGROUND"] != "1"
    popover.delegate = self
    popover.contentViewController = ToolbarInfoContent(info: info) { [weak self] in self?.act() }
  }

  @discardableResult
  static func show(_ info: ToolbarInfoState, relativeTo view: NSView, onAction: @escaping () -> Void) -> ToolbarInfoPopover {
    current?.popover.close()
    let made = ToolbarInfoPopover(info: info, onAction: onAction)
    current = made
    if view.window != nil {
      made.popover.show(relativeTo: view.bounds, of: view, preferredEdge: .minY)
    }
    return made
  }

  public static func describe() -> [String: Any]? {
    guard let current else { return nil }
    return ["title": current.info.title, "message": current.info.message, "action": current.info.action, "shown": current.popover.isShown]
  }

  public static func pressAction() -> Bool {
    guard let current else { return false }
    current.act()
    return true
  }

  public static func close() {
    current?.popover.close()
    current = nil
  }

  func act() {
    popover.close()
    if ToolbarInfoPopover.current === self { ToolbarInfoPopover.current = nil }
    onAction()
  }

  public func popoverDidClose(_ notification: Notification) {
    if ToolbarInfoPopover.current === self { ToolbarInfoPopover.current = nil }
  }
}

final class ToolbarInfoContent: NSViewController {
  let info: ToolbarInfoState
  let onAction: () -> Void
  let titleField = NSTextField(labelWithString: "")
  let messageField = NSTextField(wrappingLabelWithString: "")
  let button = NSButton(title: "", target: nil, action: nil)

  init(info: ToolbarInfoState, onAction: @escaping () -> Void) {
    self.info = info
    self.onAction = onAction
    super.init(nibName: nil, bundle: nil)
  }

  required init?(coder: NSCoder) { fatalError() }

  override func loadView() {
    let m = ToolbarInfoPopover.self
    let inner = m.width - 2 * m.inset
    titleField.stringValue = info.title
    titleField.font = .systemFont(ofSize: 13, weight: .semibold)
    messageField.stringValue = info.message
    messageField.font = .systemFont(ofSize: 12)
    messageField.textColor = .secondaryLabelColor
    messageField.preferredMaxLayoutWidth = inner
    button.title = info.action
    button.bezelStyle = .push
    button.keyEquivalent = "\r"
    button.target = self
    button.action = #selector(pressed(_:))
    let titleHeight = ceil(titleField.fittingSize.height)
    let messageHeight = ceil(messageField.sizeThatFits(NSSize(width: inner, height: .greatestFiniteMagnitude)).height)
    let buttonSize = button.fittingSize
    let height = m.inset + titleHeight + m.gap + messageHeight + m.inset + buttonSize.height + m.inset
    let root = NSView(frame: NSRect(x: 0, y: 0, width: m.width, height: height))
    var y = height - m.inset - titleHeight
    titleField.frame = NSRect(x: m.inset, y: y, width: inner, height: titleHeight)
    y -= m.gap + messageHeight
    messageField.frame = NSRect(x: m.inset, y: y, width: inner, height: messageHeight)
    button.frame = NSRect(x: m.width - m.inset - buttonSize.width, y: m.inset, width: buttonSize.width, height: buttonSize.height)
    for view in [titleField, messageField, button] { root.addSubview(view) }
    view = root
    preferredContentSize = root.frame.size
  }

  @objc private func pressed(_ sender: Any?) { onAction() }
}
