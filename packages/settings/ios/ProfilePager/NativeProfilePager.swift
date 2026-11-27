import AppKit
import SolaraCore
import SolaraShaders
import ExpoModulesCore
import Foundation
import QuartzCore
import SolaraModel
import SolaraStore
import SolaraUI

@MainActor
enum NativeProfilePager {
  static var hosts: [String: ProfilePagerHost] = [:]

  static func start(_ shell: WindowShellView, subscribeToStore: Bool = true) -> ProfilePagerHost? {
    guard NativeWindowShell.enabled else { return nil }
    let host = ProfilePagerHost(shell: shell, subscribeToStore: subscribeToStore)
    hosts[shell.windowId] = host
    return host
  }

  static func ended(_ host: ProfilePagerHost) {
    if hosts[host.windowId] === host { hosts[host.windowId] = nil }
  }

  static func describe(_ windowId: String) -> String {
    let info = hosts[windowId]?.describe() ?? [:]
    guard let data = try? JSONSerialization.data(withJSONObject: info) else { return "{}" }
    return String(decoding: data, as: UTF8.self)
  }
}

final class ProfilePagerCommits: @unchecked Sendable {
  private let lock = NSLock()
  private var latest: BrowserState?
  private var selectionRequested = false
  private var scheduled = false
  weak var host: ProfilePagerHost?

  func receive(_ state: BrowserState, selectionRequested: Bool) {
    let schedule = lock.withLock { () -> Bool in
      latest = state
      self.selectionRequested = self.selectionRequested || selectionRequested
      if scheduled { return false }
      scheduled = true
      return true
    }
    if Thread.isMainThread {
      MainActor.assumeIsolated { flush() }
    } else if schedule {
      DispatchQueue.main.async { [self] in flush() }
    }
  }

  @MainActor private func flush() {
    let pending = lock.withLock { () -> (BrowserState, Bool)? in
      scheduled = false
      defer { latest = nil; selectionRequested = false }
      return latest.map { ($0, selectionRequested) }
    }
    if let pending { host?.commit(pending.0, selectionRequested: pending.1) }
  }
}

@MainActor
final class ProfilePagerHost {
  static let wheelThreshold = 1.0
  static let wheelBurst = 0.049
  static let wheelCooldown = 0.25

  let windowId: String
  private weak var shell: WindowShellView?
  let sidebarTarget = NativeSwipeTarget()
  let stripTarget = NativeSwipeTarget()
  let peekTarget = NativeSwipeTarget()
  let tint = ProfileTintView()
  var sidebarScrollOffsets: [String: CGFloat] = [:]
  var stripScrollOffsets: [Bool: [String: CGFloat]] = [:]
  private var listener: Int?
  private let commits = ProfilePagerCommits()
  private var positionObserver: NSObjectProtocol?
  private var loadObserver: NSObjectProtocol?
  private struct TintInput: Equatable {
    var order: [String]
    var profiles: [Profile?]
    var dark: Bool
    var followsAppearance: Bool
  }

  private var tintInput: TintInput?
  private var looks: [String: NSDictionary] = [:]
  private var window: ProfilePagerSelection?
  private var ack = 0
  private var pager: ACPager?
  private var wheel = (sum: 0.0, last: 0.0, trigger: -Double.infinity)
  private var applied: (profile: String, neighbours: [String], selection: String)?
  private var swap: CFRunLoopObserver?
  private var stopped = false

