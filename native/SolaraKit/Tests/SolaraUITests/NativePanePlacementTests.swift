import AppKit
import SolaraModel
import Testing
@testable import SolaraUI

@MainActor
@Suite(.serialized)
struct NativePanePlacementTests {
  @Test func slotPublicationWaitsForTheCompleteInstallation() {
    let slots = TabSlots()
    let a = NSView(), b = NSView()
    var seen: [Set<TabSlotKey>] = []
    let observer = NotificationCenter.default.addObserver(forName: TabSlots.changed, object: slots, queue: nil) { _ in
      MainActor.assumeIsolated { seen.append(slots.keys) }
    }
    defer { NotificationCenter.default.removeObserver(observer) }
    slots.performBatch {
      slots.set(.pane("w", "a"), container: a)
      slots.performBatch { slots.set(.pane("w", "b"), container: b) }
      #expect(seen.isEmpty)
    }
    #expect(seen == [Set([.pane("w", "a"), .pane("w", "b")])])
  }

  @Test func placementValidityRejectsOldRevisionsGenerationsGeometryAndSlots() throws {
    var state = try fixture()
    state.splits = Table()
    let view = SplitPanesView(windowId: "pane-placement")
    defer { view.stop() }
    let first = try snapshot(state, width: 1000)
    view.install(first, state: state)
    let revision = first.input.storeRevision
    let generation = first.input.windowGeneration
    #expect(view.placementIsCurrent(revision: revision, generation: generation))
    #expect(!view.placementIsCurrent(revision: revision + 1, generation: generation))
    #expect(!view.placementIsCurrent(revision: revision, generation: generation + 1))
    let page = try #require(view.container("a"))
    let frame = page.frame
    page.frame.size.width -= 1
    #expect(!view.placementIsCurrent(revision: revision, generation: generation))
    page.frame = frame
    let replacement = NSView()
    TabSlots.shared.set(.pane("pane-placement", "a"), container: replacement)
    #expect(!view.placementIsCurrent(revision: revision, generation: generation))
    view.install(first, state: state)
    #expect(TabSlots.shared.container(for: .pane("pane-placement", "a")) === page)
    #expect(view.placementIsCurrent(revision: revision, generation: generation))
    TabSlots.shared.remove(.card("pane-placement"), container: page)
    #expect(!view.placementIsCurrent(revision: revision, generation: generation))
    view.install(first, state: state)
    #expect(view.placementIsCurrent(revision: revision, generation: generation))
    view.needsLayout = true
    #expect(!view.placementIsCurrent(revision: revision, generation: generation))
    view.install(first, state: state)
    #expect(view.placementIsCurrent(revision: revision, generation: generation))
    view.stop()
    #expect(!view.placementIsCurrent(revision: revision, generation: generation))
  }

