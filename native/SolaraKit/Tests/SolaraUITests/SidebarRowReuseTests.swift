import AppKit
import SolaraModel
import Testing
@testable import SolaraUI

#if SOLARA_PROBES

@MainActor
@Suite(.serialized)
struct SidebarRowReuseTests {
  @Test func recycledRowsCannotCarryHoverPressedOpacityOrTransformsIntoANewIdentity() throws {
    let sidebar = try SidebarViewportTests.sidebar(2000)
    let first = try #require(sidebar.views["t:t0"] as? SidebarRowView)
    first.hovered = true
    first.pressed = true
    first.alphaValue = 0.2
    first.layer?.transform = CATransform3DMakeTranslation(0, 40, 0)
    sidebar.scroll.contentView.setBoundsOrigin(CGPoint(x: 0, y: 3400))
    NotificationCenter.default.post(name: NSView.boundsDidChangeNotification, object: sidebar.scroll.contentView)
    #expect(first.item?.key != "t:t0")
    #expect(!first.hovered && !first.pressed && !first.retired)
    #expect(first.alphaValue == 1)
    #expect(CATransform3DIsIdentity(first.layer?.transform ?? CATransform3DIdentity))
    #expect(CATransform3DIsIdentity(first.body.layer?.sublayerTransform ?? CATransform3DIdentity))
  }

  @Test func stableViewportDoesNotReplaceBoundViews() throws {
    let sidebar = try SidebarViewportTests.sidebar(2000)
    let original = sidebar.views
    sidebar.update(state: try SidebarViewportTests.state(2000), host: SidebarHostState(profileId: "p"))
    #expect(original.allSatisfy { sidebar.views[$0.key] === $0.value })
  }
}

@MainActor
@Suite(.serialized)
struct SidebarRecycleEditorTests {
  @Test func scrollingAnEditingRowCommitsTheOldIdentityOnceBeforeReuse() throws {
    let sidebar = try SidebarViewportTests.sidebar(2000)
    let window = NSWindow(contentRect: sidebar.bounds, styleMask: [.borderless], backing: .buffered, defer: false)
    window.isReleasedWhenClosed = false
    window.contentView = sidebar
    var host = SidebarHostState(profileId: "p")
    host.renaming = "tab:t0"
    var renames: [(String, String?)] = []
    sidebar.onAction = { if case .renamed(_, let id, let text) = $0 { renames.append((id, text)) } }
    sidebar.update(state: try SidebarViewportTests.state(2000), host: host)
    sidebar.layoutSubtreeIfNeeded()
    func fields(_ view: NSView) -> [SidebarRenameField] {
      view.subviews.flatMap { child in (child as? SidebarRenameField).map { [$0] } ?? fields(child) }
    }
    let field = try #require(fields(sidebar).first)
    field.begin()
    field.stringValue = "Typed name"
    sidebar.scroll.contentView.setBoundsOrigin(CGPoint(x: 0, y: 3400))
    NotificationCenter.default.post(name: NSView.boundsDidChangeNotification, object: sidebar.scroll.contentView)
    #expect(renames.count == 1)
    #expect(renames.first?.0 == "t0" && renames.first?.1 == "Typed name")
    #expect(field.superview == nil)
    field.finish("late")
    #expect(renames.count == 1)
    sidebar.stop()
    window.contentView = nil
    window.close()
  }
}

