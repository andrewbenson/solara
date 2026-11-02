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
  private(set) static var looks: [String: NSDictionary] = [:]

  static func start(_ shell: WindowShellView) -> ProfilePagerHost? {
    guard NativeWindowShell.enabled, NativeSidebar.enabled, NativeTopStrip.enabled else { return nil }
    let host = ProfilePagerHost(shell: shell)
    hosts[shell.windowId] = host
    return host
  }

  static var onPosition: ((String, Double) -> Void)?

  static func moved(_ windowId: String, _ position: Double) {
    onPosition?(windowId, position)
  }

  static func ended(_ host: ProfilePagerHost) {
    if hosts[host.windowId] === host { hosts[host.windowId] = nil }
  }

  static func setLooks(_ json: String) {
    guard let data = json.data(using: .utf8), let all = (try? JSONSerialization.jsonObject(with: data)) as? [String: NSDictionary] else { return }
    guard all != looks else { return }
    looks = all
    for host in hosts.values { host.looksChanged() }
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
  private var scheduled = false
  weak var host: ProfilePagerHost?

  func receive(_ state: BrowserState) {
    if Thread.isMainThread {
      lock.withLock { latest = nil }
      MainActor.assumeIsolated { host?.commit(state) }
      return
    }
    let schedule = lock.withLock { () -> Bool in
      latest = state
      if scheduled { return false }
      scheduled = true
      return true
    }
    guard schedule else { return }
    DispatchQueue.main.async { [self] in
      let state = lock.withLock { () -> BrowserState? in
        scheduled = false
        defer { latest = nil }
        return latest
      }
      guard let state else { return }
      MainActor.assumeIsolated { host?.commit(state) }
    }
  }
}

struct PagerWindow: Equatable {
  var profileId: String
  var order: [String]
  var index: Int?
  var engineProfile: String
  var neighbours: [String]
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
  let tint = ProfileTintView()
  private var listener: Int?
  private let commits = ProfilePagerCommits()
  private var positionObserver: NSObjectProtocol?
  private var window: PagerWindow?
  private var ack = 0
  private var pager: ACPager?
  private var wheel = (sum: 0.0, last: 0.0, trigger: -Double.infinity)
  private var applied: (profile: String, neighbours: [String], selection: String)?
  private var swap: CFRunLoopObserver?
  private var stopped = false