  @Test func replacementGenerationOwnsSlotsAfterTheOldOwnerStops() throws {
    var state = try fixture()
    state.splits = Table()
    let old = SplitPanesView(windowId: "pane-placement")
    let replacement = SplitPanesView(windowId: "pane-placement")
    defer { old.stop(); replacement.stop() }
    let first = try snapshot(state, width: 1000)
    old.install(first, state: state)
    let input = try #require(WindowLayoutInput(state: state, windowId: "pane-placement",
      windowGeneration: first.input.windowGeneration + 1, storeRevision: first.input.storeRevision + 1,
      bounds: CGRect(x: 0, y: 0, width: 850, height: 600)))
    replacement.install(.of(input, generation: 1), state: state)
    #expect(!old.placementIsCurrent(revision: first.input.storeRevision, generation: first.input.windowGeneration))
    #expect(replacement.placementIsCurrent(revision: input.storeRevision, generation: input.windowGeneration))
    #expect(!replacement.placementIsCurrent(revision: first.input.storeRevision, generation: first.input.windowGeneration))
    let page = try #require(replacement.container("a"))
    old.stop()
    #expect(TabSlots.shared.container(for: .card("pane-placement")) === page)
    #expect(TabSlots.shared.container(for: .pane("pane-placement", "a")) === page)
    #expect(replacement.placementIsCurrent(revision: input.storeRevision, generation: input.windowGeneration))
  }

  #if DEBUG || SOLARA_PROBES
  @Test func unchangedPlacementCanBeReusedAndInvalidatedByASiblingFrameJob() throws {
    var state = try fixture()
    state.splits = Table()
    let view = SplitPanesView(windowId: "pane-placement")
    defer { view.stop() }
    let first = try snapshot(state, width: 1000)
    view.install(first, state: state)
    let page = try #require(view.container("a"))
    let passes = view.placementLayoutPasses
    #expect(view.placementIsCurrent(revision: first.input.storeRevision, generation: first.input.windowGeneration))
    FrameUpdates.flush()
    #expect(view.placementLayoutPasses == passes)
    let sibling = NSView()
    FrameUpdates.schedule(sibling) {
      TabSlots.shared.remove(.pane("pane-placement", "a"), container: page)
    }
    FrameUpdates.flush()
    #expect(!view.placementIsCurrent(revision: first.input.storeRevision, generation: first.input.windowGeneration))
    view.install(first, state: state)
    #expect(view.placementIsCurrent(revision: first.input.storeRevision, generation: first.input.windowGeneration))
    #expect(view.placementLayoutPasses == passes)
  }
  #endif

  @Test func switchingSinglePanesKeepsTheCardAndOutgoingPageAttached() throws {
    var state = try fixture()
    state.splits = Table()
    let view = SplitPanesView(windowId: "pane-placement")
    let window = NSWindow(contentRect: CGRect(x: 0, y: 0, width: 1000, height: 700), styleMask: [.borderless], backing: .buffered, defer: true)
    window.isReleasedWhenClosed = false
    window.contentView = view
    defer { view.stop(); window.close() }
    view.setToolbars(["a": singletonToolbar("a"), "b": singletonToolbar("b")])
    view.install(try snapshot(state, width: 1000), state: state)
    let container = try #require(view.container("a"))
    let page = PlacementWindowTrackingView()
    container.addSubview(page)
    page.windowChanges = 0
    state.windows["pane-placement"]?.activeTabIds["p"] = "b"
    let next = try snapshot(state, width: 1000)
    view.install(next, state: state)
    #expect(view.container("a") == nil)
    #expect(view.container("b") === container)
    #expect(TabSlots.shared.container(for: .card("pane-placement")) === container)
    #expect(TabSlots.shared.container(for: .pane("pane-placement", "a")) == nil)
    #expect(TabSlots.shared.container(for: .pane("pane-placement", "b")) === container)
    #expect(page.superview === container && page.window === window)
    #expect(page.windowChanges == 0)
    let expected = try #require(next.pageViewports["b"])
    #expect(container.bounds.size == expected.size)
  }

  @Test func reusedSinglePaneToolbarReportsOnlyTheIncomingTab() throws {
    var state = try fixture()
    state.splits = Table()
    let view = SplitPanesView(windowId: "pane-placement")
    defer { view.stop() }
    view.setToolbars(["a": singletonToolbar("a"), "b": singletonToolbar("b")])
    view.install(try snapshot(state, width: 1000), state: state)
    let oldToolbar = try #require(view.toolbar("a"))
    var releases = 0
    var releasedTabs: [String] = []
    view.onToolbarClick = { tabId, _ in releasedTabs.append(tabId) }
    oldToolbar.onHiddenOrDetached = {
      releases += 1
      oldToolbar.onClick(ToolbarClick(id: "urlEdit", kind: .blur))
    }
    state.windows["pane-placement"]?.activeTabIds["p"] = "b"
    view.install(try snapshot(state, width: 1000), state: state)
    let toolbar = try #require(view.toolbar("b"))
    #expect(toolbar === oldToolbar)
    #expect(toolbar.state?.tabId == "b")
    let current = try snapshot(state, width: 1000)
    let expected = try #require(current.toolbars["b"])
    let leaf = try #require(view.container("b")?.superview)
    #expect(toolbar.superview === leaf)
    #expect(toolbar.frame == expected.offsetBy(dx: -current.frames.card.minX - leaf.frame.minX, dy: -current.frames.card.minY - leaf.frame.minY))
    #expect(releases == 1)
    #expect(releasedTabs == ["a"])
    var clicks: [String] = [], anchors: [String] = [], geometry: [String] = []
    view.onToolbarClick = { tabId, _ in clicks.append(tabId) }
    view.onToolbarAnchors = { tabId, _ in anchors.append(tabId) }
    view.onToolbarGeometryChange = { geometry.append($0) }
    toolbar.onClick(ToolbarClick(id: "url", kind: .press))
    toolbar.onAnchors([:])
    toolbar.onLayoutAnchorsChange()
    toolbar.onHiddenOrDetached()
    #expect(clicks == ["b"] && anchors == ["b"] && geometry == ["b"])
    #expect(releases == 1)
  }

  @Test(arguments: [false, true])
  func singlePaneReuseDoesNotCarryAnEditorsRequestToTheIncomingTab(incomingEditing: Bool) throws {
    var state = try fixture()
    state.splits = Table()
    let view = SplitPanesView(windowId: "pane-placement")
    defer { view.stop() }
    func editingToolbar(_ tabId: String) -> String {
      singletonToolbar(tabId).replacingOccurrences(of: #""url":null"#,
        with: #""url":{"developer":{"text":"\#(tabId)","editing":true,"request":1},"host":"","restTrail":"","hoverTrail":"","hoverButtons":[],"trailing":[],"pinned":false}"#)
    }
    view.setToolbars(["a": editingToolbar("a"), "b": incomingEditing ? editingToolbar("b") : singletonToolbar("b")])
    view.install(try snapshot(state, width: 1000), state: state)
    let container = try #require(view.container("a"))
    let oldEditor = try #require(view.toolbar("a")?.urlEditView as? NSTextField)
    #expect(oldEditor.stringValue == "a")
    state.windows["pane-placement"]?.activeTabIds["p"] = "b"
    view.install(try snapshot(state, width: 1000), state: state)
    #expect(view.container("b") === container)
    if incomingEditing {
      let editor = try #require(view.toolbar("b")?.urlEditView as? NSTextField)
      #expect(editor !== oldEditor)
      #expect(editor.stringValue == "b")
    } else {
      #expect(view.toolbar("b")?.urlEditView == nil)
    }
  }

  @Test(arguments: [false, true])
  func singlePaneReuseKeepsToolbarModelsInTheirOwnLifetime(incomingToolbar: Bool) throws {
    var state = try fixture()
    state.splits = Table()
    let view = SplitPanesView(windowId: "pane-placement")
    defer { view.stop() }
    view.setToolbars(incomingToolbar ? ["a": singletonToolbar("a"), "b": singletonToolbar("b")] : ["a": singletonToolbar("a")])
    view.install(try snapshot(state, width: 1000), state: state)
    let old = try #require(view.container("a"))
    let toolbar = try #require(view.toolbar("a"))
    state.windows["pane-placement"]?.activeTabIds["p"] = "b"
    view.install(try snapshot(state, width: 1000), state: state)
    #expect(view.container("b") === old)
    #expect(view.toolbar("b") === toolbar)
    #expect(view.toolbar("b")?.state?.tabId == (incomingToolbar ? "b" : nil))
    #expect(view.toolbar("b")?.isHidden == !incomingToolbar)
  }

  @Test func reusedToolbarDropsOutgoingURLSecurityAndCallbacks() throws {
    var state = try fixture()
    state.splits = Table()
    let view = SplitPanesView(windowId: "pane-placement")
    defer { view.stop() }
    let outgoing = singletonToolbar("a").replacingOccurrences(of: #""url":null"#,
      with: #""url":{"host":"old.test","restTrail":"/old","hoverTrail":"/old","insecure":"http","hoverButtons":[],"trailing":[],"pinned":false}"#)
    let incoming = singletonToolbar("b").replacingOccurrences(of: #""url":null"#,
      with: #""url":{"host":"new.test","restTrail":"/new","hoverTrail":"/new","hoverButtons":[],"trailing":[],"pinned":false}"#)
    view.setToolbars(["a": outgoing, "b": incoming])
    view.install(try snapshot(state, width: 1000), state: state)
    let toolbar = try #require(view.toolbar("a"))
    let oldField = try #require(ToolbarWebKitPillTests.fieldIn(toolbar))
    var clicks: [String] = []
    view.onToolbarClick = { tabId, _ in clicks.append(tabId) }
    state.windows["pane-placement"]?.activeTabIds["p"] = "b"
    view.install(try snapshot(state, width: 1000), state: state)
    #expect(view.toolbar("b") === toolbar)
    let field = try #require(ToolbarWebKitPillTests.fieldIn(toolbar))
    #expect(field.sample()["text"] as? String == "new.test/new")
    #expect(field.sample()["lock"] == nil)
    #expect(toolbar.urlEditView == nil)
    oldField.onClick(ToolbarClick(id: "url", kind: .press))
    #expect(clicks.isEmpty)
    field.onClick(ToolbarClick(id: "url", kind: .press))
    #expect(clicks == ["b"])
  }

  #if DEBUG
  @Test(arguments: [false, true]) func markedDeveloperEditCannotCrossTabRetirement(incomingEditing: Bool) throws {
    _ = NSApplication.shared
    var state = try fixture()
    state.splits = Table()
    let view = SplitPanesView(windowId: "pane-placement")
    let window = NSWindow(contentRect: CGRect(x: 0, y: 0, width: 1000, height: 700), styleMask: [.borderless], backing: .buffered, defer: true)
    window.isReleasedWhenClosed = false
    window.contentView = view
    var pending: [@MainActor () -> Void] = []
    ToolbarUrlFieldView.enqueueEditFocus = { pending.append($0) }
    defer { ToolbarUrlFieldView.enqueueEditFocus = nil; view.stop(); window.close() }
    func toolbar(_ id: String, editing: Bool, request: Int = 1) -> String {
      singletonToolbar(id).replacingOccurrences(of: #""url":null"#,
        with: #""url":{"developer":{"text":"\#(id)","editing":\#(editing),"request":\#(request)},"host":"","restTrail":"","hoverTrail":"","hoverButtons":[],"trailing":[],"pinned":false}"#)
    }
    view.setToolbars(["a": toolbar("a", editing: true), "b": toolbar("b", editing: incomingEditing, request: 2)])
    view.install(try snapshot(state, width: 1000), state: state)
    let outgoing = try #require(view.toolbar("a"))
    let a = try #require(outgoing.urlEditView as? DeveloperUrlField)
    try #require(pending.count == 1)
    pending.removeFirst()()
    let aText = try #require(a.currentEditor() as? NSTextView)
    let aURL = try #require(ToolbarWebKitPillTests.fieldIn(outgoing))
    var renewed = try #require(outgoing.state?.url)
    renewed.developer?.request = 2
    aURL.update(renewed, palette: try #require(outgoing.state?.palette))
    try #require(pending.count == 1)
    let staleFocus = pending.removeFirst()
    aText.setMarkedText("にほん", selectedRange: NSRange(location: 3, length: 0), replacementRange: NSRange(location: 0, length: (aText.string as NSString).length))
    try #require(aText.hasMarkedText())
    let draft = aText.string
    let oldFinish = a.onFinish
    let oldFocus = a.onFocused
    let oldClick = aURL.onClick
    var events: [(String, ToolbarClick)] = []
    view.onToolbarClick = { events.append(($0, $1)) }
    state.windows["pane-placement"]?.activeTabIds["p"] = "b"
    view.install(try snapshot(state, width: 1000), state: state)
    let incoming = try #require(view.toolbar("b"))
    #expect(incoming !== outgoing)
    #expect(events.count == 1)
    #expect(events.first?.0 == "a")
    #expect(events.first?.1.kind == .blur)
    #expect(events.first?.1.text == draft)
    #expect(a.currentEditor() == nil)
    let afterRetirement = window.firstResponder
    staleFocus()
    #expect(window.firstResponder === afterRetirement)
    #expect(a.currentEditor() == nil)
    if !incomingEditing {
      #expect(incoming.urlEditView == nil)
      #expect(pending.isEmpty)
      view.setToolbars(["b": toolbar("b", editing: true, request: 2)])
    }
    let b = try #require(incoming.urlEditView as? DeveloperUrlField)
    #expect(b !== a)
    try #require(pending.count == 1)
    pending.removeFirst()()
    let bText = try #require(b.currentEditor() as? NSTextView)
    #expect(window.firstResponder === bText)
    #expect(bText.string == "b")
    #expect(!bText.hasMarkedText())
    let beforeOldCallbacks = events.count
    staleFocus()
    oldFinish(.submit, "A stale submit")
    oldFocus()
    oldClick(ToolbarClick(id: "urlEdit", kind: .submit, text: "A stale click"))
    a.onFinish(.submit, "A retired submit")
    a.onFocused()
    a.controlTextDidEndEditing(Notification(name: NSControl.textDidEndEditingNotification, object: a))
    #expect(events.count == beforeOldCallbacks)
    #expect(window.firstResponder === bText)
    #expect(!bText.hasMarkedText())
    bText.insertText("B input", replacementRange: NSRange(location: 0, length: (bText.string as NSString).length))
    b.validateEditing()
    #expect(bText.string == "B input")
    #expect(!bText.hasMarkedText())
    #expect(b.control(b, textView: bText, doCommandBy: #selector(NSResponder.insertNewline(_:))))
    let submits = events.filter { $0.1.kind == .submit }
    #expect(submits.count == 1)
    #expect(submits.first?.0 == "b")
    #expect(submits.first?.1.text == "B input")
    #expect(events.filter { $0.0 == "a" }.count == 1)
  }

  @Test func editingFallbackRetiresTextToOutgoingTabAndRejectsQueuedFocus() throws {
    var state = try fixture()
    state.splits = Table()
    let view = SplitPanesView(windowId: "pane-placement")
    let window = NSWindow(contentRect: CGRect(x: 0, y: 0, width: 1000, height: 700), styleMask: [.borderless], backing: .buffered, defer: true)
    window.isReleasedWhenClosed = false
    window.contentView = view
    var pending: [@MainActor () -> Void] = []
    ToolbarUrlFieldView.enqueueEditFocus = { pending.append($0) }
    defer { ToolbarUrlFieldView.enqueueEditFocus = nil; view.stop(); window.close() }
    func editingToolbar(_ tabId: String) -> String {
      singletonToolbar(tabId).replacingOccurrences(of: #""url":null"#,
        with: #""url":{"developer":{"text":"\#(tabId)","editing":true,"request":1},"host":"","restTrail":"","hoverTrail":"","hoverButtons":[],"trailing":[],"pinned":false}"#)
    }
    view.setToolbars(["a": editingToolbar("a"), "b": editingToolbar("b")])
    view.install(try snapshot(state, width: 1000), state: state)
    let toolbar = try #require(view.toolbar("a"))
    let oldEditor = try #require(toolbar.urlEditView as? DeveloperUrlField)
    #expect(pending.count == 1)
    pending.removeFirst()()
    #expect(window.makeFirstResponder(oldEditor))
    let fieldEditor = try #require(oldEditor.currentEditor() as? NSTextView)
    fieldEditor.string = "unsent old draft"
    fieldEditor.selectedRange = NSRange(location: 3, length: 4)
    var events: [(String, ToolbarClick)] = []
    view.onToolbarClick = { events.append(($0, $1)) }
    oldEditor.finished = false
    let oldField = try #require(ToolbarWebKitPillTests.fieldIn(toolbar))
    var renewed = try #require(toolbar.state?.url)
    renewed.developer?.request = 2
    oldField.update(renewed, palette: try #require(toolbar.state?.palette))
    let staleFocus = try #require(pending.first)
    fieldEditor.string = "unsent old draft"
    fieldEditor.selectedRange = NSRange(location: 3, length: 4)
    pending = []
    state.windows["pane-placement"]?.activeTabIds["p"] = "b"
    view.install(try snapshot(state, width: 1000), state: state)
    let incoming = try #require(view.toolbar("b"))
    #expect(incoming !== toolbar)
    #expect(events.contains { $0.0 == "a" && $0.1.kind == .blur && $0.1.text == "unsent old draft" })
    let nextEditor = try #require(incoming.urlEditView as? DeveloperUrlField)
    #expect(pending.count == 1)
    pending.removeFirst()()
    let nextResponder = window.firstResponder
    staleFocus()
    oldEditor.onFinish(.submit, "stale")
    #expect(window.firstResponder === nextResponder)
    #expect(nextEditor.stringValue == "b")
    #expect(!events.contains { $0.0 == "b" && $0.1.text == "stale" })
  }
  #endif

  @Test func singlePaneReusePreservesThePoolsOutgoingDrawHold() throws {
    var state = try fixture()
    state.splits = Table()
    let view = SplitPanesView(windowId: "pane-placement")
    let window = NSWindow(contentRect: CGRect(x: 0, y: 0, width: 1000, height: 700), styleMask: [.borderless], backing: .buffered, defer: true)
    window.isReleasedWhenClosed = false
    window.contentView = view
    var pending: [@MainActor () -> Void] = []
    let pool = TabViewPool(make: { _, _ in HoldingPage() }, schedule: { pending.append($0) }, after: { _, _ in })
    defer { pool.update([]); pool.reconcile(); view.stop(); window.close() }
    func reconcile() {
      let work = pending
      pending = []
      work.forEach { $0() }
    }
    func updatePool() {
      let selected = state.windows["pane-placement"]?.activeTabIds["p"]
      pool.update(["a", "b"].map { TabViewWanted(tabId: $0, windowId: "pane-placement", shown: $0 == selected ? .card : .none, profileId: "p") })
      reconcile()
    }
    view.install(try snapshot(state, width: 1000), state: state)
    updatePool()
    let a = try #require(pool.page("a") as? HoldingPage)
    let b = try #require(pool.page("b") as? HoldingPage)
    a.draw()
    state.windows["pane-placement"]?.activeTabIds["p"] = "b"
    view.install(try snapshot(state, width: 1000), state: state)
    updatePool()
    #expect(pool.heldTabIds == ["a"])
    #expect(a.view.superview === view.container("b"))
    #expect(b.view.superview === view.container("b"))
    b.draw()
    #expect(pool.heldTabIds.isEmpty)
    #expect(a.view.superview === pool.keeper)
  }

  @Test func fullscreenAndSplitTransitionsKeepDistinctPaneIdentities() throws {
    var state = try fixture()
    state.splits = Table()
    let view = SplitPanesView(windowId: "pane-placement")
    defer { view.stop() }
    view.install(try snapshot(state, width: 1000), state: state)
    let original = try #require(view.container("a"))
    state.windows["pane-placement"]?.activeTabIds["p"] = "b"
    let fullscreen = try #require(WindowLayoutInput(state: state, windowId: "pane-placement", bounds: CGRect(x: 0, y: 0, width: 1000, height: 700),
      pageFacts: ["b": WindowLayoutPageFacts(registration: "b", fullscreen: true)]))
    view.install(.of(fullscreen, generation: 2), state: state)
    #expect(view.container("b") !== original)
    state.splits = try fixture().splits
    state.windows["pane-placement"]?.activeTabIds["p"] = "a"
    view.install(try snapshot(state, width: 1000), state: state)
    #expect(view.container("a") !== view.container("b"))
    let splitA = try #require(view.container("a"))
    state.windows["pane-placement"]?.activeTabIds["p"] = "c"
    view.install(try snapshot(state, width: 1000), state: state)
    #expect(view.container("a") == nil && view.container("b") == nil)
    #expect(view.container("c") !== splitA)
  }

  @Test func placementAndOldOwnerTeardownPreserveTheReplacementRegistration() throws {
    let state = try fixture()
    let first = SplitPanesView(windowId: "pane-placement")
    let second = SplitPanesView(windowId: "pane-placement")
    let snapshot = try snapshot(state, width: 1000)
    first.install(snapshot, state: state)
    let old = try #require(first.container("a"))
    let page = NSView()
    old.addSubview(page)
    let resized = try self.snapshot(state, width: 1200)
    first.install(resized, state: state)
    #expect(first.container("a") === old)
    #expect(old.subviews.first === page)
    second.install(resized, state: state)
    let replacement = try #require(second.container("a"))
    #expect(replacement !== old)
    first.stop()
    #expect(TabSlots.shared.container(for: .pane("pane-placement", "a")) === replacement)
    #expect(page.superview === old)
    second.stop()
    #expect(TabSlots.shared.container(for: .pane("pane-placement", "a")) == nil)
  }

  @Test func layoutMovesThePooledPageWithoutReplacingItsRegistrationOrSession() throws {
    let registry = PageRegistry()
    let view = SplitPanesView(windowId: "pane-placement")
    var state = try fixture()
    let pool = TabViewPool(make: { id, _ in RegisteredPlacementPage(id, registry: registry) }, schedule: { $0() })
    defer { view.stop(); pool.update([]) }
    view.install(try snapshot(state, width: 1000), state: state)
    pool.update([TabViewWanted(tabId: "a", windowId: "pane-placement", shown: .pane, identity: "chromium|p")])
    let first = try #require(pool.page("a") as? RegisteredPlacementPage)
    let registration = first.registration
    let descriptor = try #require(registry.descriptor(registration))
    for width: CGFloat in [800, 1000, 1200] {
      state.splits["s"]?.orientation = width == 1000 ? "vertical" : "horizontal"
      view.install(try snapshot(state, width: width), state: state)
      pool.reconcile()
      #expect(pool.page("a") === first)
      #expect(registry.descriptor(registration)?.registration == descriptor.registration)
      #expect(registry.descriptor(registration)?.sessionGeneration == descriptor.sessionGeneration)
      #expect(first.view.superview === view.container("a"))
      #expect(first.focused == 0)
    }
  }

  #if SOLARA_PROBES
  @Test func ownerStopEndsToastAndNoticeAnimationLinks() {
    let before = NativeWorkCounters.snapshot()["activeAnimationLinks"] as? Int ?? 0
    let chrome = SplitChromeView(windowId: "pane-placement")
    chrome.setToast(SplitToastSpec(id: 1, title: "Pane limit"))
    chrome.setNotice(SplitToastSpec(id: 2, title: "Session unavailable"))
    #expect((NativeWorkCounters.snapshot()["activeAnimationLinks"] as? Int ?? 0) > before)
    chrome.stop()
    #expect(NativeWorkCounters.snapshot()["activeAnimationLinks"] as? Int == before)
  }
  #endif

  @Test func dividerResizePreservesTheMinimumWhenThereIsEnoughRoom() {
    let sizes = ShellGeometry.resize([0.5, 0.5], 0, delta: -1000, total: 1007)
    #expect(abs(sizes[0] * 1000 - ShellMetrics.minPane) < 0.001)
    #expect(abs(sizes.reduce(0, +) - 1) < 0.001)
  }

  @Test func installedShareBandShowsWithoutALegacyHeightFeed() throws {
    let state = try fixture()
    let overlays = PaneOverlaysView(windowId: "pane-placement")
    let clip = NSView()
    defer { overlays.stop() }
    overlays.setBand(clip, tabId: "a")
    overlays.install(try snapshot(state, width: 1000), state: state)
    #expect(clip.frame.height == 38)
    #expect(!clip.isHidden)
  }

  @Test func poolPreparationInstallsPendingNativeSlotsBeforePlanningPlacement() throws {
    let state = try fixture()
    let view = SplitPanesView(windowId: "pane-placement")
    let overlays = PaneOverlaysView(windowId: "pane-placement")
    let token = NSObject()
    let value = try snapshot(state, width: 1000)
    let oldCard = NSView()
    TabSlots.shared.set(.card("pane-placement"), container: oldCard)
    var pending: [@MainActor () -> Void] = []
    let pool = TabViewPool(make: { id, _ in RegisteredPlacementPage(id, registry: PageRegistry()) }, schedule: { pending.append($0) })
    pool.preparePlacement = { FrameUpdates.flush() }
    defer { view.stop(); overlays.stop(); pool.update([]); pool.reconcile(); TabSlots.shared.remove(.card("pane-placement"), container: oldCard) }
    FrameUpdates.schedule(token) {
      TabSlots.shared.performBatch {
        PaneOverlays.shared.performBatch {
          view.install(value, state: state)
          overlays.install(value, state: state)
        }
      }
    }
    pool.update([TabViewWanted(tabId: "a", windowId: "pane-placement", shown: .pane)])
    let work = pending
    pending = []
    work.forEach { $0() }
    #expect(pool.page("a")?.view.superview === view.container("a"))
    #expect(pool.page("a")?.view.superview !== oldCard)
    #expect(overlays.container("a", layer: .native)?.bounds.size == view.container("a")?.bounds.size)
  }

  @Test func aStoppedPaneOwnerRejectsQueuedInstallation() throws {
    let state = try fixture()
    let view = SplitPanesView(windowId: "pane-placement")
    let overlays = PaneOverlaysView(windowId: "pane-placement")
    let value = try snapshot(state, width: 1000)
    view.install(value, state: state)
    overlays.install(value, state: state)
    view.stop()
    overlays.stop()
    view.install(value, state: state)
    overlays.install(value, state: state)
    #expect(view.container("a") == nil)
    #expect(overlays.container("a", layer: .native) == nil)
    #expect(TabSlots.shared.container(for: .pane("pane-placement", "a")) == nil)
  }

  @Test func aBorrowerSurfaceRejectsThePreviousHolderAfterHandoff() {
    #expect(FrozenPageIdentity.admits(tabId: "copy", copyId: "copy", holder: "source", copyHolder: "source"))
    #expect(!FrozenPageIdentity.admits(tabId: "copy", copyId: "copy", holder: nil, copyHolder: nil))
    #expect(FrozenPageIdentity.admits(tabId: "source", copyId: "copy", holder: nil, copyHolder: "source"))
    #expect(FrozenPageIdentity.admits(tabId: "source", copyId: "copy", holder: "copy", copyHolder: nil))
    #expect(!FrozenPageIdentity.admits(tabId: "source", copyId: "copy", holder: nil, copyHolder: "other"))
  }

  @Test func geometryInstallsPageAndOverlayFromTheSameSnapshot() throws {
    var state = try fixture()
    let panes = SplitPanesView(windowId: "pane-placement")
    let overlays = PaneOverlaysView(windowId: "pane-placement")
    defer { panes.stop(); overlays.stop() }
    for orientation in ["horizontal", "vertical"] {
      for ids in [["a", "b"], ["a", "b", "c"]] {
        for stack in [false, true] where !stack || ids.count == 3 {
          state.splits["s"] = SplitView(id: "s", windowId: "pane-placement", tabIds: ids, orientation: orientation,
            sizes: stack ? [0.4, 0.6] : Array(repeating: 1 / Double(ids.count), count: ids.count),
            stack: stack ? SplitStack(index: 1, sizes: [0.4, 0.6]) : nil)
          for size in [CGSize(width: 8, height: 700), CGSize(width: 1000, height: 8), CGSize(width: 1000, height: 700)] {
            let value = try snapshot(state, width: size.width, height: size.height)
            panes.install(value, state: state)
            overlays.install(value, state: state)
            for id in ids {
              if value.pages[id] == nil {
                #expect(panes.container(id) == nil)
                continue
              }
              let page = try #require(panes.container(id))
              let overlay = try #require(overlays.container(id, layer: .native))
              let expected = try #require(value.pages[id]).offsetBy(dx: -value.frames.card.minX, dy: -value.frames.card.minY)
              #expect(page.convert(page.bounds, to: panes) == expected)
              #expect(overlay.convert(overlay.bounds, to: overlays) == expected)
              #expect(page.bounds.width >= 0 && page.bounds.height >= 0)
            }
          }
        }
      }
    }
  }

  @Test func installedRightSidebarCaptionKeepsPageAndOverlayTogether() throws {
    var state = try fixture()
    state.windows["pane-placement"]?.sidebarPosition = "right"
    state.settings["addressBar"] = "sidebar"
    let panes = SplitPanesView(windowId: "pane-placement")
    let overlays = PaneOverlaysView(windowId: "pane-placement")
    defer { panes.stop(); overlays.stop() }
    for orientation in ["horizontal", "vertical"] {
      state.splits["s"]?.orientation = orientation
      let input = try #require(WindowLayoutInput(state: state, windowId: "pane-placement",
        bounds: CGRect(x: 0, y: 0, width: 1000, height: 700),
        pageFacts: ["a": WindowLayoutPageFacts(registration: "a", top: 0, band: 38),
          "b": WindowLayoutPageFacts(registration: "b", top: 0)]))
      let value = WindowLayoutSnapshot.of(input, generation: 1)
      panes.install(value, state: state)
      overlays.install(value, state: state)
      let firstPane = try #require(value.panes["a"])
      let firstPage = try #require(value.pages["a"])
      #expect(firstPage.minY == firstPane.minY + 38)
      for id in ["a", "b"] {
        let page = try #require(panes.container(id))
        let overlay = try #require(overlays.container(id, layer: .native))
        let expected = try #require(value.pages[id]).offsetBy(dx: -value.frames.card.minX, dy: -value.frames.card.minY)
        #expect(page.convert(page.bounds, to: panes) == expected)
        #expect(overlay.convert(overlay.bounds, to: overlays) == expected)
      }
    }
  }

  #if DEBUG || SOLARA_PROBES
  @Test func splitSelectionDoesNotRelayoutUnchangedPanes() throws {
    var state = try fixture()
    let view = SplitPanesView(windowId: "pane-placement")
    defer { view.stop() }
    view.setToolbars(["a": singletonToolbar("a"), "b": singletonToolbar("b")])
    view.install(try snapshot(state, width: 1000), state: state)
    let a = try #require(view.container("a")?.superview as? SplitLeafView)
    let b = try #require(view.container("b")?.superview as? SplitLeafView)
    let passes = [a.placementLayoutPasses, b.placementLayoutPasses]
    let frames = [a.page.frame, b.page.frame]
    state.windows["pane-placement"]?.activeTabIds["p"] = "b"
    view.install(try snapshot(state, width: 1000), state: state)
    #expect(a.placementLayoutPasses == passes[0])
    #expect(b.placementLayoutPasses == passes[1])
    #expect([a.page.frame, b.page.frame] == frames)
  }

  @Test func changingOneSplitInsetLaysOutOnlyItsPane() throws {
    let state = try fixture()
    let view = SplitPanesView(windowId: "pane-placement")
    defer { view.stop() }
    view.install(try snapshot(state, width: 1000), state: state)
    let a = try #require(view.container("a")?.superview as? SplitLeafView)
    let b = try #require(view.container("b")?.superview as? SplitLeafView)
    let passes = [a.placementLayoutPasses, b.placementLayoutPasses]
    let unchanged = b.page.frame
    let input = try #require(WindowLayoutInput(state: state, windowId: "pane-placement", bounds: CGRect(x: 0, y: 0, width: 1000, height: 700),
      pageFacts: ["a": WindowLayoutPageFacts(registration: "a-registered", top: 91, band: 38), "b": WindowLayoutPageFacts(registration: "b-registered", top: 41)]))
    let value = WindowLayoutSnapshot.of(input, generation: 2)
    view.install(value, state: state)
    #expect(a.placementLayoutPasses == passes[0] + 1)
    #expect(b.placementLayoutPasses == passes[1])
    #expect(b.page.frame == unchanged)
    let expected = try #require(value.pageViewports["a"])
    #expect(a.page.convert(a.page.bounds, to: view) == expected.offsetBy(dx: -value.frames.card.minX, dy: -value.frames.card.minY))
  }
  #endif

  private func fixture() throws -> BrowserState {
    try BrowserState(stateJSON: JSONValue.parse(#"{"windows":{"pane-placement":{"id":"pane-placement","profileId":"p","sidebarOpen":true,"tabIds":["a","b","c"],"activeTabIds":{"p":"a"}}},"tabs":{"a":{"id":"a","windowId":"pane-placement","profileId":"p"},"b":{"id":"b","windowId":"pane-placement","profileId":"p"},"c":{"id":"c","windowId":"pane-placement","profileId":"p"}},"splits":{"s":{"id":"s","windowId":"pane-placement","tabIds":["a","b"],"orientation":"horizontal","sizes":[0.5,0.5]}}}"#).object ?? [:])
  }

  private func singletonToolbar(_ tabId: String) -> String {
    ##"{"tabId":"\##(tabId)","height":41,"bare":false,"focused":true,"accent":"#3478F6","palette":{"text":"#000000","secondary":"#00000080","icon":"#000000D4","iconDisabled":"#0000006E","hover":"#0000000D","pressed":"#0000001A","pill":"#0000000A","divider":"#0000001A"},"geometry":{"back":12,"forward":40,"reload":68,"urlLeft":100,"urlRight":8},"left":[],"url":null,"right":[],"rightInset":8,"hairline":false}"##
  }

  private func snapshot(_ state: BrowserState, width: CGFloat, height: CGFloat = 700) throws -> WindowLayoutSnapshot {
    let input = try #require(WindowLayoutInput(state: state, windowId: "pane-placement", bounds: CGRect(x: 0, y: 0, width: width, height: height),
      pageFacts: ["a": WindowLayoutPageFacts(registration: "a-registered", top: 71, band: 38), "b": WindowLayoutPageFacts(registration: "b-registered", top: 41)]))
    return .of(input, generation: 1)
  }
}