@MainActor
@Suite(.serialized)
struct SidebarVirtualDragTests {
  #if SOLARA_PROBES
  @Test func dragProbeTracksTheVisibleTargetAfterTheSourceScrollsAway() throws {
    let sidebar = try SidebarViewportTests.sidebar(2000)
    let window = NSPanel(contentRect: sidebar.bounds, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
    window.isReleasedWhenClosed = false
    window.contentView = sidebar
    defer { sidebar.stop(); window.contentView = nil; window.close() }
    let drag = SidebarDragController.of(sidebar)
    drag.collect()
    let source = try #require(drag.items["t:t0"]?.frame)
    drag.begin("t:t0", CGPoint(x: source.midX, y: source.midY))
    func targetY() throws -> CGFloat {
      let items = try #require(drag.probe()["items"] as? [[String: Any]])
      return try #require(items.first { $0["key"] as? String == "t:t100" }?["y"] as? CGFloat)
    }
    let before = try targetY()
    sidebar.probeScroll(to: 3400)
    #expect(sidebar.views["t:t0"] == nil)
    #expect(abs(try targetY() - before + sidebar.scroll.contentView.bounds.minY) < 0.5)
    drag.end(commit: false)
  }
  #endif

  @Test func dragOrderingKeepsEveryLogicalTabWhileOnlyTheViewportHasCells() throws {
    let sidebar = try SidebarViewportTests.sidebar(2000)
    let window = NSWindow(contentRect: sidebar.bounds, styleMask: [.borderless], backing: .buffered, defer: false)
    window.isReleasedWhenClosed = false
    window.contentView = sidebar
    let drag = SidebarDragController.of(sidebar)
    drag.collect()
    #expect(drag.items.values.filter { $0.kind == .row }.count == 2000)
    #expect(sidebar.views.count < 20)
    #expect(drag.items["t:t1999"]?.frame != nil)
    sidebar.stop()
    window.contentView = nil
    window.close()
  }
}

@MainActor
@Suite(.serialized)
struct SidebarVirtualAccessibilityTests {
  @Test func logicalElementsKeepIdentityAcrossScrollAndMaterializeOffscreenActions() throws {
    let sidebar = try SidebarViewportTests.sidebar(2000)
    var clicked: [String] = []
    sidebar.onAction = { if case .click(let id, _) = $0 { clicked.append(id) } }
    let elements = (sidebar.accessibilityChildren() ?? []).compactMap { $0 as? NSAccessibilityElement }
    #expect(elements.count >= 2000)
    let last = try #require(elements.first { $0.accessibilityLabel() == "Tab 1999" })
    #expect(sidebar.views["t:t1999"] == nil)
    #expect(last.accessibilityPerformPress())
    #expect(clicked == ["t1999"])
    #expect(sidebar.views["t:t1999"] != nil)
    sidebar.scroll.contentView.setBoundsOrigin(.zero)
    NotificationCenter.default.post(name: NSView.boundsDidChangeNotification, object: sidebar.scroll.contentView)
    let again = (sidebar.accessibilityChildren() ?? []).compactMap { $0 as? NSAccessibilityElement }.first { $0.accessibilityLabel() == "Tab 1999" }
    #expect(again === last)
    #expect(last.accessibilityPerformPress())
    #expect(clicked == ["t1999", "t1999"])
  }
}

#if SOLARA_PROBES
@MainActor
@Suite(.serialized)
struct SidebarFaviconBindingTests {
  @Test func anOldSameURLCompletionCannotRunAfterABindLeavesAndReturns() async throws {
    let favicons = SidebarFavicons()
    var continuations: [CheckedContinuation<NSImage?, Never>] = []
    favicons.loader = { _ in await withCheckedContinuation { continuations.append($0) } }
    let icon = TabIconView()
    icon.favicons = favicons
    let palette = SidebarPalette(SidebarHostState(profileId: "p"))
    let spec = TabIconSpec(url: "https://same.test/", profileId: "p")
    icon.set(spec, palette: palette)
    for _ in 0..<50 where continuations.count < 1 { await Task.yield() }
    #expect(continuations.count == 1)
    icon.clearBinding()
    #expect(favicons.pendingInterestCount == 0)
    icon.set(spec, palette: palette)
    for _ in 0..<50 where continuations.count < 2 { await Task.yield() }
    #expect(continuations.count == 2)
    let before = icon.probeRenderCount
    continuations[0].resume(returning: NSImage(size: CGSize(width: 16, height: 16)))
    for _ in 0..<10 { await Task.yield() }
    #expect(icon.probeRenderCount == before)
    #expect(icon.probeURL == spec.url)
    #expect(favicons.pendingInterestCount == 1)
    continuations[1].resume(returning: NSImage(size: CGSize(width: 16, height: 16)))
    for _ in 0..<50 where favicons.pendingInterestCount != 0 { await Task.yield() }
    #expect(favicons.pendingInterestCount == 0)
    #expect(icon.probeRenderCount > before)
  }

  @Test func shrinkingAFolderMosaicCancelsTheRemovedIconsInterest() async throws {
    let favicons = SidebarFavicons()
    var pending: [CheckedContinuation<NSImage?, Never>] = []
    favicons.loader = { _ in await withCheckedContinuation { pending.append($0) } }
    let context = SidebarContext(state: try SidebarViewportTests.state(4), host: SidebarHostState(profileId: "p"), windowId: "w", favicons: favicons)
    let mosaic = FolderMosaicView()
    mosaic.render(members: ["t0", "t1", "t2", "t3"], context: context)
    for _ in 0..<20 { await Task.yield() }
    #expect(favicons.pendingInterestCount == 4)
    mosaic.render(members: ["t0", "t1", "t2"], context: context)
    SidebarRowReuse.reset(mosaic)
    #expect(favicons.pendingInterestCount == 0)
    for continuation in pending { continuation.resume(returning: nil) }
    for _ in 0..<10 { await Task.yield() }
  }