  init(shell: WindowShellView, subscribeToStore: Bool = true) {
    windowId = shell.windowId
    self.shell = shell
    let windowId = windowId
    stripTarget.measuredWidth = { CGFloat(NativeTopStrip.hosts[windowId]?.swipeWidth ?? 0) }
    peekTarget.measuredWidth = { CGFloat(TopStripPeekHost.hosts[windowId]?.strip.swipeWidth ?? 0) }
    peekTarget.isHidden = true
    peekTarget.autoresizingMask = [.width, .height]
    peekTarget.onSwipe = { [weak self] event in self?.swiped(event) }
    peekTarget.onPagerState = { [weak self] event in self?.pagerChanged(event) }
    for target in [sidebarTarget, stripTarget] {
      target.isHidden = true
      target.autoresizingMask = []
      target.onSwipe = { [weak self] event in self?.swiped(event) }
      target.onPagerState = { [weak self] event in self?.pagerChanged(event) }
      shell.addSubview(target)
    }
    shell.mount(.tint, tint)
    commits.host = self
    positionObserver = NotificationCenter.default.addObserver(forName: Notification.Name("SolaraPagerPosition"), object: nil, queue: nil) {
      [weak self] note in
      guard note.userInfo?["key"] as? String == windowId, let position = note.userInfo?["position"] as? Double else { return }
      MainActor.assumeIsolated {
        guard let self, !self.stopped else { return }
        self.tint.position = position
      }
    }
    loadObserver = NotificationCenter.default.addObserver(forName: Notification.Name("SolaraCoreProfileDidLoad"), object: nil, queue: .main) {
      [weak self] note in
      guard let profile = note.userInfo?["profile"] as? String else { return }
      MainActor.assumeIsolated { self?.neighbourLoaded(profile) }
    }
    if subscribeToStore, let store = NativeStoreHandle.store {
      let sink = commits
      listener = store.subscribe { commit in
        sink.receive(commit.state, selectionRequested: commit.origin == .bridge && commit.commands.contains { $0.name == "switchProfile" && $0.args.first?.string == windowId })
      }
      commit(store.state)
    }
    place()
  }

  func stop() {
    guard !stopped else { return }
    stopped = true
    if let listener { NativeStoreHandle.store?.unsubscribe(listener) }
    listener = nil
    if let positionObserver { NotificationCenter.default.removeObserver(positionObserver) }
    positionObserver = nil
    if let loadObserver { NotificationCenter.default.removeObserver(loadObserver) }
    loadObserver = nil
    if let swap { CFRunLoopRemoveObserver(CFRunLoopGetMain(), swap, .commonModes) }
    swap = nil
    sidebarTarget.use(nil)
    stripTarget.use(nil)
    peekTarget.use(nil)
    sidebarTarget.removeFromSuperview()
    stripTarget.removeFromSuperview()
    peekTarget.removeFromSuperview()
    if shell?.view(in: .tint) === tint { shell?.mount(.tint, nil) }
    NativeProfilePager.ended(self)
  }

  func place() {
    guard !stopped, let shell else { return }
    let frames = shell.frames
    let sidebar = frames.sidebar.map { $0.offsetBy(dx: frames.sidebarShift, dy: 0) }
    sidebarTarget.frame = sidebar ?? .zero
    stripTarget.frame = frames.topStrip ?? .zero
    let live = window?.index != nil
    sidebarTarget.isHidden = !live || sidebar == nil
    stripTarget.isHidden = !live || frames.topStrip == nil
    if let peek = TopStripPeekHost.hosts[windowId], let content = peek.view.content {
      if peekTarget.superview !== content { content.addSubview(peekTarget) }
      peekTarget.frame = content.bounds
      peekTarget.isHidden = !live || !peek.view.live
    } else {
      peekTarget.isHidden = true
      peekTarget.removeFromSuperview()
    }
    if let last = shell.subviews.last, last !== stripTarget {
      for target in [sidebarTarget, stripTarget] where target.superview === shell {
        shell.addSubview(target, positioned: .above, relativeTo: nil)
      }
    }
  }

  func commit(_ state: BrowserState, selectionRequested: Bool = false) {
    guard !stopped, let next = ProfilePagerSelection(state: state, windowId: windowId) else { return }
    let previous = window
    window = next
    configure(next, previous: previous, selectionRequested: selectionRequested)
    if previous != next { scheduleSwap() }
    renderTint(state)
    place()
  }

  private func configure(_ w: ProfilePagerSelection, previous: ProfilePagerSelection?, selectionRequested: Bool) {
    let multiple = w.order.count > 1
    for target in [sidebarTarget, stripTarget, peekTarget] {
      target.canSwipeBack = (w.index ?? 0) > 0
      target.canSwipeForward = w.index.map { $0 < w.order.count - 1 } ?? false
      target.tracksUnavailableDirections = multiple
      target.isPager = multiple
    }
    guard let index = w.index else {
      sidebarTarget.use(nil)
      stripTarget.use(nil)
      peekTarget.use(nil)
      pager = nil
      return
    }
    let pager = ACPager.named(windowId)
    self.pager = pager
    sidebarTarget.use(pager)
    stripTarget.use(pager)
    peekTarget.use(pager)
    pager.configure(selected: index, count: w.order.count, ack: ack, order: w.order.joined(separator: "\n"))
    if selectionRequested {
      for target in [sidebarTarget, stripTarget, peekTarget] { ACSwipe.cancelTarget(target) }
    }
    guard previous != nil, selectionRequested || previous?.profileId != w.profileId && selectedProfile != w.profileId else { return }
    if pager.select(w.profileId, order: w.order.joined(separator: "\n")) { acknowledge() }
  }