@MainActor
private final class PlacementWindowTrackingView: NSView {
  var windowChanges = 0
  override func viewWillMove(toWindow newWindow: NSWindow?) {
    windowChanges += 1
    super.viewWillMove(toWindow: newWindow)
  }
}

@MainActor
private final class RegisteredPlacementPage: TabPoolPage {
  let view = NSView()
  let registration: PageRegistration
  let registry: PageRegistry
  var focused = 0
  init(_ id: String, registry: PageRegistry) {
    self.registry = registry
    registration = registry.register(tabID: id, engine: .chromium, host: .pooled, sessionGeneration: "session-" + id) { _, finish in finish(.success(.null)) }
  }
  func setShown(_ shown: Bool) {}
  func focus() { focused += 1 }
  func retire() { registry.retire(registration); view.removeFromSuperview() }
}

@MainActor
@Suite(.serialized)
struct PaneGuestLifetimeTests {
  @Test func retirementWaitsForThePortalsMatchingRelease() {
    let guest = PaneGuestLifetime()
    var ends = 0
    guest.onEnd = { ends += 1 }
    guest.setShown(true)
    let generation = guest.generation
    guest.announce(generation: generation)
    guest.retire()
    #expect(ends == 0)
    guest.release(generation: generation + 1)
    #expect(ends == 0)
    guest.release(generation: generation)
    guest.release(generation: generation)
    #expect(ends == 1)
  }