  @Test func scrollingCancelsFaviconInterestsForEveryPooledRow() async throws {
    let favicons = SidebarFavicons()
    var pending: [CheckedContinuation<NSImage?, Never>] = []
    favicons.loader = { _ in await withCheckedContinuation { pending.append($0) } }
    let sidebar = SidebarView(windowId: "w", favicons: favicons, virtualizesRows: true)
    sidebar.frame = CGRect(x: 0, y: 0, width: 190, height: 400)
    sidebar.update(state: try SidebarViewportTests.state(2000), host: SidebarHostState(profileId: "p"))
    for _ in 0..<20 { await Task.yield() }
    #expect(favicons.pendingInterestCount <= sidebar.views.count)
    sidebar.probeScroll(to: 3400)
    for _ in 0..<20 { await Task.yield() }
    #expect(favicons.pendingInterestCount <= sidebar.views.count)
    sidebar.stop()
    #expect(favicons.pendingInterestCount == 0)
    for continuation in pending { continuation.resume(returning: nil) }
    for _ in 0..<20 { await Task.yield() }
    #expect(sidebar.views.isEmpty)
  }
}
#endif

@MainActor
private final class ReuseDragBridge: SidebarDragBridge {
  var beginnings: [[String]] = []
  var endings: [Bool] = []
  var dropped: [[String]] = []
  func dragBegan(windowId: String, tabId: String?, tabIds: [String]) { beginnings.append(tabIds) }
  func dragPicture(windowId: String, size: CGSize, grab: CGPoint) {}
  func dragMoved(windowId: String, x: CGFloat, y: CGFloat) {}
  func dragEnded(windowId: String, commit: Bool, done: @escaping @MainActor (Bool) -> Void) { endings.append(commit); done(false) }
  func drop(windowId: String, ids: [String], drop: JSONValue, sequence: [String]?) { dropped.append(ids) }
  func escapeCapture(_ on: Bool) {}
  func haptic() {}
  func closeFolderPanel(windowId: String) {}
  func changed(windowId: String) {}
}

@MainActor
@Suite(.serialized)
struct SidebarDragBindingTests {
  private func mouse(_ type: NSEvent.EventType, in window: NSWindow, row: NSView) throws -> NSEvent {
    let at = row.convert(CGPoint(x: row.bounds.midX, y: row.bounds.midY), to: nil)
    return try #require(NSEvent.mouseEvent(with: type, location: at, modifierFlags: [], timestamp: 0, windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: 1))
  }

  @Test func recycledSourceKeepsTheFullSelectionPayloadAndCancelRestoresOnlyCurrentBindings() throws {
    let bridge = ReuseDragBridge()
    SidebarDragHub.bridge = bridge
    defer { SidebarDragHub.bridge = nil }
    let sidebar = try SidebarViewportTests.sidebar(2000)
    var host = SidebarHostState(profileId: "p")
    host.selection = ["t0", "t1999"]
    sidebar.update(state: try SidebarViewportTests.state(2000), host: host)
    let window = NSWindow(contentRect: sidebar.bounds, styleMask: [.borderless], backing: .buffered, defer: false)
    window.isReleasedWhenClosed = false
    window.contentView = sidebar
    defer { sidebar.stop(); window.contentView = nil; window.close() }
    let controller = SidebarDragController.of(sidebar)
    controller.collect()
    let source = try #require(controller.items["t:t0"])
    let frame = try #require(source.frame)
    let row = try #require(source.views.first as? SidebarRowView)
    let originalToken = row.bindingToken
    controller.begin("t:t0", CGPoint(x: frame.midX, y: frame.midY))
    #expect(bridge.beginnings == [["t0", "t1999"]])
    #expect(controller.followsPopoverDrag)
    sidebar.probeScroll(to: 3400)
    #expect(controller.active)
    #expect(row.bindingToken != originalToken)
    #expect(source.views.isEmpty)
    #expect(controller.items.values.filter { $0.kind == .row }.count == 2000)
    #expect(controller.marks.sources == ["t:t0", "t:t1999"])
    #expect(sidebar.views.count < 20)
    controller.end(commit: false)
    #expect(!controller.active && !controller.followsPopoverDrag)
    #expect(bridge.endings == [false])
    #expect(sidebar.views.values.allSatisfy { $0.alphaValue == 1 && CATransform3DIsIdentity($0.layer?.transform ?? CATransform3DIdentity) })
  }

