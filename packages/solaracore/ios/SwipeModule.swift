import Darwin
import ExpoModulesCore
import QuartzCore

public class SwipeModule: Module {
  public func definition() -> ModuleDefinition {
    Name("SolaraSwipe")

    Function("haptic") { (pattern: String) in
      DispatchQueue.main.async { ACSwipe.performHaptic(pattern) }
    }

    AsyncFunction("switchPager") { (key: String, index: Int, order: String?) -> Bool in
      ACPager.existing(key)?.switchTo(index, order: order) ?? false
    }.runOnQueue(.main)

    AsyncFunction("selectPager") { (key: String, profileId: String, order: String) -> Bool in
      ACPager.existing(key)?.select(profileId, order: order) ?? false
    }.runOnQueue(.main)

    AsyncFunction("stepPager") { (key: String, delta: Int, wrap: Bool, order: String?) -> Bool in
      ACPager.existing(key)?.step(delta, wrap: wrap, order: order) ?? false
    }.runOnQueue(.main)

    Function("pagerState") { (key: String) -> [String: Any]? in ACPager.snapshot(key) }

    AsyncFunction("devPagerState") { (key: String) -> [String: Any]? in
      #if DEBUG
      return ACPager.existing(key)?.debug()
      #else
      return nil
      #endif
    }.runOnQueue(.main)

    AsyncFunction("devSimulate") { (x: Double, y: Double, windowNumber: Int, steps: [[String: Any]], ignorePreference: Bool, promise: Promise) in
      #if DEBUG
      guard let window = NSApp.window(withWindowNumber: windowNumber) else {
        promise.resolve(["error": "no window \(windowNumber)"])
        return
      }
      ACSwipe.simulate(in: window, point: NSPoint(x: x, y: y), steps: steps, ignoreSystemPreference: ignorePreference) {
        #if SOLARA_PROBES
        let result = $0
        let recorded = MainActor.assumeIsolated { SwipeRead.record(result) ?? result }
        promise.resolve(recorded)
        #else
        promise.resolve($0)
        #endif
      }
      #else
      promise.resolve(["error": "DEV builds only"])
      #endif
    }.runOnQueue(.main)

    View(SwipeArea.self) {
      Events("onSwipe", "onPagerPosition", "onPagerState")
      Prop("canSwipeBack") { (view: SwipeArea, value: Bool?) in view.canSwipeBack = value ?? false }
      Prop("canSwipeForward") { (view: SwipeArea, value: Bool?) in view.canSwipeForward = value ?? false }
      Prop("tracksUnavailableDirections") { (view: SwipeArea, value: Bool?) in view.tracksUnavailableDirections = value ?? false }
      Prop("allowsVerticalMotion") { (view: SwipeArea, value: Bool?) in view.allowsVerticalMotion = value ?? false }
      Prop("isPager") { (view: SwipeArea, value: Bool?) in view.isPager = value ?? false }
      Prop("coversPage") { (view: SwipeArea, value: Bool?) in view.coversPage = value ?? false }
      Prop("nativePager") { (view: SwipeArea, value: [String: Any]?) in view.configurePager(value) }
      AsyncFunction("devLocate") { (view: SwipeArea) -> [String: Any]? in
        guard let window = view.window, let content = window.contentView else { return nil }
        let frame = view.convert(view.bounds, to: content)
        let top = content.isFlipped ? frame.minY : content.bounds.height - frame.maxY
        return ["windowNumber": window.windowNumber, "x": frame.minX, "y": top, "width": frame.width, "height": frame.height]
      }.runOnQueue(.main)
    }
  }
}

public protocol ACPagerSurface: AnyObject {
  var pageWidth: Double { get }
  var surfaceWindow: NSWindow? { get }
  func pagerMoved(_ position: Double)
  func pagerChanged(_ event: [String: Any])
}

