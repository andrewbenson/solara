import AppKit
import SolaraModel
import SolaraStore

@MainActor
public final class SplitDropZone: TabDropZone {
  public static let slide: TimeInterval = 0.11

  public let windowId: String
  public var state: () -> BrowserState? = { nil }
  public var onDrop: (_ tabId: String, _ targetTabId: String, _ side: SplitSide) -> Bool = { _, _, _ in false }
  public var covered: (_ windowPoint: CGPoint) -> Bool = { _ in false }
  public private(set) var target: SplitDropTarget?
  public private(set) var grown = false
  private weak var chrome: SplitChromeView?
  private var candidates: [SplitDropPane] = []
  private var px: CGFloat = 0
  private var shown = false
  private var timer: Timer?

  public init(windowId: String, chrome: SplitChromeView) {
    self.windowId = windowId
    self.chrome = chrome
  }

  public func aim(_ session: TabDragSession, at windowPoint: CGPoint) -> TabDropAim? {
    guard let chrome, let window = chrome.window, let dragging = session.tabIds.first else { return hide() }
    let height = window.contentView?.bounds.height ?? 0
    let local = chrome.convert(NSPoint(x: windowPoint.x, y: height - windowPoint.y), from: nil)
    let panes = chrome.panes
    let next = Self.candidates(state(), windowId: windowId, dragging: dragging, panes: panes)
    let overPage = panes.values.contains { $0.contains(local) }
    guard !next.isEmpty, overPage, !covered(windowPoint), chrome.windowShell?.sidebarPeekCoverage?.contains(windowPoint) != true, session.lifted != false, !session.outside else { return hide() }
    guard session.tabIds.count == 1 else {
      clear()
      return .page
    }
    candidates = next
    px = local.x
    if !shown {
      shown = true
      grown = false
      timer?.invalidate()
      let grows = Timer(timeInterval: Self.slide, repeats: false) { [weak self] _ in
        MainActor.assumeIsolated { self?.grow() }
      }
      RunLoop.main.add(grows, forMode: .common)
      timer = grows
    }
    target = grown ? SplitDrop.zoneHit(next.map { ($0.tabId, $0.rect) }, local.x, local.y, current: target) : nil
    publish()
    return target.map { .split(tabId: $0.tabId, side: $0.side) } ?? .page
  }

  public func clear() { _ = hide() }

  public func drop(_ session: TabDragSession, _ aim: TabDropAim) -> Bool {
    defer { _ = hide() }
    guard case let .split(tabId, side) = aim, session.tabIds.count == 1,
      let dragging = session.tabIds.first, dragging != tabId, session.sourceWindow == windowId,
      let state = state(), let target = state.tabs[tabId], target.windowId == windowId,
      let source = state.tabs[dragging], source.windowId == windowId, source.profileId == target.profileId,
      state.windows[windowId]?.profileId == source.profileId else { return false }
    return onDrop(dragging, tabId, side)
  }

  static func candidates(_ state: BrowserState?, windowId: String, dragging: String, panes: [String: CGRect]) -> [SplitDropPane] {
    guard let state, let window = state.windows[windowId], let source = state.tabs[dragging],
      source.windowId == windowId, source.profileId == window.profileId else { return [] }
    if let split = Splits.splitOf(state, window.activeTabIds[window.profileId]), split.tabIds.count >= Splits.maxPanes, !split.tabIds.contains(dragging) { return [] }
    if panes.count == 1, let rect = panes[dragging] {
      let fallback = window.tabIds.compactMap { state.tabs[$0] }.filter { $0.id != dragging && $0.profileId == source.profileId }.max { $0.lastActiveAt < $1.lastActiveAt }
      return fallback.map { [SplitDropPane(tabId: $0.id, rect: rect)] } ?? []
    }
    return panes.filter { $0.key != dragging && state.tabs[$0.key]?.windowId == windowId && state.tabs[$0.key]?.profileId == source.profileId }.sorted { $0.key < $1.key }.map { SplitDropPane(tabId: $0.key, rect: $0.value) }
  }

  private func grow() {
    guard shown else { return }
    grown = true
    publish()
    TabDragSession.current?.reaim?()
  }

  private func hide() -> TabDropAim? {
    timer?.invalidate()
    timer = nil
    if shown {
      shown = false
      grown = false
      target = nil
      chrome?.setDrag(SplitDragFrame(shown: false, grown: false, px: px, target: nil, panes: candidates))
    }
    return nil
  }

  private func publish() {
    chrome?.setDrag(SplitDragFrame(shown: true, grown: grown, px: px, target: target, panes: candidates))
  }
}