  @Test func scrollingAnOversizedTileSectionKeepsEmptyPinnedRowAnchorsInTheDragCoordinateSpace() throws {
    let bridge = ReuseDragBridge()
    SidebarDragHub.bridge = bridge
    defer { SidebarDragHub.bridge = nil }
    for pinnedCount in [3, 30] {
      var state = try SidebarViewportTests.state(120)
      for index in 0..<pinnedCount { state.tabs["t\(index)"]?.pinned = true }
      let sidebar = SidebarView(windowId: "w", virtualizesRows: true)
      sidebar.frame = CGRect(x: 0, y: 0, width: 190, height: 400)
      let window = NSWindow(contentRect: sidebar.bounds, styleMask: [.borderless], backing: .buffered, defer: false)
      window.isReleasedWhenClosed = false
      window.contentView = sidebar
      defer { sidebar.stop(); window.contentView = nil; window.close() }
      var host = SidebarHostState(profileId: "p")
      host.tidy = true
      host.clear = true
      sidebar.update(state: state, host: host)
      sidebar.layoutSubtreeIfNeeded()
      #expect(sidebar.pageLayout.tilesFixed == (pinnedCount == 3))
      #expect(sidebar.pageLayout.items.allSatisfy { $0.section != .pinned })
      sidebar.probeScroll(to: pinnedCount == 30 ? 450 : 100)
      let controller = SidebarDragController.of(sidebar)
      controller.collect()
      let sourceKey = try #require(sidebar.views.keys.first { key in
        guard let row = sidebar.views[key] as? TabRowView else { return false }
        return row.item?.region == .scroll
      })
      let source = try #require(controller.items[sourceKey]?.frame)
      let initialScroll = sidebar.scroll.contentView.bounds.minY
      let fixedTile = try #require(controller.items["t:t0"]?.frame)
      controller.begin(sourceKey, CGPoint(x: source.midX, y: source.midY))
      #expect(controller.active)
      sidebar.probeScroll(to: initialScroll + 70)
      let delta = sidebar.scroll.contentView.bounds.minY - initialScroll
      #expect(delta == 70)
      let anchor = try #require(sidebar.pageLayout.items.first { $0.kind == .divider }
        ?? sidebar.pageLayout.items.first { $0.region == .scroll && $0.section == .list })
      let local = sidebar.modelFrame(anchor)
      let absolute = sidebar.convert(local, to: nil)
      let current = CGRect(x: absolute.minX, y: window.contentView!.bounds.height - absolute.maxY, width: absolute.width, height: absolute.height)
      let expected = current.minY + delta
      let regions = try #require(controller.probe()["regions"] as? [String: Any])
      let pinned = try #require(regions["pinnedGroups"] as? [String: Double])
      let tail = try #require(controller.items["tail:pinnedGroups"]?.frame)
      #expect(abs(try #require(pinned["y"]) - expected) <= 0.5)
      #expect(abs(tail.minY - expected) <= 0.5)
      #expect(abs(tail.minY - delta - current.minY) <= 0.5)
      if pinnedCount == 3 { #expect(controller.items["t:t0"]?.frame == fixedTile) }
      controller.end(commit: false)
    }
  }

  @Test func aSourceMonitorExitAllowsTheNextPressAndStillSwallowsAnOldUp() async throws {
    #if DEBUG
    await configurePairingTestApplication()
    #endif
    for ending in ["escape", "up"] {
      for staleUp in [false, true] {
        let bridge = ReuseDragBridge()
        let sidebar = try SidebarViewportTests.sidebar(2000)
        let window = NSPanel(contentRect: sidebar.bounds, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = sidebar
        defer { sidebar.stop(); window.contentView = nil; window.close() }
        var clicks: [String] = []
        sidebar.onAction = { if case .click(let id, _) = $0 { clicks.append(id) } }
        let controller = SidebarDragController.of(sidebar)
        controller.bridgeOverride = bridge
        let source = try #require(sidebar.views["t:t0"] as? SidebarRowView)
        source.mouseDown(with: try mouse(.leftMouseDown, in: window, row: source))
        let start = source.convert(CGPoint(x: source.bounds.midX + 12, y: source.bounds.midY), to: nil)
        let firstDrag = try #require(NSEvent.mouseEvent(with: .leftMouseDragged, location: start, modifierFlags: [],
          timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: 1))
        source.mouseDragged(with: firstDrag)
        #expect(controller.active && controller.followsPopoverDrag)
        #expect(bridge.beginnings == [["t0"]])
        sidebar.probeScroll(to: 3400)
        #expect(sidebar.views["t:t0"] == nil)
        let terminal: NSEvent
        if ending == "escape" {
          terminal = try #require(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
            windowNumber: window.windowNumber, context: nil, characters: "\u{1b}", charactersIgnoringModifiers: "\u{1b}", isARepeat: false, keyCode: 53))
        } else {
          let point = sidebar.convert(CGPoint(x: 90, y: 200), to: nil)
          terminal = try #require(NSEvent.mouseEvent(with: .leftMouseUp, location: point, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
            windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: 1))
        }
        NSApp.postEvent(terminal, atStart: false)
        for _ in 0..<50 where controller.active { try await Task.sleep(for: .milliseconds(10)) }
        #expect(!controller.active && !controller.followsPopoverDrag)
        #expect(bridge.endings == [ending == "up"])
        sidebar.probeScroll(to: 0)
        let next = try #require(sidebar.views["t:t0"] as? SidebarRowView)
        if staleUp {
          let oldUp = try mouse(.leftMouseUp, in: window, row: next)
          #expect(controller.release(next, oldUp))
          next.mouseUp(with: oldUp)
          #expect(clicks.isEmpty)
        }
        next.mouseDown(with: try mouse(.leftMouseDown, in: window, row: next))
        let point = next.convert(CGPoint(x: next.bounds.midX + 12, y: next.bounds.midY), to: nil)
        let nextDrag = try #require(NSEvent.mouseEvent(with: .leftMouseDragged, location: point, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
          windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: 1))
        next.mouseDragged(with: nextDrag)
        #expect(controller.active, "ending=\(ending), staleUp=\(staleUp)")
        #expect(bridge.beginnings == [["t0"], ["t0"]])
        #expect(clicks.isEmpty)
        controller.cancelForModeChange()
        #expect(!window.isVisible && !window.isKeyWindow)
      }
    }
  }

  @Test func downOnOneBindingThenScrollDragAndUpCannotClickItsReplacement() throws {
    let sidebar = try SidebarViewportTests.sidebar(2000)
    let window = NSWindow(contentRect: sidebar.bounds, styleMask: [.borderless], backing: .buffered, defer: false)
    window.isReleasedWhenClosed = false
    window.contentView = sidebar
    defer { sidebar.stop(); window.contentView = nil; window.close() }
    var clicks: [String] = []
    sidebar.onAction = { if case .click(let id, _) = $0 { clicks.append(id) } }
    let row = try #require(sidebar.views["t:t0"] as? SidebarRowView)
    row.mouseDown(with: try mouse(.leftMouseDown, in: window, row: row))
    sidebar.probeScroll(to: 3400)
    #expect(row.item?.key != "t:t0")
    row.mouseDragged(with: try mouse(.leftMouseDragged, in: window, row: row))
    row.mouseUp(with: try mouse(.leftMouseUp, in: window, row: row))
    #expect(clicks.isEmpty)
  }
}