final class SwipeArea: ExpoView, ACSwipeTarget, ACPagerSurface {
  let onSwipe = EventDispatcher()
  let onPagerPosition = EventDispatcher()
  let onPagerState = EventDispatcher()
  var canSwipeBack = false
  var canSwipeForward = false
  var tracksUnavailableDirections = false
  var allowsVerticalMotion = false
  @objc var isPager = false
  @objc var coversPage = false
  private(set) var pager: ACPager?
  private var pagerWidth: CGFloat = 0

  @objc var hasNativePager: Bool { pager != nil }

  var pageWidth: Double { Double(pagerWidth > 0 ? pagerWidth : bounds.width) }
  var surfaceWindow: NSWindow? { window }

  func pagerMoved(_ position: Double) {
    onPagerPosition(["position": position])
  }

  func pagerChanged(_ event: [String: Any]) {
    onPagerState(event)
  }

  override func hitTest(_ point: NSPoint) -> NSView? { nil }

  override func viewDidMoveToWindow() {
    super.viewDidMoveToWindow()
    if window != nil { ACSwipe.addTarget(self) } else { ACSwipe.removeTarget(self) }
  }

  deinit {
    if let pager { DispatchQueue.main.async { pager.prune() } }
  }

  func swipeEvent(_ event: [String: Any]) {
    onSwipe(event)
  }

  @objc(pagerInput:distance:direction:timestamp:)
  func pagerInput(_ phase: String, distance: CGFloat, direction: Int32, timestamp: TimeInterval) {
    pager?.input(from: self, phase: phase, distance: Double(distance), direction: Int(direction), timestamp: timestamp)
  }

  #if SOLARA_PROBES
  @objc func cancelProbeSwipe() { pager?.cancelProbeSwipe(from: self) }
  #endif

  func configurePager(_ value: [String: Any]?) {
    guard let value, let key = value["key"] as? String else {
      let old = pager
      pager = nil
      old?.detach(self)
      return
    }
    if pager?.key != key {
      pager?.detach(self)
      pager = ACPager.named(key)
      pager!.attach(self)
    }
    pagerWidth = CGFloat(number(value["width"]) ?? 0)
    pager!.configure(
      selected: Int(number(value["selected"]) ?? 0),
      count: Int(number(value["count"]) ?? 1),
      ack: Int(number(value["ack"]) ?? 0),
      order: value["order"] as? String
    )
  }
}

private let pagerActivity = Notification.Name("SolaraPagerActivity")
private let pagerPosition = Notification.Name("SolaraPagerPosition")

private func number(_ value: Any?) -> Double? {
  switch value {
  case let v as Double: return v
  case let v as Int: return Double(v)
  case let v as NSNumber: return v.doubleValue
  default: return nil
  }
}

private let trackingScale = 0.5
private let rubberDimension = 255.0
private let rubberCoefficient = 0.15
private let flickVelocity = 5.0
private let omega = 2 * Double.pi / 0.25
private let restDisplacement = 0.003
private let restSpeed = 0.1
private let historyWindow = 0.1
private let linkStall = 0.05

private func rubberBand(_ value: Double, _ dimension: Double) -> Double {
  (1 - 1 / (value * rubberCoefficient / dimension + 1)) * dimension
}

private final class ACPagerFrames: NSObject {
  weak var pager: ACPager?
  let generation: Int

  init(_ pager: ACPager, generation: Int) {
    self.pager = pager
    self.generation = generation
  }

  @objc func frame(_ link: CADisplayLink) {
    guard let pager, pager.frame(generation: generation, fromLink: true) else { return link.invalidate() }
  }
}

public final class ACPager {
  enum Phase: String { case idle, tracking, holding, settling }

  private struct Drag {
    var start = 0.0, lo = 0, hi = 0, home = 0, detent = 0
    weak var area: AnyObject?
  }

  private struct Spring {
    let from: Double
    let target: Int
    let velocity: Double
    let start: CFTimeInterval
  }

  private static var pagers: [String: ACPager] = [:]
  private static let lock = NSLock()
  private static var snapshots: [String: [String: Any]] = [:]
  private static var counter = 0