  private var selectedProfile: String? {
    ACPager.snapshot(windowId)?["profileId"] as? String
  }

  private func pagerChanged(_ event: [String: Any]) {
    acknowledge(event)
  }

  private func acknowledge(_ event: [String: Any]? = nil) {
    guard !stopped, let snapshot = ACPager.snapshot(windowId) ?? event, let sequence = (snapshot["sequence"] as? NSNumber)?.intValue, sequence > ack else { return }
    guard let store = NativeStoreHandle.store else { return }
    let state = store.state
    let order = state.profileOrder
    let id = snapshot["profileId"] as? String ?? (snapshot["selected"] as? NSNumber).flatMap { order.indices.contains($0.intValue) ? order[$0.intValue] : nil }
    ack = sequence
    if let w = state.windows[windowId], !w.incognito, let id, state.profiles[id] != nil, id != w.profileId {
      _ = try? store.dispatch(Command("switchProfile", [.string(windowId), .string(id)]), origin: .native)
    }
    commit(store.state)
  }

  private func neighbourLoaded(_ profile: String) {
    guard !stopped, let w = window, w.neighbours.contains(profile), let applied, applied.neighbours.contains(profile) else { return }
    self.applied = (applied.profile, [], applied.selection)
    scheduleSwap()
  }

  private func swiped(_ event: [String: Any]) {
    guard !stopped else { return }
    switch event["phase"] as? String {
    case "swipe": step(event["direction"] as? String == "back" ? -1 : 1)
    case "wheel": wheeled(event)
    default: break
    }
  }

  private func wheeled(_ event: [String: Any]) {
    let now = CACurrentMediaTime()
    if now - wheel.trigger <= Self.wheelCooldown { return }
    if now - wheel.last > Self.wheelBurst { wheel.sum = 0 }
    wheel.last = now
    let distance = (event["distance"] as? NSNumber)?.doubleValue ?? 0
    wheel.sum += event["direction"] as? String == "back" ? -distance : distance
    guard abs(wheel.sum) > Self.wheelThreshold else { return }
    let delta = wheel.sum < 0 ? -1 : 1
    wheel.sum = 0
    wheel.trigger = now
    step(delta)
  }

  func switchTo(_ profileId: String) {
    guard !stopped, let w = window, let index = w.order.firstIndex(of: profileId) else { return }
    if pager?.switchTo(index, order: w.order.joined(separator: "\n")) == true { return }
    select(profileId)
  }

  func step(_ delta: Int, wrap: Bool = false) {
    guard !stopped, let w = window, let index = w.index, delta == -1 || delta == 1 else { return }
    if pager?.step(delta, wrap: wrap, order: w.order.joined(separator: "\n")) == true { return }
    let target = wrap ? (index + delta + w.order.count) % w.order.count : index + delta
    guard w.order.indices.contains(target) else { return }
    select(w.order[target])
  }

  private func select(_ profileId: String) {
    _ = try? WorkspaceWrites.store?.dispatch(Command("switchProfile", [.string(windowId), .string(profileId)]), origin: .native)
  }

  private func renderTint(_ state: BrowserState) {
    guard let w = window, let index = w.index else {
      tint.show(nil)
      shell?.cardEdgeTint = nil
      return
    }
    let input = TintInput(order: w.order, profiles: w.order.map { state.profiles[$0] }, dark: state.ui.appDark,
      followsAppearance: state.settings.bool("spacesFollowAppearance"))
    if input != tintInput {
      tintInput = input
      looks = Dictionary(uniqueKeysWithValues: Set(w.order).compactMap { id in
        let look = LaunchBackdropProvider.profile(state, profileId: id, appDark: input.dark).foundation
        return (look as? NSDictionary).map { (id, $0) }
      })
      tint.show(w.order.map { ($0, looks[$0]) })
    } else if tint.isHidden {
      tint.show(w.order.map { ($0, looks[$0]) })
    }
    tint.position = (ACPager.snapshot(windowId)?["position"] as? Double) ?? Double(index)
    shell?.cardEdgeTint = Self.frameColor(looks[w.profileId])
  }