#if SOLARA_PROBES
@MainActor
@Suite(.serialized)
struct SidebarRetirementBindingTests {
  @Test func closingALongColoredGroupCropsItsRetirementPictureToTheViewport() throws {
    guard !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion else { return }
    var state = try SidebarViewportTests.state(200)
    let ids = (0..<180).map { "t\($0)" }
    state.groups["g"] = TabGroup(id: "g", windowId: "w", profileId: "p", name: "Large", icon: nil, color: "blue", collapsed: false, pinned: false, tabIds: ids, createdAt: 0)
    let sidebar = SidebarView(windowId: "w", virtualizesRows: true)
    sidebar.frame = CGRect(x: 0, y: 0, width: 190, height: 400)
    let window = NSWindow(contentRect: sidebar.bounds, styleMask: [.borderless], backing: .buffered, defer: false)
    window.isReleasedWhenClosed = false
    window.contentView = sidebar
    defer { sidebar.stop(); window.contentView = nil; window.close() }
    sidebar.update(state: state, host: SidebarHostState(profileId: "p"))
    sidebar.layoutSubtreeIfNeeded()
    #expect(sidebar.views["gb:g"] != nil)
    state.groups["g"] = nil
    for id in ids { state.tabs[id] = nil }
    state.windows["w"]?.tabIds.removeAll { ids.contains($0) }
    state.windows["w"]?.activeTabIds["p"] = "t180"
    sidebar.update(state: state, host: SidebarHostState(profileId: "p"))
    let pictures = sidebar.probeRealization()["bound"] as? [[String: Any]] ?? []
    let group = try #require(pictures.first { $0["key"] as? String == "gb:g" && $0["retired"] as? Bool == true })
    let frame = try #require(group["frame"] as? [CGFloat])
    let clip = try #require(group["clip"] as? [CGFloat])
    #expect(frame[0] >= clip[0] && frame[1] >= clip[1] && frame[0] + frame[2] <= clip[0] + clip[2] && frame[1] + frame[3] <= clip[1] + clip[3])
  }