  public static func named(_ key: String) -> ACPager {
    if let pager = pagers[key] { return pager }
    let pager = ACPager(key: key)
    pagers[key] = pager
    return pager
  }

  public static func existing(_ key: String) -> ACPager? { pagers[key] }

  public static func snapshot(_ key: String) -> [String: Any]? {
    lock.lock()
    defer { lock.unlock() }
    return snapshots[key]
  }

  public let key: String
  private let areas = NSHashTable<AnyObject>.weakObjects()
  private var configured = false
  private var count = 1
  private var order: String?
  private var orderIds: [String]?
  private var selected = 0
  private var position = 0.0
  private var velocity = 0.0
  private var phase = Phase.idle
  private var sequence = 0
  private var selectionSequence = 0
  private var propSelected = 0
  private var propAck = 0
  private var drag = Drag()
  #if SOLARA_PROBES
  private weak var probeArea: AnyObject?
  #endif
  private var history: [(time: TimeInterval, position: Double)] = []
  private var spring: Spring?
  private var link: CADisplayLink?
  private var lastLinkFrame: CFTimeInterval = 0
  private var timer: Timer?
  private var generation = 0
  #if DEBUG
  private var lastInput: [String: Any] = [:]
  #endif

  private init(key: String) { self.key = key }

  private var surfaces: [ACPagerSurface] { areas.allObjects.compactMap { $0 as? ACPagerSurface } }

  public func attach(_ area: ACPagerSurface) {
    areas.add(area)
    if configured { area.pagerMoved(position) }
  }

  public func detach(_ area: ACPagerSurface) {
    areas.remove(area)
    prune()
  }

  func prune() {
    guard areas.allObjects.isEmpty, ACPager.pagers[key] === self else { return }
    stopSpring()
    ACPager.pagers[key] = nil
    ACPager.lock.lock()
    ACPager.snapshots[key] = nil
    ACPager.lock.unlock()
  }

  public func configure(selected newSelected: Int, count newCount: Int, ack: Int, order newOrder: String?) {
    let count = max(1, newCount)
    propSelected = min(max(newSelected, 0), count - 1)
    propAck = max(propAck, ack)
    if !configured {
      configured = true
      self.count = count
      setOrder(newOrder)
      selected = propSelected
      position = Double(selected)
      sequence = ACPager.next()
      publish()
      emitPosition()
      return
    }
    if count != self.count || (newOrder != nil && newOrder != order) {
      var index = propSelected
      let old = orderIds
      self.count = count
      setOrder(newOrder)
      if propAck < selectionSequence, let old, selected < old.count, let moved = orderIds?.firstIndex(of: old[selected]) {
        index = moved
      }
      cancelMotion()
      jump(to: index)
      return
    }
    reconcile()
  }

  private func setOrder(_ newOrder: String?) {
    order = newOrder
    orderIds = newOrder?.components(separatedBy: "\n")
  }

  private func reconcile() {
    guard phase == .idle, propAck >= selectionSequence, propSelected != selected else { return }
    jump(to: propSelected)
  }

  private func jump(to index: Int, selection: Bool = false) {
    announceActivity()
    selected = index
    position = Double(index)
    velocity = 0
    sequence = ACPager.next()
    if selection { selectionSequence = sequence }
    publish()
    emitPosition()
  }

