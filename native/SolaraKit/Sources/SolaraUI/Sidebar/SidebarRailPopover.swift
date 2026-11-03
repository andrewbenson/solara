import AppKit

struct SidebarRailPopoverRow {
  var content: SidebarFolderPeekState.Row
  var action: SidebarAction
}

@MainActor
final class SidebarRailPopover: NSObject, NSPopoverDelegate {
  let popover = NSPopover()
  let renameKey: String?
  private let content = SidebarRailPopoverBody()
  private var field: SidebarRenameField?
  private var closed = false

  init(title: String, rows: [SidebarRailPopoverRow], context: SidebarContext) {
    renameKey = nil
    super.init()
    prepare()
    let peek = SidebarFolderPeekView(favicons: context.favicons)
    peek.set(SidebarFolderPeekState(
      folderId: "", title: title, rows: rows.map(\.content), more: nil, anchor: [], dark: context.palette.dark,
      shadowOpacity: 0, theme: context.host.theme))
    let send = context.send
    peek.onChoose = { [weak self] id in
      guard let row = rows.first(where: { $0.content.id == id }) else { return }
      self?.close()
      switch row.action {
      case .click(let tabId, _): send(.click(tabId: tabId, mods: SidebarClickMods(NSEvent.modifierFlags)))
      case .live(let action, let folderId, let id, _): send(.live(action: action, folderId: folderId, id: id, meta: NSEvent.modifierFlags.contains(.command)))
      default: send(row.action)
      }
    }
    content.install(peek, height: min(400, peek.height))
    popover.contentSize = content.frame.size
  }

  init(kind: String, id: String, initial: String, placeholder: String, context: SidebarContext) {
    renameKey = "\(kind):\(id)"
    super.init()
    prepare()
    let field = SidebarRenameField(initial: initial, placeholder: placeholder, font: .systemFont(ofSize: 13), color: context.palette.textPrimary)
    let send = context.send
    field.onDone = { [weak self] text in
      self?.close()
      send(.renamed(kind: kind, id: id, text: text))
    }
    self.field = field
    content.install(field)
    popover.contentSize = content.frame.size
  }

  private func prepare() {
    popover.behavior = .transient
    popover.animates = false
    popover.delegate = self
    let controller = NSViewController()
    controller.view = content
    popover.contentViewController = controller
    content.onCancel = { [weak self] in
      if let field = self?.field { field.finish(nil) } else { self?.close() }
    }
  }

  func show(on row: RailIconView) {
    guard !closed, !popover.isShown, row.window != nil else { return }
    popover.show(relativeTo: row.body.convert(row.icon.frame, to: row), of: row, preferredEdge: .maxX)
    if let field { field.begin() } else { content.window?.makeFirstResponder(content) }
  }

  func close(commitRename: Bool = true) {
    guard !closed else { return }
    closed = true
    if !commitRename { field?.onDone = nil }
    if !popover.isShown { field?.finish(field?.stringValue) }
    popover.performClose(nil)
  }

  func popoverWillClose(_ notification: Notification) {
    closed = true
    field?.finish(field?.stringValue)
  }
}

@MainActor
private final class SidebarRailPopoverBody: NSView {
  var onCancel: (() -> Void)?
  private var scroll: NSScrollView?
  private var field: SidebarRenameField?

  override var isFlipped: Bool { true }
  override var acceptsFirstResponder: Bool { true }

  func install(_ peek: SidebarFolderPeekView, height: CGFloat) {
    let scroll = NSScrollView()
    scroll.drawsBackground = false
    scroll.hasVerticalScroller = peek.height > height
    scroll.hasHorizontalScroller = false
    scroll.documentView = peek
    addSubview(scroll)
    self.scroll = scroll
    setFrameSize(NSSize(width: SidebarFolderPeekMetrics.width, height: height))
    needsLayout = true
  }

  func install(_ field: SidebarRenameField) {
    addSubview(field)
    self.field = field
    setFrameSize(NSSize(width: SidebarFolderPeekMetrics.width, height: 44))
    needsLayout = true
  }

  override func layout() {
    super.layout()
    scroll?.frame = bounds
    field?.frame = NSRect(x: 12, y: 12, width: max(0, bounds.width - 24), height: 20)
  }

  override func cancelOperation(_ sender: Any?) { onCancel?() }
}