  static func frameColor(_ look: NSDictionary?) -> NSColor? {
    let hex = look?["tintColor"] as? String ?? (look?["colors"] as? [String])?.first
    return hex.flatMap { CSSColor($0)?.ns }
  }

  private func scheduleSwap() {
    guard !stopped, swap == nil else { return }
    let observer = CFRunLoopObserverCreateWithHandler(nil, CFRunLoopActivity.beforeWaiting.rawValue, false, 0) { [weak self] _, _ in
      MainActor.assumeIsolated {
        self?.swap = nil
        self?.applyProfile()
      }
    }
    swap = observer
    CFRunLoopAddObserver(CFRunLoopGetMain(), observer, .commonModes)
  }

  private func applyProfile() {
    guard !stopped, let w = window, let nsWindow = shell?.window, let host = NSClassFromString("ACChromeWindowHost") as? NSObject.Type else { return }
    if applied?.profile != w.engineProfile {
      host.perform(NSSelectorFromString("showProfile:inWindow:"), with: w.engineProfile, with: nsWindow)
    }
    if let applied, applied.profile != w.engineProfile || applied.selection != w.profileId {
      NotificationCenter.default.post(name: Notification.Name("SolaraPagerActivity"), object: nsWindow)
    }
    if applied?.neighbours != w.neighbours, !w.neighbours.isEmpty {
      host.perform(NSSelectorFromString("prepareProfiles:forWindow:"), with: w.neighbours, with: nsWindow)
    }
    applied = (w.engineProfile, w.neighbours, w.profileId)
  }

  func windowChanged() {
    guard !stopped else { return }
    applied = nil
    if window != nil { scheduleSwap() }
  }

  func describe() -> [String: Any] {
    func rect(_ view: NSView) -> [Double] {
      guard let root = view.window?.contentView else { return [] }
      let r = view.convert(view.bounds, to: nil)
      return [r.minX, root.bounds.height - r.maxY, r.width, r.height]
    }
    func target(_ t: NativeSwipeTarget) -> [String: Any] {
      [
        "frame": rect(t), "hidden": t.isHidden, "pageWidth": t.pageWidth, "back": t.canSwipeBack, "forward": t.canSwipeForward,
        "pager": t.isPager, "native": t.hasNativePager, "windowNumber": t.window?.windowNumber ?? 0,
      ]
    }
    return [
      "sidebar": target(sidebarTarget), "strip": target(stripTarget), "peek": target(peekTarget), "ack": ack, "tint": tint.describe(),
      "snapshot": ACPager.snapshot(windowId) ?? NSNull(),
      "applied": applied.map { ["profile": $0.profile, "neighbours": $0.neighbours, "selection": $0.selection] as [String: Any] } ?? NSNull(),
    ]
  }
}

@MainActor
final class ProfileTintView: NSView {
  private var pages: [(id: String, look: NSDictionary?, view: NSView)] = []

  var position = 0.0 {
    didSet { if position != oldValue { fade() } }
  }

  override var isFlipped: Bool { true }

  override func hitTest(_ point: NSPoint) -> NSView? { nil }

  override init(frame: NSRect) {
    super.init(frame: frame)
    wantsLayer = true
  }

  required init?(coder: NSCoder) { fatalError() }

  func show(_ next: [(String, NSDictionary?)]?) {
    guard let next else {
      for page in pages { page.view.removeFromSuperview() }
      pages = []
      isHidden = true
      return
    }
    isHidden = false
    let same = pages.count == next.count && zip(pages, next).allSatisfy { $0.id == $1.0 && $0.look == $1.1 }
    guard !same else { return }
    let old = pages
    pages = next.map { id, look in
      if let kept = old.first(where: { $0.id == id && $0.look == look }) { return kept }
      let view = look.flatMap { EarlyBackdrop.make($0) } ?? NSView()
      view.autoresizingMask = [.width, .height]
      return (id, look, view)
    }
    for page in old where !pages.contains(where: { $0.view === page.view }) { page.view.removeFromSuperview() }
    for page in pages {
      page.view.frame = bounds
      addSubview(page.view)
    }
    fade()
  }