  public func input(from area: ACPagerSurface, phase input: String, distance: Double, direction: Int, timestamp: TimeInterval) {
    #if SOLARA_PROBES
    probeArea = ACSwipe.probeDelivery ? area : nil
    #endif
    #if DEBUG
    lastInput = ["phase": input, "distance": distance, "direction": direction, "timestamp": timestamp]
    #endif
    switch input {
    case "prepare":
      announceActivity(["seconds": 1, "speculative": true])
      if phase == .settling {
        stopSpring()
        phase = .holding
        publish()
      }
    case "abandon":
      if phase == .holding {
        settle(to: selected, velocity: 0)
      } else if phase == .tracking, drag.area === area {
        release(velocity: 0, cancelled: false)
      } else {
        announceActivity(["release": true])
      }
    case "began":
      begin(area)
      track(distance, direction, timestamp, sample: true)
    case "changed":
      guard phase == .tracking, drag.area === area else { return }
      track(distance, direction, timestamp, sample: true)
    case "ended", "cancelled":
      guard phase == .tracking, drag.area === area else { return }
      track(distance, direction, timestamp, sample: false)
      release(velocity: releaseVelocity(at: timestamp), cancelled: input == "cancelled")
    default:
      break
    }
  }

  private func begin(_ area: ACPagerSurface) {
    announceActivity()
    stopSpring()
    let home = selected
    let x = position
    let lo = max(0, min(home - 1, Int(x.rounded(.down))))
    let hi = min(count - 1, max(home + 1, Int(x.rounded(.up))))
    drag = Drag(start: x, lo: lo, hi: hi, home: home, detent: min(max(Int(x.rounded()), lo), hi), area: area)
    history = []
    velocity = 0
    phase = .tracking
    sequence = ACPager.next()
    publish()
    emitState("began")
  }

  private func track(_ distance: Double, _ direction: Int, _ timestamp: TimeInterval, sample: Bool) {
    guard let area = drag.area as? ACPagerSurface else { return }
    let width = area.pageWidth
    guard width > 0 else { return }
    let raw = drag.start + Double(direction > 0 ? -1 : 1) * distance * trackingScale / width
    let lo = Double(drag.lo), hi = Double(drag.hi)
    let x = raw > hi ? hi + rubberBand((raw - hi) * width, rubberDimension) / width
      : raw < lo ? lo - rubberBand((lo - raw) * width, rubberDimension) / width
      : raw
    position = x
    if sample {
      let time = max(timestamp, history.last?.time ?? timestamp)
      history.append((time, x))
      history.removeAll { time - $0.time > historyWindow }
    }
    let nearest = min(max(Int(x.rounded()), drag.lo), drag.hi)
    if nearest != drag.detent {
      drag.detent = nearest
      ACSwipe.performHaptic("alignment")
    }
    publish()
    emitPosition()
  }

  #if SOLARA_PROBES
  func cancelProbeSwipe(from area: ACPagerSurface) {
    guard probeArea === area else { return }
    probeArea = nil
    stopSpring()
    drag = Drag()
    history = []
    position = Double(selected)
    velocity = 0
    phase = .idle
    publish()
  }
  #endif

  private func releaseVelocity(at timestamp: TimeInterval) -> Double {
    let recent = history.filter { timestamp - $0.time <= historyWindow }
    guard recent.count >= 2, let first = recent.first, let last = recent.last, last.time > first.time else { return 0 }
    return (last.position - first.position) / (last.time - first.time)
  }

  private func release(velocity v: Double, cancelled: Bool) {
    let home = drag.home
    let area = drag.area as? ACPagerSurface
    let width = area?.pageWidth ?? 0
    drag.area = nil
    var target = home
    if !cancelled {
      let flick = abs(v * width) >= flickVelocity
      target = !flick ? Int(position.rounded()) : v > 0 ? Int(position.rounded(.down)) + 1 : Int(position.rounded(.up)) - 1
      target = max(0, home - 1, min(count - 1, home + 1, target))
    }
    settle(to: target, velocity: towards(target, v), from: area)
  }

  private func towards(_ target: Int, _ v: Double) -> Double {
    let d = Double(target) - position
    return d != 0 && v != 0 && (d > 0) == (v > 0) ? v : 0
  }

  public func switchTo(_ index: Int, order newOrder: String? = nil) -> Bool {
    guard configured else { return false }
    sync(order: newOrder)
    let target = min(max(index, 0), count - 1)
    drag.area = nil
    let v = phase == .settling ? velocity : 0
    settle(to: target, velocity: towards(target, v))
    return true
  }