  @Test func anOldPortalCleanupCannotReleaseTheReshownTarget() {
    let guest = PaneGuestLifetime()
    var ends = 0
    guest.onEnd = { ends += 1 }
    guest.setShown(true)
    let old = guest.generation
    guest.setShown(false)
    guest.setShown(true)
    let current = guest.generation
    guest.announce(generation: current)
    #expect(current > old)
    guest.release(generation: old)
    guest.retire()
    #expect(ends == 0)
    guest.release(generation: current)
    #expect(ends == 1)
    guest.setShown(true)
    #expect(!guest.shown)
  }

  @Test func reshowingWithoutPublicationKeepsTheOldPortalsReleaseObligation() {
    let guest = PaneGuestLifetime()
    var ends = 0
    guest.onEnd = { ends += 1 }
    guest.setShown(true)
    let old = guest.generation
    guest.announce(generation: old)
    guest.setShown(false)
    guest.setShown(true)
    guest.retire()
    #expect(ends == 0)
    guest.release(generation: old)
    #expect(ends == 1)
  }

  @Test func aNewLeaseRearmsAnEpochAfterThePreviousOwnersRelease() {
    let guest = PaneGuestLifetime()
    var announcements = PaneGuestAnnouncements()
    var ends = 0
    guest.onEnd = { ends += 1 }
    guest.setShown(true)
    let generation = guest.generation
    let oldLease = announcements.acquire(generation)
    guest.announce(generation: generation)
    if announcements.reject(generation, ticket: oldLease) { guest.release(generation: generation) }
    let newLease = announcements.acquire(generation)
    guest.announce(generation: generation)
    if announcements.reject(generation, ticket: oldLease) { guest.release(generation: generation) }
    guest.retire()
    #expect(ends == 0)
    if announcements.reject(generation, ticket: newLease) { guest.release(generation: generation) }
    #expect(ends == 1)
  }

