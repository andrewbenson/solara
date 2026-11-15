import AppKit
import SolaraModel
import Testing
@testable import SolaraUI

@MainActor
@Suite(.serialized)
struct SidebarAuxiliaryViewportTests {
  private func count(_ name: String, in view: NSView) -> Int {
    (String(describing: type(of: view)) == name ? 1 : 0) + view.subviews.reduce(0) { $0 + count(name, in: $1) }
  }

  @Test func groupCardRealizesOnlyItsVisibleRowsAndKeyboardReachesTheEnd() {
    let card = SidebarGroupCardView(favicons: SidebarFavicons())
    card.virtualizesRows = true
    let rows = (0..<2000).map { index in SidebarGroupCardState.Row(id: "t\(index)", title: "Tab \(index)", url: "https://fixture.test/\(index)", usedAt: 0, favicon: nil, icon: nil, profileId: "p") }
    card.set(SidebarGroupCardState(groupId: "g", rows: rows, anchor: [0, 0, 190, 34], windowHeight: 800, dark: true, theme: [:]))
    card.layoutSubtreeIfNeeded()
    #expect(count("GroupCardRowView", in: card) > 0)
    #expect(count("GroupCardRowView", in: card) < 10)
    var chosen: String?
    card.onEvent = { if case .choose(let id) = $0 { chosen = id } }
    let field = NSTextField(), text = NSTextView()
    for _ in 0..<2000 { _ = card.control(field, textView: text, doCommandBy: #selector(NSResponder.moveDown(_:))) }
    _ = card.control(field, textView: text, doCommandBy: #selector(NSResponder.insertNewline(_:)))
    #expect(chosen == "t1999")
    #expect(count("GroupCardRowView", in: card) > 0)
    #expect(count("GroupCardRowView", in: card) < 10)
  }

  @Test func groupCardHandsFocusToSearchBeforeRebindingAScrolledRow() throws {
    let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 800, height: 600), styleMask: [.borderless], backing: .buffered, defer: true)
    window.isReleasedWhenClosed = false
    defer { window.close() }
    let root = try #require(window.contentView)
    let card = SidebarGroupCardView(favicons: SidebarFavicons())
    card.virtualizesRows = true
    root.addSubview(card)
    let rows = (0..<200).map { SidebarGroupCardState.Row(id: "t\($0)", title: "Tab \($0)", url: "", usedAt: 0, favicon: nil, icon: nil, profileId: "p") }
    card.set(SidebarGroupCardState(groupId: "g", rows: rows, anchor: [0, 0, 190, 34], windowHeight: 600, dark: true, theme: [:]))
    card.layoutSubtreeIfNeeded()
    let search = try #require(card.subviews.compactMap { $0 as? NSTextField }.first { $0.isEditable })
    let pointer = try #require(NSEvent.mouseEvent(with: .mouseMoved, location: .zero, modifierFlags: [], timestamp: 0, windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: 0, pressure: 0))
    card.mouseEntered(with: pointer)
    let editor = try #require(search.currentEditor() as? NSTextView)
    #expect(card.control(search, textView: editor, doCommandBy: #selector(NSResponder.insertTab(_:))))
    let outgoing = try #require(window.firstResponder as? GroupCardRowView)
    #expect(outgoing.accessibilityLabel() == "Tab 0")
    let scroll = try #require(descendants(NSScrollView.self, in: card).first)
    scroll.contentView.scroll(to: NSPoint(x: 0, y: 2000))
    NotificationCenter.default.post(name: NSView.boundsDidChangeNotification, object: scroll.contentView)
    #expect((window.firstResponder as? NSTextView)?.delegate === search)
    #expect(window.firstResponder !== outgoing)
    #expect(count("GroupCardRowView", in: card) < 10)
    let backtab = try #require(search.currentEditor() as? NSTextView)
    #expect(card.control(search, textView: backtab, doCommandBy: #selector(NSResponder.insertBacktab(_:))))
    let last = try #require(window.firstResponder as? GroupCardRowView)
    #expect(last.accessibilityLabel() == "Tab 199")
    var chosen: String?
    card.onEvent = { if case .choose(let id) = $0 { chosen = id } }
    let enter = try #require(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0, windowNumber: window.windowNumber, context: nil, characters: "\r", charactersIgnoringModifiers: "\r", isARepeat: false, keyCode: 36))
    last.keyDown(with: enter)
    #expect(chosen == "t199")
    card.live = false
  }

  @Test func folderPanelClipsMembersWithoutDroppingLogicalInsertionFrames() {
    let panel = SidebarFolderPanelView(frame: CGRect(x: 0, y: 0, width: 190, height: 400))
    panel.virtualizesRows = true
    let members = (0..<2000).map { FolderPanelMember(tabId: "t\($0)", title: "Tab \($0)", active: false) }
    panel.update(label: "Folder", members: members, colors: FolderPanelColors(dark: true, tokens: [:]), anchor: CGRect(x: 6, y: 0, width: 178, height: 41), width: 178)
    panel.layoutSubtreeIfNeeded()
    #expect(count("FolderPanelRow", in: panel) > 0)
    #expect(count("FolderPanelRow", in: panel) < 15)
  }

  private func descendants<T: NSView>(_ type: T.Type, in view: NSView) -> [T] {
    (view as? T).map { [$0] } ?? view.subviews.flatMap { descendants(type, in: $0) }
  }

  @Test func groupCardReusesRowsAndKeepsLogicalAccessibilityAfterScrolling() throws {
    let card = SidebarGroupCardView(favicons: SidebarFavicons())
    card.virtualizesRows = true
    let values = (0..<200).map { SidebarGroupCardState.Row(id: "t\($0)", title: "Tab \($0)", url: "", usedAt: 0, favicon: nil, icon: nil, profileId: "p") }
    card.set(SidebarGroupCardState(groupId: "g", rows: values, anchor: [0, 0, 190, 34], windowHeight: 800, dark: true, theme: [:]))
    card.layoutSubtreeIfNeeded()
    let first = Set(descendants(GroupCardRowView.self, in: card).map(ObjectIdentifier.init))
    let field = NSTextField(), text = NSTextView()
    for _ in 0..<30 { _ = card.control(field, textView: text, doCommandBy: #selector(NSResponder.moveDown(_:))) }
    let later = Set(descendants(GroupCardRowView.self, in: card).map(ObjectIdentifier.init))
    #expect(!first.intersection(later).isEmpty)
    let elements = NSAccessibility.unignoredChildren(from: card.accessibilityChildren() ?? []).compactMap { $0 as? NSAccessibilityElement }
    #expect(elements.count == 200)
    #expect(elements.allSatisfy { $0.isAccessibilityElement() && $0.accessibilityRole() == .button })
    var chosen: String?
    card.onEvent = { if case .choose(let id) = $0 { chosen = id } }
    let last = try #require(elements.last)
    #expect(last.accessibilityLabel() == "Tab 199")
    #expect(last.accessibilityPerformPress())
    #expect(chosen == "t199")
    #expect(count("GroupCardRowView", in: card) > 0)
    #expect(count("GroupCardRowView", in: card) < 10)
    card.isHidden = true
    #expect(count("GroupCardRowView", in: card) == 0)
    #expect(!last.accessibilityPerformPress())
  }

  @Test func folderPanelReportsEveryLogicalMemberAndReusesTheVisibleCells() throws {
    NSApplication.shared.setActivationPolicy(.prohibited)
    let window = NSWindow(contentRect: CGRect(x: 0, y: 0, width: 190, height: 400), styleMask: [.borderless], backing: .buffered, defer: false)
    window.isReleasedWhenClosed = false
    window.alphaValue = 0
    window.level = NSWindow.Level(rawValue: -1_000_000)
    defer { window.close() }
    let panel = SidebarFolderPanelView(frame: CGRect(x: 0, y: 0, width: 190, height: 400))
    panel.virtualizesRows = true
    window.contentView = panel
    var zone: FolderPanelDropZone?
    panel.onDropZone = { zone = $0 }
    panel.update(label: "Folder", members: (0..<200).map { FolderPanelMember(tabId: "t\($0)", title: "Tab \($0)", active: false) }, colors: FolderPanelColors(dark: true, tokens: [:]), anchor: CGRect(x: 6, y: 0, width: 178, height: 41), width: 178)
    panel.layoutSubtreeIfNeeded()
    #expect(zone?.members.count == 200)
    #expect(zone?.members.last?.tabId == "t199")
    #expect((zone?.members.last?.frame.minY ?? 0) > 7000)
    let first = Set(descendants(FolderPanelRow.self, in: panel).map(ObjectIdentifier.init))
    let scroll = try #require(descendants(NSScrollView.self, in: panel).first)
    scroll.contentView.setBoundsOrigin(CGPoint(x: 0, y: 3700))
    NotificationCenter.default.post(name: NSView.boundsDidChangeNotification, object: scroll.contentView)
    let later = Set(descendants(FolderPanelRow.self, in: panel).map(ObjectIdentifier.init))
    #expect(!first.intersection(later).isEmpty)
    #expect(count("FolderPanelRow", in: panel) > 0)
    #expect(count("FolderPanelRow", in: panel) < 15)
    let elements = NSAccessibility.unignoredChildren(from: panel.accessibilityChildren() ?? []).compactMap { $0 as? NSAccessibilityElement }
    #expect(elements.count == 200)
    #expect(elements.allSatisfy { $0.isAccessibilityElement() && $0.accessibilityRole() == .button })
    var opened: String?
    panel.onEvent = { if case .open(let id) = $0 { opened = id } }
    #expect(elements.last?.accessibilityPerformPress() == true)
    #expect(opened == "t199")
  }

  @Test func railPopoverBoundsRowsWhileKeyboardAndAccessibilityReachTheLastItem() throws {
    let state = try SidebarViewportTests.state(2000)
    let context = SidebarContext(state: state, host: SidebarHostState(profileId: "p"), windowId: "w", favicons: SidebarFavicons())
    context.virtualizesRows = true
    let values = (0..<2000).map { index in
      SidebarRailPopoverRow(content: SidebarFolderPeekState.Row(id: "t\(index)", title: "Tab \(index)", url: "", favicon: nil, icon: nil, profileId: "p"), action: .click(tabId: "t\(index)", mods: SidebarClickMods([])), closeAction: nil, menuAction: nil, active: false, unread: false, groupId: nil, directIcon: false)
    }
    let popover = SidebarRailPopover(title: "Tabs", rows: values, context: context)
    defer { popover.close() }
    let content = try #require(popover.popover.contentViewController?.view)
    content.layoutSubtreeIfNeeded()
    #expect(count("SidebarRailPopoverRowView", in: content) > 0)
    #expect(count("SidebarRailPopoverRowView", in: content) < 15)
    var selected: String?
    context.send = { if case .click(let id, _) = $0 { selected = id } }
    let elements = NSAccessibility.unignoredChildren(from: content.accessibilityChildren() ?? []).compactMap { $0 as? NSAccessibilityElement }
    #expect(elements.count == 2000)
    #expect(elements.allSatisfy { $0.isAccessibilityElement() && $0.accessibilityRole() == .button })
    #expect(elements.last?.accessibilityPerformPress() == true)
    #expect(selected == "t1999")
  }

  @Test func legacyAuxiliaryListsKeepTheirEagerRows() {
    let card = SidebarGroupCardView(favicons: SidebarFavicons())
    let values = (0..<20).map { SidebarGroupCardState.Row(id: "t\($0)", title: "Tab \($0)", url: "", usedAt: 0, favicon: nil, icon: nil, profileId: "p") }
    card.set(SidebarGroupCardState(groupId: "g", rows: values, anchor: [0, 0, 190, 34], windowHeight: 800, dark: true, theme: [:]))
    card.layoutSubtreeIfNeeded()
    #expect(count("GroupCardRowView", in: card) == 20)
  }


  @Test func groupCardMouseUpAfterRebindCannotChooseTheNewIdentity() throws {
    let row = GroupCardRowView(frame: CGRect(x: 0, y: 0, width: 200, height: 44))
    let event = try #require(NSEvent.mouseEvent(with: .leftMouseDown, location: CGPoint(x: 10, y: 10), modifierFlags: [], timestamp: 0, windowNumber: 0, context: nil, eventNumber: 0, clickCount: 1, pressure: 1))
    row.mouseDown(with: event)
    row.clearBinding()
    var pressed = false
    row.onPress = { pressed = true }
    row.mouseUp(with: event)
    #expect(!pressed)
  }

  @Test func folderDragTransferSurvivesSourceRecycleWithoutCancellation() throws {
    let row = FolderPanelRow(member: FolderPanelMember(tabId: "source", title: "Source", active: false), icon: NSView())
    row.frame = CGRect(x: 0, y: 0, width: 180, height: 34)
    row.transfersDrag = true
    var phases: [String] = []
    row.onEvent = { if case .drag(let phase, _, _) = $0 { phases.append(phase) } }
    let down = try #require(NSEvent.mouseEvent(with: .leftMouseDown, location: CGPoint(x: 10, y: 10), modifierFlags: [], timestamp: 0, windowNumber: 0, context: nil, eventNumber: 0, clickCount: 1, pressure: 1))
    let move = try #require(NSEvent.mouseEvent(with: .leftMouseDragged, location: CGPoint(x: 30, y: 30), modifierFlags: [], timestamp: 0.1, windowNumber: 0, context: nil, eventNumber: 1, clickCount: 1, pressure: 1))
    row.mouseDown(with: down)
    row.mouseDragged(with: move)
    row.clearBinding()
    #expect(phases == ["begin"])
    var opened = false
    row.set(FolderPanelMember(tabId: "next", title: "Next", active: false), colors: FolderPanelColors(dark: true, tokens: [:]))
    row.onEvent = { if case .open = $0 { opened = true } }
    row.mouseUp(with: move)
    #expect(!opened)
  }


  @Test func ancestorResizeReconcilesAuxiliaryRowsWithoutChangingTheCardSize() {
    let parent = NSView(frame: CGRect(x: 0, y: 0, width: 264, height: 400))
    parent.wantsLayer = true
    parent.layer?.masksToBounds = true
    let card = SidebarGroupCardView(favicons: SidebarFavicons())
    card.virtualizesRows = true
    parent.addSubview(card)
    let values = (0..<200).map { SidebarGroupCardState.Row(id: "t\($0)", title: "Tab \($0)", url: "", usedAt: 0, favicon: nil, icon: nil, profileId: "p") }
    card.set(SidebarGroupCardState(groupId: "g", rows: values, anchor: [0, 0, 190, 34], windowHeight: 800, dark: true, theme: [:]))
    card.layoutSubtreeIfNeeded()
    let initial = count("GroupCardRowView", in: card)
    #expect(initial > 0)
    parent.frame.size.height = 150
    #expect(count("GroupCardRowView", in: card) > 0)
    #expect(count("GroupCardRowView", in: card) < initial)
    parent.frame.size.height = 0
    #expect(count("GroupCardRowView", in: card) == 0)
    parent.frame.size.height = 400
    #expect(count("GroupCardRowView", in: card) == initial)
  }


  #if SOLARA_PROBES
  @Test func auxiliaryWorkCountersMeasureRowsAndReturnToZeroAfterCleanup() throws {
    NativeWorkCounters.reset()
    func counters(_ windowId: String, _ kind: String) -> [String: Any]? {
      (NativeWorkCounters.snapshot()["groups"] as? [[String: Any]])?.first { $0["windowId"] as? String == windowId && $0["profileId"] as? String == "p" && $0["kind"] as? String == kind }
    }
    var railOwner: SidebarRailPopover?
    weak var railWitness: NSView?
    try autoreleasepool {
      let context = SidebarContext(state: try SidebarViewportTests.state(2000), host: SidebarHostState(profileId: "p"), windowId: "aux-counter-rail", favicons: SidebarFavicons())
      context.virtualizesRows = true
      let values = (0..<2000).map { index in
        SidebarRailPopoverRow(content: SidebarFolderPeekState.Row(id: "t\(index)", title: "Tab \(index)", url: "", favicon: nil, icon: nil, profileId: "p"), action: .click(tabId: "t\(index)", mods: SidebarClickMods([])))
      }
      let popover = SidebarRailPopover(title: "Tabs", rows: values, context: context)
      railOwner = popover
      let content = try #require(popover.popover.contentViewController?.view)
      content.layoutSubtreeIfNeeded()
      railWitness = descendants(SidebarRailPopoverRowView.self, in: content).first
      let rail = try #require(counters("aux-counter-rail", "sidebar.railPopover.full"))
      let initial = try #require(rail["created"] as? Int)
      #expect(initial > 0 && initial < 15)
      #expect(rail["live"] as? Int == count("SidebarRailPopoverRowView", in: content))
      let scroll = try #require(descendants(NSScrollView.self, in: content).first)
      for offset in [3700.0, 7400.0, 0.0] {
        scroll.contentView.setBoundsOrigin(CGPoint(x: 0, y: offset))
        NotificationCenter.default.post(name: NSView.boundsDidChangeNotification, object: scroll.contentView)
      }
      let moved = try #require(counters("aux-counter-rail", "sidebar.railPopover.full"))
      #expect((moved["created"] as? Int ?? 2000) < 15)
      #expect((moved["bound"] as? Int ?? 0) > initial)
      #expect((moved["reused"] as? Int ?? 0) > 0)
      #expect((moved["live"] as? Int ?? 2000) < 15)
      popover.close()
      #expect(count("SidebarRailPopoverRowView", in: content) == 0)
    }
    withExtendedLifetime(railOwner) {
      #expect(railWitness == nil)
      #expect(counters("aux-counter-rail", "sidebar.railPopover.full")?["live"] as? Int == 0)
    }

    let card = SidebarGroupCardView(favicons: SidebarFavicons())
    weak var groupWitness: NSView?
    try autoreleasepool {
      card.virtualizesRows = true
      card.probeRowBinding = { NativeWorkCounters.bind($0, windowId: "aux-counter-group", profileId: $1, kind: "sidebar.groupCard.full") }
      let rows = (0..<2000).map { SidebarGroupCardState.Row(id: "t\($0)", title: "Tab \($0)", url: "", usedAt: 0, favicon: nil, icon: nil, profileId: "p") }
      card.set(SidebarGroupCardState(groupId: "g", rows: rows, anchor: [0, 0, 190, 34], windowHeight: 800, dark: true, theme: [:]))
      card.layoutSubtreeIfNeeded()
      groupWitness = descendants(GroupCardRowView.self, in: card).first
      let group = try #require(counters("aux-counter-group", "sidebar.groupCard.full"))
      #expect(group["live"] as? Int == count("GroupCardRowView", in: card))
      #expect((group["created"] as? Int ?? 2000) > 0 && (group["created"] as? Int ?? 2000) < 10)
      card.isHidden = true
      #expect(count("GroupCardRowView", in: card) == 0)
    }
    withExtendedLifetime(card) {
      #expect(groupWitness == nil)
      #expect(counters("aux-counter-group", "sidebar.groupCard.full")?["live"] as? Int == 0)
    }

    let panel = SidebarFolderPanelView(frame: CGRect(x: 0, y: 0, width: 190, height: 400))
    weak var folderWitness: NSView?
    try autoreleasepool {
      panel.virtualizesRows = true
      panel.probeRowBinding = { NativeWorkCounters.bind($0, windowId: "aux-counter-folder", profileId: "p", kind: "sidebar.folderPanel.full") }
      panel.update(label: "Folder", members: (0..<2000).map { FolderPanelMember(tabId: "t\($0)", title: "Tab \($0)", active: false) }, colors: FolderPanelColors(dark: true, tokens: [:]), anchor: CGRect(x: 6, y: 0, width: 178, height: 41), width: 178)
      panel.layoutSubtreeIfNeeded()
      folderWitness = descendants(FolderPanelRow.self, in: panel).first
      let folder = try #require(counters("aux-counter-folder", "sidebar.folderPanel.full"))
      #expect(folder["live"] as? Int == count("FolderPanelRow", in: panel))
      #expect((folder["created"] as? Int ?? 2000) > 0 && (folder["created"] as? Int ?? 2000) < 15)
      panel.isHidden = true
      #expect(count("FolderPanelRow", in: panel) == 0)
    }
    withExtendedLifetime(panel) {
      #expect(folderWitness == nil)
      #expect(counters("aux-counter-folder", "sidebar.folderPanel.full")?["live"] as? Int == 0)
    }
  }

  #endif

}