  private func sync(order newOrder: String?) {
    guard let newOrder, newOrder != order else { return }
    let ids = newOrder.components(separatedBy: "\n")
    guard !ids.isEmpty else { return }
    let current = orderIds.flatMap { selected < $0.count ? $0[selected] : nil }
    let id = current.flatMap { ids.contains($0) ? $0 : nil } ?? ids[min(max(propSelected, 0), ids.count - 1)]
    _ = select(id, order: newOrder)
  }

  public func select(_ profileId: String, order newOrder: String) -> Bool {
    guard configured else { return false }
    let ids = newOrder.components(separatedBy: "\n")
    guard let index = ids.firstIndex(of: profileId) else { return false }
    cancelMotion()
    count = ids.count
    setOrder(newOrder)
    jump(to: index, selection: true)
    emitState("selected")
    return true
  }

  public func step(_ delta: Int, wrap: Bool, order newOrder: String? = nil) -> Bool {
    guard configured else { return false }
    sync(order: newOrder)
    let target = wrap ? ((selected + delta) % count + count) % count : min(max(selected + delta, 0), count - 1)
    return target == selected || switchTo(target)
  }

  private func settle(to target: Int, velocity v: Double, from origin: ACPagerSurface? = nil) {
    announceActivity()
    if target != selected {
      selected = target
      sequence = ACPager.next()
      selectionSequence = sequence
      publish()
      emitState("selected")
    }
    stopSpring()
    phase = .settling
    velocity = v
    spring = Spring(from: position, target: target, velocity: v, start: CACurrentMediaTime())
    let generation = self.generation
    if let screen = origin?.surfaceWindow?.screen ?? surfaces.lazy.compactMap({ $0.surfaceWindow?.screen }).first {
      let link = screen.displayLink(target: ACPagerFrames(self, generation: generation), selector: #selector(ACPagerFrames.frame(_:)))
      let fps = Float(max(60, screen.maximumFramesPerSecond))
      link.preferredFrameRateRange = CAFrameRateRange(minimum: 60, maximum: fps, preferred: fps)
      link.add(to: .main, forMode: .common)
      self.link = link
      lastLinkFrame = CACurrentMediaTime()
    }
    let timer = Timer(timeInterval: 1.0 / 60, repeats: true) { [weak self] timer in
      guard let self else { return timer.invalidate() }
      if self.link != nil, CACurrentMediaTime() - self.lastLinkFrame < linkStall { return }
      if !self.frame(generation: generation) { timer.invalidate() }
    }
    RunLoop.main.add(timer, forMode: .common)
    self.timer = timer
    publish()
  }

  fileprivate func frame(generation: Int, fromLink: Bool = false) -> Bool {
    guard generation == self.generation, spring != nil else { return false }
    if fromLink { lastLinkFrame = CACurrentMediaTime() }
    step()
    return generation == self.generation
  }

  private func step() {
    guard let s = spring else { return }
    let t = CACurrentMediaTime() - s.start
    let x0 = s.from - Double(s.target)
    let b = s.velocity + omega * x0
    let decay = exp(-omega * t)
    let x = (x0 + b * t) * decay
    let v = (s.velocity - omega * b * t) * decay
    if abs(x) < restDisplacement && abs(v) < restSpeed {
      stopSpring()
      position = Double(s.target)
      velocity = 0
      phase = .idle
      sequence = ACPager.next()
      publish()
      emitPosition()
      emitState("settled")
      reconcile()
      return
    }
    position = Double(s.target) + x
    velocity = v
    publish()
    emitPosition()
  }

  private func stopSpring() {
    generation += 1
    link?.invalidate()
    link = nil
    timer?.invalidate()
    timer = nil
    spring = nil
  }

  private func cancelMotion() {
    stopSpring()
    drag.area = nil
    phase = .idle
    velocity = 0
  }

  private static func next() -> Int {
    counter += 1
    return counter
  }

  private func emitPosition() {
    let area = phase == .tracking ? drag.area as? ACPagerSurface : nil
    let all = surfaces
    (area ?? all.first { $0.surfaceWindow != nil } ?? all.first)?.pagerMoved(position)
    NotificationCenter.default.post(name: pagerPosition, object: nil, userInfo: ["key": key, "position": position])
  }

  private func emitState(_ name: String) {
    var event: [String: Any] = ["phase": name, "sequence": sequence, "position": position, "selected": selected, "velocity": velocity]
    if orderIds != nil { event["profileId"] = selectedId }
    for area in surfaces { area.pagerChanged(event) }
  }

  private func announceActivity(_ info: [String: Any] = [:]) {
    var windows: [NSWindow] = []
    for case let window? in surfaces.map(\.surfaceWindow) where !windows.contains(where: { $0 === window }) { windows.append(window) }
    for window in windows { NotificationCenter.default.post(name: pagerActivity, object: window, userInfo: info) }
  }

  private func publish() {
    var state: [String: Any] = [
      "sequence": sequence, "selectionSequence": selectionSequence, "position": position, "selected": selected,
      "phase": phase.rawValue, "velocity": velocity, "count": count,
    ]
    if orderIds != nil { state["profileId"] = selectedId }
    ACPager.lock.lock()
    ACPager.snapshots[key] = state
    ACPager.lock.unlock()
  }

  private var selectedId: Any {
    guard let ids = orderIds, selected >= 0, selected < ids.count else { return NSNull() }
    return ids[selected]
  }

  #if DEBUG
  func debug() -> [String: Any] {
    var out = ACPager.snapshot(key) ?? [:]
    out["areas"] = areas.allObjects.count
    out["propSelected"] = propSelected
    out["propAck"] = propAck
    out["history"] = history.count
    out["lastInput"] = lastInput
    if phase == .tracking {
      out["drag"] = ["start": drag.start, "lo": drag.lo, "hi": drag.hi, "home": drag.home, "detent": drag.detent]
    }
    return out
  }
  #endif
}

#if SOLARA_PROBES
@MainActor
public enum SwipeInput {
  public static func perform(windowNumber: Int, x: Double, y: Double, steps: [[String: Any]], ignorePreference: Bool,
    shouldContinue: @escaping () -> Bool, completion: @escaping ([String: Any]) -> Void) -> () -> Void {
    guard let window = NSApp.window(withWindowNumber: windowNumber) else {
      completion(["error": "windowGone"])
      return {}
    }
    var cancel: (() -> Void)?
    var completed = false
    let stop = ACSwipe.simulate(in: window, point: NSPoint(x: x, y: y), steps: steps, ignoreSystemPreference: ignorePreference,
      shouldContinue: { MainActor.assumeIsolated { shouldContinue() } }) { result in
      MainActor.assumeIsolated {
        defer { completed = true; cancel = nil }
        guard shouldContinue(), result["error"] == nil else {
          if result["error"] == nil, let cancel { cancel() }
          else { completion(["error": "testHooksDenied"]) }
          return
        }
        SwipeRead.record(result)
        completion(["where": result["where"] ?? [:], "eventCount": (result["events"] as? [Any])?.count ?? 0])
      }
    }
    if !completed { cancel = stop }
    return stop
  }
}
#endif

#if SOLARA_PROBES
@MainActor
public enum SwipeRead {
  private static var count = 0
  private static var whereHit: [String: Any] = [:]
  private struct CompletedTrace {
    let sequence: Int
    let startNs: String
    let completedNs: String
    let whereHit: [String: Any]
    let events: [[String: Any]]
    let acks: [[String: Any]]