  @Test func eachAnnouncedEpochNeedsItsOwnReleaseBeforeTheRootCanEnd() {
    let guest = PaneGuestLifetime()
    var ends = 0
    guest.onEnd = { ends += 1 }
    guest.setShown(true)
    let old = guest.generation
    guest.announce(generation: old)
    guest.setShown(false)
    guest.setShown(true)
    let current = guest.generation
    guest.announce(generation: current)
    guest.retire()
    guest.release(generation: current)
    #expect(ends == 0)
    guest.release(generation: old)
    #expect(ends == 1)
  }

  @Test func aNeverAnnouncedTargetRetiresWithoutAPortalRelease() {
    let guest = PaneGuestLifetime()
    var ends = 0
    guest.onEnd = { ends += 1 }
    guest.setShown(true)
    guest.retire()
    #expect(ends == 1)
  }

  @Test func aReleasedHiddenTargetEndsWithoutWaitingOnHostStop() {
    let guest = PaneGuestLifetime()
    var ends = 0
    guest.onEnd = { ends += 1 }
    guest.setShown(true)
    guest.setShown(false)
    guest.release(generation: guest.generation)
    #expect(ends == 0)
    guest.retire()
    guest.retire()
    #expect(ends == 1)
  }
}

@Suite struct PaneGuestAnnouncementTests {
  @Test func acquisitionsRemainUniqueAcrossEpochsAndLateReceiptsAreInert() {
    var announcements = PaneGuestAnnouncements()
    let first = announcements.acquire(5)
    let second = announcements.acquire(5)
    let other = announcements.acquire(6)
    #expect(first != second && second != other && first != other)
    let firstReleasedLast = announcements.reject(5, ticket: first)
    let duplicateReleasedLast = announcements.reject(5, ticket: first)
    let wrongEpochReleasedLast = announcements.reject(5, ticket: other)
    #expect(!firstReleasedLast)
    #expect(!duplicateReleasedLast)
    #expect(!wrongEpochReleasedLast)
    #expect(announcements.contains(5))
    let secondReleasedLast = announcements.reject(5, ticket: second)
    #expect(secondReleasedLast)
    #expect(announcements.contains(6))
    let otherReleasedLast = announcements.reject(6, ticket: other)
    #expect(otherReleasedLast)
  }

  @Test func aRejectedOlderPublicationPreservesTheAcceptedOne() {
    var announcements = PaneGuestAnnouncements()
    announcements.announce(7, ticket: 1)
    announcements.announce(7, ticket: 2)
    let olderRejected = announcements.reject(7, ticket: 1)
    #expect(!olderRejected)
    #expect(announcements.contains(7))
    let newerRejected = announcements.reject(7, ticket: 2)
    #expect(newerRejected)
    #expect(!announcements.contains(7))
  }

  @Test func aSynchronousReadCannotBeErasedByAFailedPublication() {
    var announcements = PaneGuestAnnouncements()
    announcements.announce(8, ticket: 0)
    announcements.announce(8, ticket: 4)
    let publicationRejected = announcements.reject(8, ticket: 4)
    #expect(!publicationRejected)
    #expect(announcements.contains(8))
    announcements.remove(8)
    #expect(!announcements.contains(8))
  }
}
