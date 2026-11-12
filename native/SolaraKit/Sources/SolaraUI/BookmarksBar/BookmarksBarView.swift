import AppKit
import SolaraEngine

@MainActor
public final class BookmarksBarView: NSView {
  public var onFocusPage: () -> Void = {}
  public var onAction: (_ name: String, _ payload: [String: Any]) -> Void = { _, _ in }
  public private(set) var snapshot: BookmarksBarSnapshot?
  public var resolveTab: (String) -> BookmarksBarDroppedLink? = { _ in nil }
  public var windowId = "" {
    didSet { registerTabDrops() }
  }

  private lazy var tabDropZone = BookmarksBarTabDropZone(view: self)
  private var linkDrop: BookmarksBarLinkDrop.Destination?

  private lazy var navigation = BookmarksBarNavigation(view: self)
  #if DEBUG
  private var simulatingKey = false
  private var openedMenu: [String: Any]?
  private var openedMenuItems: [[String: Any]] = []
  #endif
  private let favicons: PageFavicons
  private var items: [BookmarksBarButton] = []
  private var itemsNeedUpdate = true
  private let overflow = BookmarksBarButton()
  private let other = BookmarksBarButton()
  private let importButton = BookmarksBarButton()
  private let recoveryButton = BookmarksBarButton()
  private var recoveryMessage: String?
  private let hint = NSTextField(labelWithString: "For quick access, place your bookmarks here on the bookmarks bar.")
  private let divider = NSView()
  private var overflowIds: [String] = []
  private var placements: [BookmarksBarLayout.Placement] = []
  private let insertion = CALayer()
  private var drag: Drag?
  private var dragWatch: BookmarksBarDragWatch?

  private struct Drag {
    var id: String
    var index: Int
    var down: CGPoint
    var frame: CGRect
    var active = false
    var offsetX: CGFloat = 0
    var target: BookmarksBarDropTarget?
  }

  public override var isFlipped: Bool { true }
  public override var mouseDownCanMoveWindow: Bool { false }

  public init(favicons: PageFavicons) {
    self.favicons = favicons
    super.init(frame: .zero)
    wantsLayer = true
    layer?.masksToBounds = true
    insertion.isHidden = true
    insertion.cornerRadius = 1
    insertion.zPosition = 20
    layer?.addSublayer(insertion)
    registerForDraggedTypes(BookmarksBarLinkDrop.types)
    setAccessibilityElement(true)
    setAccessibilityRole(.toolbar)
    setAccessibilityLabel("Bookmarks bar")
    hint.font = BookmarksBarButton.font
    hint.lineBreakMode = .byTruncatingTail
    divider.wantsLayer = true
    divider.setAccessibilityElement(false)
    for view in [overflow, other, importButton, recoveryButton, hint, divider] {
      view.isHidden = true
      addSubview(view)
    }
    overflow.controlId = "overflow"
    overflow.controlKind = .overflow
    other.controlId = "other"
    other.controlKind = .other
    recoveryButton.controlId = "recovery"
    recoveryButton.controlKind = .importButton
    recoveryButton.onPress = { [weak self] _, _ in
      guard let self, let message = self.recoveryMessage, let window = self.window else { return }
      let alert = NSAlert()
      alert.messageText = "Bookmark recovery"
      alert.informativeText = message
      alert.addButton(withTitle: "OK")
      alert.beginSheetModal(for: window)
    }
    importButton.controlId = "import"
    importButton.controlKind = .importButton
    overflow.onOpenMenu = { [weak self] in
      guard let self else { return }
      self.showMenu(trigger: "overflow", anchor: self.overflow, selectFirst: true)
    }
    other.onOpenMenu = { [weak self] in
      guard let self else { return }
      self.showMenu(trigger: "other", anchor: self.other, selectFirst: true)
    }
    overflow.onPress = { [weak self] _, _ in
      guard let self else { return }
      self.showMenu(trigger: "overflow", anchor: self.overflow)
    }
    overflow.onContext = { [weak self] in
      guard let self else { return }
      self.showMenu(trigger: "blank", anchor: self.overflow)
    }
    other.onPress = { [weak self] _, _ in
      guard let self else { return }
      self.showMenu(trigger: "other", anchor: self.other)
    }
    other.onContext = { [weak self] in
      guard let self else { return }
      self.showMenu(trigger: "blank", anchor: self.other)
    }
    importButton.onPress = { [weak self] _, _ in self?.emit("importPress") }
    importButton.onContext = { [weak self] in
      guard let self else { return }
      self.showMenu(trigger: "import", anchor: self.importButton)
    }
  }