    var metadata: [String: Any] {
      ["startNs": startNs, "sequence": sequence, "completedNs": completedNs]
    }
  }
  private static var completedTraces: [CompletedTrace] = []

  public static func snapshot(tracePage: Int? = nil, traceStartNs: String? = nil, traceSequence: Int? = nil) -> [String: Any] {
    let selected: CompletedTrace?
    if let traceStartNs {
      selected = completedTraces.last { $0.startNs == traceStartNs && (traceSequence == nil || $0.sequence == traceSequence) }
    } else if traceSequence != nil {
      selected = nil
    } else {
      selected = completedTraces.last
    }
    var result: [String: Any] = ["count": count, "where": whereHit, "trace": NSNull(),
      "completedTraces": completedTraces.map(\.metadata),
      "traceAbsent": (traceStartNs != nil || traceSequence != nil) && selected == nil]
    guard let page = tracePage, (0..<32).contains(page), let trace = selected else { return result }
    let pages = max(1, (max(trace.events.count, trace.acks.count) + 7) / 8)
    result["trace"] = ["page": page, "pageCount": pages, "eventCount": trace.events.count, "ackCount": trace.acks.count,
      "startNs": trace.startNs, "sequence": trace.sequence, "completedNs": trace.completedNs, "where": trace.whereHit,
      "events": Array(trace.events.dropFirst(page * 8).prefix(8)), "acks": Array(trace.acks.dropFirst(page * 8).prefix(8))]
    return result
  }