  @Test func visibleCloseUsesAClippedPictureAndLateCompletionCannotRemoveAReboundCell() async throws {
    let sidebar = try SidebarViewportTests.sidebar(2000)
    let window = NSWindow(contentRect: sidebar.bounds, styleMask: [.borderless], backing: .buffered, defer: false)
    window.isReleasedWhenClosed = false
    window.contentView = sidebar
    defer { sidebar.stop(); window.contentView = nil; window.close() }
    let old = try #require(sidebar.views["t:t0"] as? SidebarRowView)
    var state = try SidebarViewportTests.state(2000)
    state.tabs["t0"] = nil
    state.windows["w"]?.tabIds.removeAll { $0 == "t0" }
    state.windows["w"]?.activeTabIds["p"] = "t1"
    sidebar.update(state: state, host: SidebarHostState(profileId: "p"))
    let immediate = sidebar.probeRealization()["bound"] as? [[String: Any]] ?? []
    if !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion {
      #expect(immediate.contains { $0["key"] as? String == "t:t0" && $0["retired"] as? Bool == true })
    }
    #expect(old.item?.key != "t:t0")
    let replacementKey = try #require(old.item?.key)
    await withCheckedContinuation { continuation in
      DispatchQueue.main.asyncAfter(deadline: .now() + 0.22) { continuation.resume() }
    }
    #expect(sidebar.views[replacementKey] === old)
    #expect(old.superview != nil && !old.retired && old.alphaValue == 1)
    #expect((sidebar.probeRealization()["bound"] as? [[String: Any]] ?? []).allSatisfy { $0["retired"] as? Bool == false })
  }
}
#endif

@MainActor
@Suite(.serialized)
struct SidebarVisualReuseTests {
  @Test func recyclingPreservesPermanentNestedMasksWhileRemovingTheTransientRowMask() throws {
    let sidebar = try SidebarViewportTests.sidebar(2000)
    let row = try #require(sidebar.views["t:t0"] as? SidebarRowView)
    func masks(_ layer: CALayer) -> [(CALayer, CALayer)] {
      (layer.sublayers ?? []).flatMap { child in (child.mask.map { [(child, $0)] } ?? []) + masks(child) }
    }
    func nestedMasks(_ view: NSView) -> [(CALayer, CALayer)] {
      (view.layer.map(masks) ?? []) + view.subviews.flatMap(nestedMasks)
    }
    let permanent = nestedMasks(row)
    #expect(!permanent.isEmpty)
    row.layer?.mask = CALayer()
    sidebar.probeScroll(to: 3400)
    #expect(row.layer?.mask == nil)
    #expect(permanent.allSatisfy { $0.0.mask === $0.1 })
  }

  @Test func rebindingTheSameCachedImageDoesNotLeaveThePictureLayerBlank() {
    let image = NSImage(size: CGSize(width: 16, height: 16))
    let icon = TabIconView()
    let state = FaviconState(url: "https://same.test/", size: 16, dark: true, textSecondary: "#ffffff", mode: "image", initial: nil, uri: nil, tint: nil, token: 1)
    icon.setResolved(state, image: image)
    let picture = icon.layer?.sublayers?.compactMap { $0 as? PictureLayer }.first
    #expect(picture?.contents != nil)
    icon.clearBinding()
    icon.setResolved(state, image: image)
    #expect(picture?.contents != nil)
  }

  @Test func nativeAccessibilityKeepsTidyClearAndVisiblePillControls() throws {
    let sidebar = try SidebarViewportTests.sidebar(2000)
    var host = SidebarHostState(profileId: "p")
    host.tidy = true
    host.clear = true
    var state = try SidebarViewportTests.state(2000)
    state.tabs["t0"]?.pinned = true
    state.tabs["t0"]?.pinnedAsRow = true
    sidebar.update(state: state, host: host)
    sidebar.layoutSubtreeIfNeeded()
    #expect(sidebar.pageLayout.items.contains { $0.kind == .divider })
    func labels(_ object: Any, depth: Int = 0) -> [String] {
      guard depth < 12, let object = object as? NSAccessibilityProtocol else { return [] }
      return (object.isAccessibilityElement() ? object.accessibilityLabel().map { [$0] } ?? [] : []) + (object.accessibilityChildren() ?? []).flatMap { labels($0, depth: depth + 1) }
    }
    let initial = labels(sidebar)
    let hasTidy = initial.contains("Tidy pinned tabs")
    let hasClear = initial.contains("Clear unpinned tabs")
    #expect(hasTidy)
    #expect(hasClear)
    sidebar.probeScroll(to: 3400)
    #expect(labels(sidebar).contains { $0.hasPrefix("Scroll up to Tab 0") })
  }
}