  @objc var fullScreenBackdropSignature: String {
    "\(position)|" + pages.map { "\($0.id):\($0.look.debugDescription)" }.joined(separator: "|")
  }

  static func opacity(_ k: Int, position: Double) -> Double {
    k == 0 ? 1 : min(1, max(0, position - Double(k - 1)))
  }

  private func fade() {
    CATransaction.begin()
    CATransaction.setDisableActions(true)
    for (k, page) in pages.enumerated() { page.view.alphaValue = CGFloat(Self.opacity(k, position: position)) }
    CATransaction.commit()
  }

  var opacities: [Double] { pages.map { Double($0.view.alphaValue) } }

  func describe() -> [String: Any] {
    ["hidden": isHidden, "position": position, "pages": pages.enumerated().map { k, page in ["id": page.id, "opacity": Double(page.view.alphaValue), "look": page.look != nil] }]
  }
}

public class ProfilePagerModule: Module {
  public func definition() -> ModuleDefinition {
    Name("SolaraProfilePager")

    Function("active") { (windowId: String) -> Bool in
      NativeWindowShell.enabled && NativeWindowShell.active(windowId)
    }

    AsyncFunction("switchTo") { (windowId: String, profileId: String) in
      MainActor.assumeIsolated {
        if let host = NativeProfilePager.hosts[windowId] {
          host.switchTo(profileId)
        } else {
          _ = try? WorkspaceWrites.store?.dispatch(Command("switchProfile", [.string(windowId), .string(profileId)]), origin: .native)
        }
      }
    }.runOnQueue(.main)

    AsyncFunction("step") { (windowId: String, delta: Int) in
      MainActor.assumeIsolated {
        if let host = NativeProfilePager.hosts[windowId] {
          host.step(delta, wrap: true)
        } else if let store = WorkspaceWrites.store, let window = ProfilePagerSelection(state: store.state, windowId: windowId),
          let index = window.index, delta == -1 || delta == 1 {
          let target = (index + delta + window.order.count) % window.order.count
          _ = try? store.dispatch(Command("switchProfile", [.string(windowId), .string(window.order[target])]), origin: .native)
        }
      }
    }.runOnQueue(.main)

    AsyncFunction("describe") { (windowId: String) -> String in
      MainActor.assumeIsolated { NativeProfilePager.describe(windowId) }
    }.runOnQueue(.main)

    AsyncFunction("devProfileWarmup") { (action: String) -> String in
      #if DEBUG
      return MainActor.assumeIsolated { NativeProfileWarmup.shared.dev(action) }
      #else
      return "null"
      #endif
    }.runOnQueue(.main)

    AsyncFunction("devTrace") { (windowId: String, on: Bool) -> String in
      MainActor.assumeIsolated { PagerTrace.toggle(windowId, on) }
    }.runOnQueue(.main)
  }
}

@MainActor
enum PagerTrace {
  private static var observer: NSObjectProtocol?
  private static var samples: [[Any]] = []

  static func toggle(_ windowId: String, _ on: Bool) -> String {
    if let observer { NotificationCenter.default.removeObserver(observer) }
    observer = nil
    let taken = samples
    samples = []
    if on {
      observer = NotificationCenter.default.addObserver(forName: Notification.Name("SolaraPagerPosition"), object: nil, queue: nil) { note in
        guard note.userInfo?["key"] as? String == windowId, let position = note.userInfo?["position"] as? Double else { return }
        let timestamp = note.userInfo?["timestamp"] as? Double ?? CACurrentMediaTime()
        MainActor.assumeIsolated {
          let tint = NativeProfilePager.hosts[windowId]?.tint.opacities ?? []
          samples.append([timestamp, position, tint])
        }
      }
    }
    guard let data = try? JSONSerialization.data(withJSONObject: taken) else { return "[]" }
    return String(decoding: data, as: UTF8.self)
  }
}

#if SOLARA_PROBES
@MainActor
public enum ProfilePagerRead {
  public static func snapshot(windowId: String) -> [String: Any]? {
    guard let host = NativeProfilePager.hosts[windowId] else { return nil }
    return ["ack": host.describe()["ack"] ?? NSNull()]
  }
}
#endif