  required init?(coder: NSCoder) { fatalError() }

  public func update(_ snapshot: BookmarksBarSnapshot, recoveryMessage: String? = nil) {
    let coordinator = NativeBookmarkOwner.current?.coordinator
    self.recoveryMessage = recoveryMessage ?? coordinator?.recoveryNotice?.message ?? ((coordinator?.recoveryConflicts.isEmpty == false) ? "Some bookmark changes need recovery. Their saved source has been retained." : nil)
    navigation.captureFocus()
    clearLinkDrop()
    cancelDrag()
    self.snapshot = snapshot
    itemsNeedUpdate = true
    recoveryButton.configure(title: "Bookmark recovery", symbol: "exclamationmark.circle", folder: false, theme: snapshot.theme)
    recoveryButton.setAccessibilityLabel("Bookmark recovery")
    recoveryButton.toolTip = self.recoveryMessage
    overflow.configure(title: "", symbol: "chevron.right.2", folder: false, theme: snapshot.theme)
    overflow.setAccessibilityLabel("More bookmarks")
    overflow.toolTip = "More bookmarks"
    other.configure(title: "Other Bookmarks", symbol: "folder", folder: true, theme: snapshot.theme)
    importButton.configure(title: "Import bookmarks", symbol: "rectangle.portrait.and.arrow.right", folder: false, theme: snapshot.theme)
    importButton.toolTip = "Add bookmarks from another browser"
    hint.textColor = toolbarColor(snapshot.theme["textTertiary"]) ?? .secondaryLabelColor
    divider.layer?.backgroundColor = (toolbarColor(snapshot.theme["divider"]) ?? .separatorColor).cgColor
    insertion.backgroundColor = (toolbarColor(snapshot.theme["accent"]) ?? .controlAccentColor).cgColor
    needsLayout = true
    layoutSubtreeIfNeeded()
  }

  private func updateItems(_ count: Int) {
    guard let snapshot else { return }
    while items.count > count {
      let button = items.removeLast()
      navigation.prepareToHide(button)
      button.removeFromSuperview()
    }
    for (index, item) in snapshot.items.prefix(count).enumerated() {
      let button: BookmarksBarButton
      if index < items.count {
        button = items[index]
      } else {
        button = BookmarksBarButton()
        items.append(button)
        addSubview(button, positioned: .below, relativeTo: overflow)
      }
      button.controlId = item.id
      button.controlKind = item.kind == .folder ? .folder : .link
      button.configure(title: item.displayTitle, symbol: item.kind == .folder ? "folder" : "globe", folder: item.kind == .folder, theme: snapshot.theme)
      button.setAccessibilityLabel(item.title.isEmpty && item.kind == .url ? item.url.flatMap { URL(string: $0)?.host } ?? item.displayTitle : item.title)
      button.toolTip = item.kind == .url ? [item.title, item.url ?? ""].filter { !$0.isEmpty }.joined(separator: "\n") : item.title
      button.setFavicon(item.kind == .url ? item : nil, profileId: snapshot.profileId, dark: snapshot.dark, favicons: favicons)
      button.onPress = { [weak self, weak button] flags, middle in
        guard let self else { return }
        if item.kind == .folder {
          self.showMenu(trigger: "folder", id: item.id, anchor: button)
          return
        }
        self.emit("press", ["id": item.id, "metaKey": flags.contains(.command), "shiftKey": flags.contains(.shift), "altKey": flags.contains(.option), "ctrlKey": flags.contains(.control), "middle": middle])
      }
      button.onOpenMenu = { [weak self, weak button] in
        self?.showMenu(trigger: "folder", id: item.id, anchor: button, selectFirst: true)
      }
      button.onContext = { [weak self, weak button] in self?.showMenu(trigger: "item", id: item.id, anchor: button) }
      button.onPointerDown = { [weak self] in self?.beginDrag(id: item.id, at: $0) }
      button.onPointerDrag = { [weak self] in self?.moveDrag(to: $0) }
      button.onPointerUp = { [weak self] in self?.endDrag(at: $0) ?? false }
    }
    itemsNeedUpdate = false
  }