#if SOLARA_PROBES
@MainActor
@Suite(.serialized)
struct SidebarSplitBindingTests {
  private func state() throws -> BrowserState {
    var state = try SidebarViewportTests.state(2000)
    state.splits["first"] = SplitView(id: "first", windowId: "w", tabIds: ["t0", "t1"], orientation: "horizontal", sizes: [0.5, 0.5])
    state.splits["last"] = SplitView(id: "last", windowId: "w", tabIds: ["t1998", "t1999"], orientation: "horizontal", sizes: [0.5, 0.5])
    return state
  }

  @Test func recyclingSplitPanesCancelsTheirFaviconInterestsBeforeRemoval() async throws {
    let favicons = SidebarFavicons()
    var continuations: [CheckedContinuation<NSImage?, Never>] = []
    favicons.loader = { _ in await withCheckedContinuation { continuations.append($0) } }
    let sidebar = SidebarView(windowId: "w", favicons: favicons, virtualizesRows: true)
    sidebar.frame = CGRect(x: 0, y: 0, width: 190, height: 400)
    sidebar.update(state: try state(), host: SidebarHostState(profileId: "p"))
    #expect(sidebar.views["s:first"] != nil)
    for _ in 0..<20 { await Task.yield() }
    sidebar.probeScroll(to: 3400)
    sidebar.stop()
    #expect(favicons.pendingInterestCount == 0)
    for continuation in continuations { continuation.resume(returning: nil) }
    for _ in 0..<10 { await Task.yield() }
  }

  @Test func offscreenFullSplitAccessibilityPressActuallyActivatesItsFirstPane() throws {
    let sidebar = SidebarView(windowId: "w", virtualizesRows: true)
    sidebar.frame = CGRect(x: 0, y: 0, width: 190, height: 400)
    sidebar.update(state: try state(), host: SidebarHostState(profileId: "p"))
    var clicks: [String] = []
    sidebar.onAction = { if case .click(let id, _) = $0 { clicks.append(id) } }
    #expect(sidebar.probeAccessibility(key: "s:last", action: "press"))
    #expect(clicks == ["t1998"])
    sidebar.stop()
  }

  @Test func middleMouseUpAfterASplitRebindCannotCloseTheNewPane() throws {
    let sidebar = SidebarView(windowId: "w", virtualizesRows: true)
    sidebar.frame = CGRect(x: 0, y: 0, width: 190, height: 400)
    sidebar.update(state: try state(), host: SidebarHostState(profileId: "p"))
    let row = try #require(sidebar.views["s:first"] as? SplitRowView)
    var middleClicks: [String] = []
    sidebar.onAction = { if case .middleClick(let id) = $0 { middleClicks.append(id) } }
    let window = NSWindow(contentRect: sidebar.bounds, styleMask: [.borderless], backing: .buffered, defer: false)
    window.isReleasedWhenClosed = false
    window.contentView = sidebar
    defer { sidebar.stop(); window.contentView = nil; window.close() }
    func event(_ type: NSEvent.EventType) throws -> NSEvent {
      let point = row.convert(CGPoint(x: 20, y: 15), to: nil)
      let initial = try #require(NSEvent.mouseEvent(with: type, location: point, modifierFlags: [], timestamp: 0, windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: 1))
      let cg = try #require(initial.cgEvent)
      cg.setIntegerValueField(.mouseEventButtonNumber, value: 2)
      let event = try #require(NSEvent(cgEvent: cg))
      #expect(event.buttonNumber == 2)
      #expect(abs(event.locationInWindow.x - point.x) < 0.5 && abs(event.locationInWindow.y - point.y) < 0.5)
      return event
    }
    row.layoutSubtreeIfNeeded()
    row.otherMouseDown(with: try event(.otherMouseDown))
    row.otherMouseUp(with: try event(.otherMouseUp))
    #expect(middleClicks == ["t0"])
    middleClicks.removeAll()
    row.otherMouseDown(with: try event(.otherMouseDown))
    #expect(sidebar.probeReveal(key: "s:last"))
    #expect(sidebar.views["s:last"] === row)
    row.layoutSubtreeIfNeeded()
    row.otherMouseUp(with: try event(.otherMouseUp))
    #expect(middleClicks.isEmpty)
    middleClicks.removeAll()
    row.otherMouseDown(with: try event(.otherMouseDown))
    row.otherMouseUp(with: try event(.otherMouseUp))
    #expect(middleClicks == ["t1998"])
  }
}
#endif

#endif