  init(shell: WindowShellView) {
    windowId = shell.windowId
    self.shell = shell
    let windowId = windowId
    stripTarget.measuredWidth = { CGFloat(NativeTopStrip.hosts[windowId]?.swipeWidth ?? 0) }
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
        self?.tint.position = position
        NativeProfilePager.moved(windowId, position)
      }
    }
    if let store = NativeStoreHandle.store {
      let sink = commits
      listener = store.subscribe { commit in sink.receive(commit.state) }
      commit(store.state)
    }
    place()
  }

  func stop() {
    stopped = true
    if let listener { NativeStoreHandle.store?.unsubscribe(listener) }
    listener = nil
    if let positionObserver { NotificationCenter.default.removeObserver(positionObserver) }
    positionObserver = nil
    if let swap { CFRunLoopRemoveObserver(CFRunLoopGetMain(), swap, .commonModes) }
    swap = nil
    sidebarTarget.use(nil)
    stripTarget.use(nil)
    sidebarTarget.removeFromSuperview()
    stripTarget.removeFromSuperview()
    if shell?.view(in: .tint) === tint { shell?.mount(.tint, nil) }
    NativeProfilePager.ended(self)
  }

  func place() {
    guard let shell else { return }
    let frames = shell.frames
    let sidebar = frames.sidebar.map { $0.offsetBy(dx: frames.sidebarShift, dy: 0) }
    sidebarTarget.frame = sidebar ?? .zero
    stripTarget.frame = frames.topStrip ?? .zero
    let live = window?.index != nil
    sidebarTarget.isHidden = !live || sidebar == nil
    stripTarget.isHidden = !live || frames.topStrip == nil
    if let last = shell.subviews.last, last !== stripTarget {
      for target in [sidebarTarget, stripTarget] where target.superview === shell {
        shell.addSubview(target, positioned: .above, relativeTo: nil)
      }
    }
  }

  func looksChanged() {
    renderTint()
  }

  func commit(_ state: BrowserState) {
    guard !stopped, let w = state.windows[windowId] else { return }
    let order = state.profileOrder
    let index = w.incognito ? nil : order.firstIndex(of: w.profileId)
    let next = PagerWindow(
      profileId: w.profileId, order: order, index: index, engineProfile: state.engineProfile(w.profileId),
      neighbours: index.map { i in [i - 1, i + 1].filter { order.indices.contains($0) }.map { state.engineProfile(order[$0]) } } ?? [])
    let previous = window
    window = next
    configure(next, previous: previous)
    if previous != next { scheduleSwap() }
    renderTint()
    place()
  }

  private func configure(_ w: PagerWindow, previous: PagerWindow?) {
    let multiple = w.order.count > 1
    for target in [sidebarTarget, stripTarget] {
      target.canSwipeBack = (w.index ?? 0) > 0
      target.canSwipeForward = w.index.map { $0 < w.order.count - 1 } ?? false
      target.tracksUnavailableDirections = multiple
      target.isPager = multiple
    }
    guard let index = w.index else {
      sidebarTarget.use(nil)
      stripTarget.use(nil)
      pager = nil
      return
    }
    let pager = ACPager.named(windowId)
    self.pager = pager
    sidebarTarget.use(pager)
    stripTarget.use(pager)
    pager.configure(selected: index, count: w.order.count, ack: ack, order: w.order.joined(separator: "\n"))
    guard let previous, previous.profileId != w.profileId, selectedProfile != w.profileId else { return }
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

  private func swiped(_ event: [String: Any]) {
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

  private func step(_ delta: Int) {
    guard let w = window, let index = w.index else { return }
    if pager?.step(delta, wrap: false, order: w.order.joined(separator: "\n")) == true { return }
    let target = index + delta
    guard w.order.indices.contains(target) else { return }
    _ = try? NativeStoreHandle.store?.dispatch(Command("switchProfile", [.string(windowId), .string(w.order[target])]), origin: .native)
  }

  private func renderTint() {
    guard let w = window, let index = w.index else { return tint.show(nil) }
    tint.show(w.order.map { ($0, NativeProfilePager.looks[$0]) })
    tint.position = (ACPager.snapshot(windowId)?["position"] as? Double) ?? Double(index)
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
      "sidebar": target(sidebarTarget), "strip": target(stripTarget), "ack": ack, "tint": tint.describe(),
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

    Events("onPagerPosition")

    OnStartObserving("onPagerPosition") {
      let sink = ProfilePagerSink(self)
      DispatchQueue.main.async {
        MainActor.assumeIsolated {
          NativeProfilePager.onPosition = { windowId, position in
            sink.module?.sendEvent("onPagerPosition", ["windowId": windowId, "position": position])
          }
        }
      }
    }

    OnStopObserving("onPagerPosition") {
      DispatchQueue.main.async { MainActor.assumeIsolated { NativeProfilePager.onPosition = nil } }
    }

    Function("active") { (windowId: String) -> Bool in
      NativeWindowShell.enabled && NativeSidebar.enabled && NativeTopStrip.enabled && NativeWindowShell.active(windowId)
    }

    AsyncFunction("setLooks") { (json: String) in
      MainActor.assumeIsolated { NativeProfilePager.setLooks(json) }
    }.runOnQueue(.main)

    AsyncFunction("describe") { (windowId: String) -> String in
      MainActor.assumeIsolated { NativeProfilePager.describe(windowId) }
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
        MainActor.assumeIsolated {
          let tint = NativeProfilePager.hosts[windowId]?.tint.opacities ?? []
          samples.append([CACurrentMediaTime(), position, tint])
        }
      }
    }
    guard let data = try? JSONSerialization.data(withJSONObject: taken) else { return "[]" }
    return String(decoding: data, as: UTF8.self)
  }
}

private final class ProfilePagerSink: @unchecked Sendable {
  weak var module: ProfilePagerModule?
  init(_ module: ProfilePagerModule) { self.module = module }
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