  public override func setFrameSize(_ newSize: NSSize) {
    if newSize != frame.size { cancelDrag(); clearLinkDrop() }
    super.setFrameSize(newSize)
    needsLayout = true
  }

  public override func layout() {
    super.layout()
    guard let snapshot else { return }
    navigation.captureFocus()
    let recoveryWidth = recoveryMessage == nil ? 0 : min(bounds.width, recoveryButton.measuredWidth + 8)
    var widths = Array(repeating: CGFloat.zero, count: snapshot.items.count)
    var measured: CGFloat = 0
    for index in snapshot.items.indices {
      let item = snapshot.items[index]
      widths[index] = BookmarksBarButton.width(forTitle: item.displayTitle, iconSize: item.kind == .folder ? 16 : 14)
      measured += widths[index]
      if measured > max(0, bounds.width) { break }
    }
    let layout = BookmarksBarLayout(itemWidths: widths, width: max(0, bounds.width - recoveryWidth), hasOther: snapshot.hasOther && snapshot.otherId != nil)
    if let drag, layout.visible.first(where: { $0.index == drag.index })?.frame != drag.frame { cancelDrag() }
    if itemsNeedUpdate || items.count != layout.visible.count { updateItems(layout.visible.count) }
    placements = layout.visible
    for placement in layout.visible {
      let offset = drag.flatMap { $0.active && $0.index == placement.index ? $0.offsetX : nil } ?? 0
      items[placement.index].frame = placement.frame.offsetBy(dx: offset, dy: 0)
      items[placement.index].isHidden = false
    }
    overflowIds = layout.overflowIndexes.map { snapshot.items[$0].id }
    place(overflow, layout.overflowFrame)
    place(other, layout.otherFrame.map { CGRect(x: $0.minX, y: $0.minY, width: min($0.width, other.measuredWidth), height: $0.height) })
    place(divider, layout.dividerFrame)
    let empty = snapshot.items.isEmpty
    let hideImport = !empty || snapshot.hideBookmarksBarImport
    if hideImport { navigation.prepareToHide(importButton) }
    importButton.isHidden = hideImport
    importButton.frame = CGRect(x: 8, y: 3, width: min(importButton.measuredWidth, layout.contentFrame.width), height: 24)
    hint.isHidden = !empty || !snapshot.hideBookmarksBarImport
    let height = hint.fittingSize.height
    hint.frame = CGRect(x: 12, y: (30 - height) / 2, width: max(0, layout.contentFrame.width - 4), height: height)
    recoveryButton.isHidden = recoveryMessage == nil
    recoveryButton.frame = CGRect(x: max(0, bounds.width - recoveryWidth), y: 3, width: max(0, recoveryWidth - 8), height: 24)
    navigation.update(layout.visible.map { items[$0.index] } + [importButton, overflow, other, recoveryButton])
    setAccessibilityChildren(navigation.controls)
    setAccessibilityHelp(recoveryMessage ?? (hint.isHidden ? nil : hint.stringValue))
  }

  public override func rightMouseDown(with event: NSEvent) {
    guard isHitBy(event) else { return super.rightMouseDown(with: event) }
    showMenu(trigger: "blank")
  }