  public static func pager(windowId: String) -> [String: Any]? {
    guard let state = ACPager.existing(windowId)?.debug() else { return nil }
    var result: [String: Any] = [:]
    for key in ["profileId", "count", "selected", "position", "phase", "selectionSequence", "areas", "propAck"] {
      if let value = state[key] { result[key] = value }
    }
    return result
  }
  public static var haptics: [String: Any] { ACSwipe.hapticSnapshot }

  @discardableResult
  static func record(_ value: Any) -> [String: Any]? {
    guard var result = value as? [String: Any], let whereValue = result["where"] as? [String: Any],
      let startNs = (result["startNs"] as? NSNumber)?.stringValue,
      !startNs.isEmpty, startNs.utf8.count <= 32, startNs.utf8.allSatisfy({ (48...57).contains($0) }),
      count < 9007199254740991 else { return nil }
    let completedNs = String(clock_gettime_nsec_np(CLOCK_UPTIME_RAW))
    result["startNs"] = startNs
    count += 1
    whereHit = whereValue
    var events: [[String: Any]] = []
    for event in (result["events"] as? [[String: Any]] ?? []).prefix(128) {
      var row: [String: Any] = [:]
      for key in ["phase", "time", "atMs", "lateMs", "swallowed", "monitorSwallowed", "state"] {
        if let value = event[key] { row[key] = value }
      }
      if let error = event["error"] as? String { row["error"] = String(error.prefix(512)) }
      events.append(row)
    }
    var acks: [[String: Any]] = []
    for ack in result["acks"] as? [[String: Any]] ?? [] {
      guard let diag = ack["diag"] as? String, ["begin", "emit", "hitRouting", "reject"].contains(diag), acks.count < 256 else { continue }
      var row: [String: Any] = ["diag": diag]
      for key in ["phase", "velocity", "window", "fallback", "reason"] {
        if let value = ack[key] { row[key] = value }
      }
      for key in ["raw", "hit"] {
        if let chain = ack[key] as? [[String: Any]] { row[key] = chain.prefix(16).map { ["class": $0["class"] ?? NSNull()] } }
      }
      if let targets = ack["targets"] as? [[String: Any]] {
        row["targets"] = targets.prefix(16).map { target -> [String: Any] in
          if let miss = target["miss"] as? String { return ["miss": String(miss.prefix(512))] }
          return ["miss": NSNull()]
        }
      }
      acks.append(row)
    }
    completedTraces.append(CompletedTrace(sequence: count, startNs: startNs, completedNs: completedNs,
      whereHit: whereValue, events: events, acks: acks))
    if completedTraces.count > 8 { completedTraces.removeFirst(completedTraces.count - 8) }
    return result
  }
}
#endif