#if SOLARA_PROBES
@MainActor
@Suite(.serialized)
struct SidebarNestedControlBindingTests {
  @Test func aResetNestedControlCannotAcceptTheOldPointerSequence() throws {
    let close = SidebarIconButton(frame: CGRect(x: 0, y: 0, width: 100, height: 24))
    let upsell = UpsellButton(title: "Clean Up Once", primary: true)
    upsell.frame = close.frame
    for control in [close, upsell] as [NSView] {
      var actions = 0
      close.onPress = { actions += 1 }
      upsell.onPress = { actions += 1 }
      func event(_ type: NSEvent.EventType) throws -> NSEvent {
        try #require(NSEvent.mouseEvent(with: type, location: CGPoint(x: 50, y: 12), modifierFlags: [], timestamp: 0, windowNumber: 0, context: nil, eventNumber: 0, clickCount: 1, pressure: 1))
      }
      control.mouseDown(with: try event(.leftMouseDown))
      SidebarRowReuse.reset(control)
      control.mouseDragged(with: try event(.leftMouseDragged))
      control.mouseUp(with: try event(.leftMouseUp))
      #expect(actions == 0)
      actions = 0
      control.mouseDown(with: try event(.leftMouseDown))
      control.mouseUp(with: try event(.leftMouseUp))
      #expect(actions == 1)
    }
  }
}
#endif

@MainActor
@Suite(.serialized)
struct SidebarRailReuseControlTests {
  @Test func aHoveredRailCloseControlCannotRemainVisibleOrKeepItsIdentityAfterRebind() throws {
    var state = try SidebarViewportTests.state(2)
    let favicons = SidebarFavicons()
    let host = SidebarHostState(profileId: "p")
    let before = SidebarContext(state: state, host: host, windowId: "w", favicons: favicons)
    before.virtualizesRows = true
    let root = SidebarLayer(frame: CGRect(x: 0, y: 0, width: 42, height: 70))
    let window = NSPanel(contentRect: root.bounds, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
    window.isReleasedWhenClosed = false
    window.contentView = root
    defer { window.contentView = nil; window.close() }
    let row = RailTabView(frame: CGRect(x: 6, y: 6, width: 30, height: 30))
    root.addSubview(row)
    func item(_ id: String) -> SidebarItem {
      SidebarItem(kind: .tab(id), frame: row.frame, region: .scroll, groups: [], section: .list)
    }
    func controls(_ view: NSView) -> [SidebarIconButton] {
      view.subviews.flatMap { child in (child as? SidebarIconButton).map { [$0] } ?? controls(child) }
    }
    func visibleControls() -> [SidebarIconButton] {
      controls(row).filter { !$0.isHiddenOrHasHiddenAncestor && $0.alphaValue > 0.01 }
    }
    row.update(item("t0"), before)
    row.hovered = true
    root.layoutSubtreeIfNeeded()
    let oldClose = try #require(visibleControls().first)
    #expect(oldClose.toolTip == "Close Tab")
    #expect(oldClose.alphaValue > 0.99)
    row.prepareForReuse()
    #expect(row.tabId == nil && oldClose.superview == nil)
    state.windows["w"]?.activeTabIds["p"] = "t1"
    let after = SidebarContext(state: state, host: host, windowId: "w", favicons: favicons)
    after.virtualizesRows = true
    var activated: [String] = []
    var closed: [String] = []
    after.send = {
      if case .click(let id, _) = $0 { activated.append(id) }
      if case .close(let id) = $0 { closed.append(id) }
    }
    root.addSubview(row)
    row.update(item("t1"), after)
    root.layoutSubtreeIfNeeded()
    #expect(row.tabId == "t1" && row.accessibleTitle == "Tab 1" && !row.hovered)
    #expect(visibleControls().isEmpty)
    row.click(SidebarClickMods([]), count: 1)
    #expect(activated == ["t1"])
    row.hovered = true
    root.layoutSubtreeIfNeeded()
    let newClose = try #require(visibleControls().first)
    #expect(newClose !== oldClose)
    let point = newClose.convert(CGPoint(x: newClose.bounds.midX, y: newClose.bounds.midY), to: nil)
    func event(_ type: NSEvent.EventType) throws -> NSEvent {
      try #require(NSEvent.mouseEvent(with: type, location: point, modifierFlags: [], timestamp: 0, windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: 1))
    }
    newClose.mouseDown(with: try event(.leftMouseDown))
    newClose.mouseUp(with: try event(.leftMouseUp))
    #expect(closed == ["t1"])
    #expect(!window.isVisible && !window.isKeyWindow)
    row.prepareForReuse()
  }
}