  public override func mouseDown(with event: NSEvent) {
    guard event.modifierFlags.contains(.control), isHitBy(event) else { return super.mouseDown(with: event) }
    showMenu(trigger: "blank")
  }

  public override func viewWillMove(toWindow newWindow: NSWindow?) {
    if newWindow !== window { cancelDrag(); tabDropZone.clear(); TabDragSession.unregister(tabDropZone); navigation.detach() }
    super.viewWillMove(toWindow: newWindow)
  }

  public override func cancelOperation(_ sender: Any?) {
    cancelDrag()
    tabDropZone.clear()
    if let focused = window?.firstResponder as? BookmarksBarButton, focused.isDescendant(of: self) { navigation.leaveBar() }
  }

  public override func viewDidMoveToWindow() {
    super.viewDidMoveToWindow()
    registerTabDrops()
    needsLayout = true
  }

  private func registerTabDrops() {
    tabDropZone.clear()
    TabDragSession.unregister(tabDropZone)
    if window != nil, !windowId.isEmpty { TabDragSession.register(tabDropZone, windowId: windowId, priority: .bookmarks) }
  }

  public override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
    draggingUpdated(sender)
  }

  public override func draggingUpdated(_ sender: NSDraggingInfo) -> NSDragOperation {
    let links = BookmarksBarLinkDrop.links(sender.draggingPasteboard)
    let point = convert(sender.draggingLocation, from: nil)
    return showLinkDrop(at: point, links: links) ? .copy : []
  }

  public override func draggingExited(_ sender: NSDraggingInfo?) { clearLinkDrop() }

  public override func prepareForDragOperation(_ sender: NSDraggingInfo) -> Bool {
    draggingUpdated(sender) == .copy
  }

  public override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
    let links = BookmarksBarLinkDrop.links(sender.draggingPasteboard)
    guard showLinkDrop(at: convert(sender.draggingLocation, from: nil), links: links) else { return false }
    return performLinkDrop(links)
  }

  public override func concludeDragOperation(_ sender: NSDraggingInfo?) { clearLinkDrop() }

  func showLinkDrop(at point: CGPoint, links: [BookmarksBarDroppedLink]) -> Bool {
    clearLinkDrop()
    guard drag == nil, !links.isEmpty, !isHiddenOrHasHiddenAncestor, bounds.contains(point), let snapshot else { return false }
    layoutSubtreeIfNeeded()
    let folderId = !other.isHidden && other.frame.contains(point) ? snapshot.otherId : nil
    guard let destination = BookmarksBarLinkDrop.destination(snapshot: snapshot, visible: placements, x: point.x, folderId: folderId) else { return false }
    linkDrop = destination
    if let x = destination.insertionX {
      CATransaction.begin()
      CATransaction.setDisableActions(true)
      insertion.frame = CGRect(x: max(8, min(x, bounds.width - 10)), y: 6, width: 2, height: 18)
      insertion.isHidden = false
      CATransaction.commit()
    } else if destination.parentId == snapshot.otherId {
      other.highlighted = true
    } else if let index = snapshot.items.firstIndex(where: { $0.id == destination.parentId }), items.indices.contains(index) {
      items[index].highlighted = true
    }
    return true
  }

  func clearLinkDrop() {
    guard linkDrop != nil else { return }
    linkDrop = nil
    for item in items { item.highlighted = false }
    other.highlighted = false
    insertion.isHidden = true
  }

  func performLinkDrop(_ links: [BookmarksBarDroppedLink]) -> Bool {
    defer { clearLinkDrop() }
    guard let destination = linkDrop, !links.isEmpty else { return false }
    var payload = destination.json
    payload["items"] = links.map(\.json)
    emit("dropLinks", payload)
    return true
  }

  private func showMenu(trigger: String, id: String? = nil, anchor: NSView? = nil, selectFirst: Bool = false) {
    guard let snapshot else { return }
    layoutSubtreeIfNeeded()
    let model = BookmarksBarMenu(snapshot: snapshot, overflowIds: overflowIds)
    let rows = model.items(trigger: trigger, id: id)
    guard !rows.isEmpty else { return }
    #if DEBUG
    openedMenuItems = rows.map(\.json)
    openedMenu = ["trigger": trigger, "id": id as Any? ?? NSNull(), "items": openedMenuItems, "highlightedId": (selectFirst ? rows.first { $0.enabled && !$0.separator }?.choiceId : nil) as Any? ?? NSNull()]
    if simulatingKey { return }
    #endif
    let point = anchor.map { convert(CGPoint(x: $0.bounds.minX, y: $0.bounds.maxY), from: $0) }
      ?? window.map { convert($0.convertPoint(fromScreen: NSEvent.mouseLocation), from: nil) }
    BookmarksBarMenuPresenter.show(rows, in: self, at: point, selectFirst: selectFirst) { [weak self] choiceId in
      guard let choice = model.choice(trigger: trigger, id: id, choiceId: choiceId) else { return }
      self?.choose(choice, model: model) { string in
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(string, forType: .string)
      }
    }
  }

  private func choose(_ choice: BookmarksBarMenu.Choice, model: BookmarksBarMenu, copy: (String) -> Void) {
    guard snapshot?.profileId == model.snapshot.profileId else { return }
    if choice.action == "copy" {
      guard let id = choice.id, let string = model.find(id)?.cleanUrl else { return }
      copy(string)
      return
    }
    var payload: [String: Any] = ["action": choice.action]
    if let id = choice.id { payload["id"] = id }
    emit("menuChoice", payload)
  }

  private func beginDrag(id: String, at point: CGPoint) {
    cancelDrag()
    guard let index = snapshot?.items.firstIndex(where: { $0.id == id }),
      let placement = placements.first(where: { $0.index == index }) else { return }
    drag = Drag(id: id, index: index, down: point, frame: placement.frame)
  }

  private func moveDrag(to point: CGPoint) {
    guard var drag, let snapshot, items.indices.contains(drag.index) else { return }
    let dx = point.x - drag.down.x
    guard drag.active || abs(dx) > 4 else { return }
    if !drag.active {
      drag.active = true
      if let window { dragWatch = BookmarksBarDragWatch(view: self, window: window) }
    }
    drag.target = BookmarksBarDropTarget.resolve(id: drag.id, items: snapshot.items, visible: placements, deltaX: dx, pointerX: point.x, sidebarEdge: snapshot.sidebarEdge)
    drag.offsetX = drag.target == .sidebar ? 8 - drag.frame.minX : dx
    self.drag = drag
    for item in items { item.highlighted = false }
    let button = items[drag.index]
    button.dragging = true
    button.alphaValue = 0.85
    button.layer?.zPosition = 10
    button.frame = drag.frame.offsetBy(dx: drag.offsetX, dy: 0)
    insertion.isHidden = true
    switch drag.target {
    case .reorder(_, let x):
      CATransaction.begin()
      CATransaction.setDisableActions(true)
      insertion.frame = CGRect(x: max(8, min(x, bounds.width - 10)), y: 6, width: 2, height: 18)
      insertion.isHidden = false
      CATransaction.commit()
    case .folder(let id):
      if let index = snapshot.items.firstIndex(where: { $0.id == id }), items.indices.contains(index) { items[index].highlighted = true }
    case .sidebar:
      button.highlighted = true
    case nil: break
    }
  }

  private func endDrag(at point: CGPoint) -> Bool {
    guard let starting = drag else { return false }
    if starting.active { moveDrag(to: point) }
    let final = drag
    cancelDrag()
    guard let final, final.active else { return false }
    switch final.target {
    case .reorder(let index, _): emit("move", ["id": final.id, "index": index])
    case .folder(let id): emit("move", ["id": final.id, "into": id])
    case .sidebar: emit("folderToSidebar", ["id": final.id])
    case nil: break
    }
    return true
  }

  private func cancelDrag() {
    dragWatch?.stop()
    dragWatch = nil
    if let drag, items.indices.contains(drag.index) {
      let button = items[drag.index]
      button.frame = drag.frame
      button.dragging = false
      button.alphaValue = 1
      button.layer?.zPosition = 0
      button.cancelPress()
    }
    for item in items { item.highlighted = false }
    insertion.isHidden = true
    drag = nil
  }

  public func benchmarkMenu(trigger: String, id: String?) -> [String: Any] {
    layoutSubtreeIfNeeded()
    guard let snapshot else { return [:] }
    let started = CFAbsoluteTimeGetCurrent()
    let rows = BookmarksBarMenu(snapshot: snapshot, overflowIds: overflowIds).items(trigger: trigger, id: id)
    let menu = BookmarksBarMenuPresenter.make(rows) { _ in }
    return ["elapsedMs": (CFAbsoluteTimeGetCurrent() - started) * 1000, "items": menu.items.count]
  }

  public func benchmarkLayout() -> [String: Any] {
    layoutSubtreeIfNeeded()
    return ["items": snapshot?.items.count ?? 0, "firstId": snapshot?.items.first?.id as Any? ?? NSNull(), "firstTitle": snapshot?.items.first?.title as Any? ?? NSNull(), "overflowCount": overflowIds.count, "overflowShown": !overflow.isHidden, "visible": placements.count]
  }

  #if DEBUG
  public func devDrop(x: CGFloat, folderId: String?, payload: String) -> [String: Any] {
    layoutSubtreeIfNeeded()
    let links = BookmarksBarLinkDrop.devLinks(payload, resolve: resolveTab)
    let rejected: [String: Any] = ["accepted": false, "parentId": NSNull(), "index": NSNull(), "items": []]
    var point = CGPoint(x: x, y: bounds.midY)
    if let folderId {
      if folderId == snapshot?.otherId, !other.isHidden {
        point = CGPoint(x: other.frame.midX, y: other.frame.midY)
      } else {
        guard let index = snapshot?.items.firstIndex(where: { $0.id == folderId && $0.kind == .folder }),
          items.indices.contains(index), !items[index].isHidden else { return rejected }
        point = CGPoint(x: items[index].frame.midX, y: items[index].frame.midY)
      }
    }
    guard x.isFinite, showLinkDrop(at: point, links: links), let destination = linkDrop else { return rejected }
    var result = destination.json
    result["items"] = links.map(\.json)
    result["accepted"] = performLinkDrop(links)
    return result
  }

  public func devKey(key: String, id: String?, flags: NSEvent.ModifierFlags, fullKeyboardAccess: Bool) -> [String: Any] {
    layoutSubtreeIfNeeded()
    simulatingKey = true
    defer { simulatingKey = false }
    openedMenu = nil
    openedMenuItems = []
    var result = navigation.devKey(key: key, id: id, flags: flags, fullKeyboardAccess: fullKeyboardAccess)
    if let openedMenu { result["menu"] = openedMenu }
    return result
  }

  public func devAccessibility() -> [String: Any] {
    layoutSubtreeIfNeeded()
    let actions: [(NSAccessibility.Action, Selector)] = [(.press, #selector(accessibilityPerformPress)), (.showMenu, #selector(accessibilityPerformShowMenu))]
    let children: [[String: Any]] = navigation.controls.map { button in
      ["id": button.controlId, "role": button.accessibilityRole()?.rawValue as Any? ?? NSNull(),
       "subrole": button.accessibilitySubrole()?.rawValue as Any? ?? NSNull(),
       "roleDescription": button.accessibilityRoleDescription() as Any? ?? NSNull(),
       "label": button.accessibilityLabel() ?? "", "help": button.accessibilityHelp() ?? "",
       "actions": actions.filter { button.isAccessibilitySelectorAllowed($0.1) }.map { $0.0.rawValue }]
    }
    return ["role": accessibilityRole()?.rawValue ?? "", "label": accessibilityLabel() ?? "", "help": accessibilityHelp() ?? "", "children": children]
  }

  public func devMenu(trigger: String, id: String?) -> [[String: Any]] {
    layoutSubtreeIfNeeded()
    if trigger == "open" { return openedMenuItems }
    guard let snapshot else { return [] }
    return BookmarksBarMenu(snapshot: snapshot, overflowIds: overflowIds).items(trigger: trigger, id: id).map(\.json)
  }

  public func devChoose(trigger: String, id: String?, choiceId: String) -> [String: Any] {
    layoutSubtreeIfNeeded()
    guard let snapshot else { return ["accepted": false] }
    let model = BookmarksBarMenu(snapshot: snapshot, overflowIds: overflowIds)
    guard let choice = model.choice(trigger: trigger, id: id, choiceId: choiceId) else { return ["accepted": false] }
    var result: [String: Any] = ["accepted": true]
    choose(choice, model: model) { result["copyText"] = $0 }
    return result
  }

  public func devLayout() -> [String: Any] {
    layoutSubtreeIfNeeded()
    let frame = convert(bounds, to: nil)
    let height = window?.contentView?.superview?.bounds.height ?? 0
    let visible: [[String: Any]] = placements.compactMap { placement in
      guard let snapshot, snapshot.items.indices.contains(placement.index) else { return nil }
      let frame = items[placement.index].frame
      return ["id": snapshot.items[placement.index].id, "frame": ["x": frame.minX, "y": frame.minY, "width": frame.width, "height": frame.height]]
    }
    return ["frame": ["x": frame.minX, "y": height - frame.maxY, "width": frame.width, "height": frame.height], "contentOffsetY": height - (window?.contentView?.bounds.height ?? 0), "visible": visible, "overflowIds": overflowIds, "overflowShown": !overflow.isHidden, "otherShown": !other.isHidden, "importShown": !importButton.isHidden, "hintShown": !hint.isHidden]
  }

  public func devInput(action: String, id: String?, flags: NSEvent.ModifierFlags, x: CGFloat?) -> Bool {
    layoutSubtreeIfNeeded()
    let button = id.flatMap { id in snapshot?.items.firstIndex(where: { $0.id == id }) }.flatMap { index in items.indices.contains(index) && !items[index].isHidden ? items[index] : nil }
    switch action {
    case "press":
      guard let button else { return false }
      let point = convert(CGPoint(x: button.frame.midX, y: button.frame.midY), to: nil)
      button.beginPress(at: point, flags: flags)
      button.endPress(at: point, flags: flags, inside: true)
    case "overflowPress":
      guard !overflow.isHidden else { return false }
      press(overflow, flags: flags)
    case "otherPress":
      guard !other.isHidden else { return false }
      press(other, flags: flags)
    case "importPress":
      guard !importButton.isHidden else { return false }
      press(importButton, flags: flags)
    case "importContextMenu":
      guard !importButton.isHidden else { return false }
      importButton.onContext()
    case "contextMenu":
      if id != nil {
        guard let button else { return false }
        button.onContext()
      } else {
        showMenu(trigger: "blank")
      }
    case "drag", "cancelDrag":
      guard let button, let x, x.isFinite else { return false }
      let down = convert(CGPoint(x: button.frame.midX, y: button.frame.midY), to: nil)
      let end = convert(CGPoint(x: x, y: button.frame.midY), to: nil)
      button.beginPress(at: down, flags: [])
      button.dragPress(to: end)
      if action == "cancelDrag" { cancelOperation(nil) }
      button.endPress(at: end, flags: [], inside: false)
    default: return false
    }
    return true
  }

  private func press(_ button: BookmarksBarButton, flags: NSEvent.ModifierFlags) {
    let point = convert(CGPoint(x: button.frame.midX, y: button.frame.midY), to: nil)
    button.beginPress(at: point, flags: flags)
    button.endPress(at: point, flags: flags, inside: true)
  }
  #endif

  private func place(_ view: NSView, _ frame: CGRect?) {
    if frame == nil, let button = view as? BookmarksBarButton { navigation.prepareToHide(button) }
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
