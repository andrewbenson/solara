import AppKit

@MainActor
public final class BookmarksBarView: NSView {
  public var onAction: (_ name: String, _ payload: [String: Any]) -> Void = { _, _ in }
  public private(set) var snapshot: BookmarksBarSnapshot?

  private let favicons: PageFavicons
  private var items: [BookmarksBarButton] = []
  private let overflow = BookmarksBarButton()
  private let other = BookmarksBarButton()
  private let importButton = BookmarksBarButton()
  private let hint = NSTextField(labelWithString: "For quick access, place your bookmarks here on the bookmarks bar.")
  private let divider = NSView()
  private var overflowIds: [String] = []

  public override var isFlipped: Bool { true }
  public override var mouseDownCanMoveWindow: Bool { false }

  public init(favicons: PageFavicons) {
    self.favicons = favicons
    super.init(frame: .zero)
    wantsLayer = true
    layer?.masksToBounds = true
    setAccessibilityRole(.group)
    setAccessibilityLabel("Bookmarks bar")
    hint.font = BookmarksBarButton.font
    hint.lineBreakMode = .byTruncatingTail
    divider.wantsLayer = true
    divider.setAccessibilityElement(false)
    for view in [overflow, other, importButton, hint, divider] {
      view.isHidden = true
      addSubview(view)
    }
    overflow.onPress = { [weak self] _, _ in
      guard let self else { return }
      self.emit("overflowPress", ["ids": self.overflowIds])
    }
    overflow.onContext = { [weak self] in self?.emit("contextMenu") }
    other.onPress = { [weak self] _, _ in self?.emit("otherPress") }
    other.onContext = { [weak self] in self?.emit("contextMenu") }
    importButton.onPress = { [weak self] _, _ in self?.emit("importPress") }
    importButton.onContext = { [weak self] in self?.emit("importContextMenu") }
  }

  required init?(coder: NSCoder) { fatalError() }

  public func update(_ snapshot: BookmarksBarSnapshot) {
    self.snapshot = snapshot
    while items.count > snapshot.items.count { items.removeLast().removeFromSuperview() }
    for (index, item) in snapshot.items.enumerated() {
      let button: BookmarksBarButton
      if index < items.count {
        button = items[index]
      } else {
        button = BookmarksBarButton()
        items.append(button)
        addSubview(button, positioned: .below, relativeTo: overflow)
      }
      button.configure(title: item.displayTitle, symbol: item.kind == .folder ? "folder" : "globe", folder: item.kind == .folder, theme: snapshot.theme)
      button.toolTip = item.kind == .url ? [item.title, item.url ?? ""].filter { !$0.isEmpty }.joined(separator: "\n") : item.title
      button.setFavicon(item.kind == .url ? item : nil, profileId: snapshot.profileId, dark: snapshot.dark, favicons: favicons)
      button.onPress = { [weak self] flags, middle in
        self?.emit("press", ["id": item.id, "metaKey": flags.contains(.command), "shiftKey": flags.contains(.shift), "altKey": flags.contains(.option), "ctrlKey": flags.contains(.control), "middle": middle])
      }
      button.onContext = { [weak self] in self?.emit("contextMenu", ["id": item.id]) }
    }
    overflow.configure(title: "", symbol: "chevron.right.2", folder: false, theme: snapshot.theme)
    overflow.setAccessibilityLabel("More bookmarks")
    overflow.toolTip = "More bookmarks"
    other.configure(title: "Other Bookmarks", symbol: "folder", folder: true, theme: snapshot.theme)
    importButton.configure(title: "Import bookmarks", symbol: "rectangle.portrait.and.arrow.right", folder: false, theme: snapshot.theme)
    importButton.toolTip = "Add bookmarks from another browser"
    hint.textColor = toolbarColor(snapshot.theme["textTertiary"]) ?? .secondaryLabelColor
    divider.layer?.backgroundColor = (toolbarColor(snapshot.theme["divider"]) ?? .separatorColor).cgColor
    needsLayout = true
  }

  public override func setFrameSize(_ newSize: NSSize) {
    super.setFrameSize(newSize)
    needsLayout = true
  }

  public override func layout() {
    super.layout()
    guard let snapshot else { return }
    let layout = BookmarksBarLayout(itemWidths: items.map(\.measuredWidth), width: bounds.width, hasOther: snapshot.hasOther && snapshot.otherId != nil)
    for item in items { item.isHidden = true }
    for placement in layout.visible {
      items[placement.index].frame = placement.frame
      items[placement.index].isHidden = false
    }
    overflowIds = layout.overflowIndexes.map { snapshot.items[$0].id }
    place(overflow, layout.overflowFrame)
    place(other, layout.otherFrame.map { CGRect(x: $0.minX, y: $0.minY, width: min($0.width, other.measuredWidth), height: $0.height) })
    place(divider, layout.dividerFrame)
    let empty = items.isEmpty
    importButton.isHidden = !empty || snapshot.hideBookmarksBarImport
    importButton.frame = CGRect(x: 8, y: 3, width: min(importButton.measuredWidth, layout.contentFrame.width), height: 24)
    hint.isHidden = !empty || !snapshot.hideBookmarksBarImport
    let height = hint.fittingSize.height
    hint.frame = CGRect(x: 12, y: (30 - height) / 2, width: max(0, layout.contentFrame.width - 4), height: height)
    setAccessibilityChildren(subviews.filter { !$0.isHidden && $0 !== divider })
  }

  public override func rightMouseDown(with event: NSEvent) {
    guard isHitBy(event) else { return super.rightMouseDown(with: event) }
    emit("contextMenu")
  }

  public override func mouseDown(with event: NSEvent) {
    guard event.modifierFlags.contains(.control), isHitBy(event) else { return super.mouseDown(with: event) }
    emit("contextMenu")
  }

  private func place(_ view: NSView, _ frame: CGRect?) {
    view.isHidden = frame == nil
    if let frame { view.frame = frame }
  }

  private func emit(_ name: String, _ payload: [String: Any] = [:]) {
    guard let snapshot else { return }
    var payload = payload
    payload["profileId"] = snapshot.profileId
    onAction(name, payload)
  }
}
