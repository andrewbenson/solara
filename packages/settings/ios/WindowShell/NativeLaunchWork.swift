import AppKit
import SolaraShell
import SolaraStore
import SolaraUI
#if DEBUG || SOLARA_PERF_TRACE
import SolaraModel
#endif

#if SOLARA_PROBES
struct NativeLaunchWorkOptions: Sendable {
  let id: String?
  let windowId: String?
  let chunks: Int?
  let milliseconds: Double?
  let holdMs: Double?
  let priority: Int?
  let deadlineMs: Double?

  init(_ values: [String: Any]) {
    id = values["id"] as? String
    windowId = values["windowId"] as? String
    chunks = values["chunks"] as? Int
    milliseconds = values["milliseconds"] as? Double
    holdMs = values["holdMs"] as? Double
    priority = values["priority"] as? Int
    deadlineMs = values["deadlineMs"] as? Double
  }
}
#endif

@MainActor
public enum NativeLaunchScheduler {
  private static var installed = false
  private static var generation: UInt64 = 1 << 63
  private static var legacy: [String: NativeLaunchReadiness] = [:]

  public static func install() {
    guard !installed else { return }
    installed = true
    NativeLaunchWork.install()
    WindowHost.prepareContent = { id, root, committed in
      generation += 1
      legacy[id]?.stop()
      let readiness = NativeLaunchReadiness(windowId: id, generation: generation, shell: root, root: root)
      readiness.coherent = { [weak root] in root.map { !$0.bounds.isEmpty } ?? false }
      readiness.guestsReady = { true }
      readiness.revision = { NativeStoreHandle.store?.rev ?? -1 }
      readiness.onStop = { [weak readiness] in
        if legacy[id] === readiness { legacy[id] = nil }
      }
      legacy[id] = readiness
      readiness.attach(committed)
      return true
    }
  }
}

@MainActor
enum NativeLaunchWork {
  static let scheduler = LaunchWorkScheduler()
  private static var installed = false
  private static var observer: CFRunLoopObserver?
  private static var eventMonitor: Any?
  private static var notifications: [NSObjectProtocol] = []
  private static var lifecycle: Int?
  private static var ownershipGeneration = 0
  private static var ownedWorkspace = false
  private static var waitingAt: Double?
  private static var slept = false
  private static var timer: Timer?
  private static let interaction = LaunchWorkInteraction()
  private static var quitting = false
  private static var admitted = false
  private static var admission: UUID?
  private static var bridgeJobs: [UUID: UUID] = [:]
  #if SOLARA_PROBES
  private static var testJobs: [String: (token: UUID, runs: Int, generation: UInt64?)] = [:]
  #endif

  static func install() {
    guard !installed else { return }
    installed = true
    #if SOLARA_PROBES
    NativeWorkCounters.launchWorkRead = { snapshot() }
    #endif
    LaunchAdmission.cancelScheduled = { token in
      if let scheduled = bridgeJobs.removeValue(forKey: token) { scheduler.cancel(scheduled) }
      wakeIfNeeded()
    }
    LaunchAdmission.schedule = { token, action in
      bridgeJobs[token] = scheduler.enqueue(id: "js.\(token)", cancelled: {
        bridgeJobs[token] = nil
        action(false)
      }) { _ in
        bridgeJobs[token] = nil
        action(true)
        return true
      }
      wakeIfNeeded()
    }
    let activity = CFRunLoopActivity.beforeWaiting.rawValue | CFRunLoopActivity.afterWaiting.rawValue
    observer = CFRunLoopObserverCreateWithHandler(nil, activity, true, 2_000_000) { _, activity in
      MainActor.assumeIsolated {
        let now = ProcessInfo.processInfo.systemUptime
        if activity == .afterWaiting {
          slept = waitingAt.map { now - $0 >= 0.001 } ?? false
          waitingAt = nil
        } else {
          updatePause()
          if slept { _ = scheduler.idleOpportunity() }
          slept = false
          wakeIfNeeded()
          waitingAt = ProcessInfo.processInfo.systemUptime
        }
      }
    }
    CFRunLoopAddObserver(CFRunLoopGetMain(), observer, .commonModes)
    eventMonitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown, .keyUp, .leftMouseDown, .leftMouseUp,
      .rightMouseDown, .rightMouseUp, .otherMouseDown, .otherMouseUp, .mouseMoved, .leftMouseDragged,
      .rightMouseDragged, .otherMouseDragged, .scrollWheel, .beginGesture, .endGesture, .magnify, .rotate, .swipe]) { event in
      input(event)
      return event
    }
    let center = NotificationCenter.default
    for name in [NSWindow.willStartLiveResizeNotification, NSWindow.didEndLiveResizeNotification] {
      notifications.append(center.addObserver(forName: name, object: nil, queue: .main) { note in
        let window = note.object as? NSWindow
        let active = note.name == NSWindow.willStartLiveResizeNotification
        MainActor.assumeIsolated {
          guard let window else { return }
          interaction.resize(window: window.windowNumber, active: active)
          wakeIfNeeded()
        }
      })
    }
    notifications.append(center.addObserver(forName: NSApplication.didResignActiveNotification, object: nil, queue: .main) { _ in
      MainActor.assumeIsolated { interaction.deactivate(); wakeIfNeeded() }
    })
    notifications.append(center.addObserver(forName: NSWindow.willCloseNotification, object: nil, queue: .main) { note in
      let window = note.object as? NSWindow
      MainActor.assumeIsolated {
        if let window { interaction.close(window: window.windowNumber) }
        wakeIfNeeded()
      }
    })
    notifications.append(center.addObserver(forName: Notification.Name("SolaraWindowKeptOnCloseChanged"), object: nil, queue: .main) { note in
      let id = note.userInfo?["id"] as? String
      let on = note.userInfo?["on"] as? Bool == true
      MainActor.assumeIsolated {
        guard let id, let window = scheduler.window(id) else { return }
        interaction.setRetained(windowId: id, generation: window.generation, on: on)
        scheduler.suspend(window, on)
        readinessChanged()
      }
    })
    for (name, stopping) in [("SolaraWillQuit", true), ("SolaraCoreQuitCancelled", false)] {
      notifications.append(center.addObserver(forName: Notification.Name(name), object: nil, queue: .main) { _ in
        MainActor.assumeIsolated {
          quitting = stopping
          if stopping { scheduler.cancelPending(); revokeAdmission() }
          readinessChanged()
        }
      })
    }
    notifications.append(center.addObserver(forName: NSApplication.willTerminateNotification, object: nil, queue: .main) { _ in
      MainActor.assumeIsolated { scheduler.quit(); revokeAdmission(); timer?.invalidate(); timer = nil }
    })
    lifecycle = NativeStoreHandle.subscribeLifecycle {
      let current = NativeStoreHandle.ownershipGeneration
      let owned = NativeStoreHandle.ownsWorkspace
      if current != ownershipGeneration || (ownedWorkspace && !owned) {
        revokeAdmission()
        scheduler.invalidateWindows()
        scheduler.cancelPending()
      }
      ownershipGeneration = current
      ownedWorkspace = owned
      readinessChanged()
    }
  }

  static func readinessChanged() {
    updatePause()
    if !scheduler.hasReadyWindow || quitting { revokeAdmission() }
    else if !admitted, admission == nil {
      admission = scheduler.enqueue(id: "native.admission", priority: 100) { _ in
        admission = nil
        guard scheduler.hasReadyWindow, !quitting else { return true }
        admitted = true
        LaunchAdmission.setAdmitted(true)
        return true
      }
    }
    wakeIfNeeded()
  }

  static func attachOwner(_ token: LaunchWorkScheduler.Window, number: Int) {
    interaction.register(windowId: token.id, generation: token.generation, number: number)
  }

  static func endOwner(_ token: LaunchWorkScheduler.Window) {
    interaction.endOwner(windowId: token.id, generation: token.generation)
    scheduler.end(token)
    readinessChanged()
  }

  private static func revokeAdmission() {
    if let admission { scheduler.cancel(admission) }
    admission = nil
    admitted = false
    LaunchAdmission.setAdmitted(false)
  }

  private static func input(_ event: NSEvent) {
    let window = event.windowNumber
    switch event.type {
    case .keyDown: interaction.hold("key.\(event.keyCode)", window: window, active: true)
    case .keyUp: interaction.hold("key.\(event.keyCode)", window: window, active: false)
    case .leftMouseDown, .rightMouseDown, .otherMouseDown: interaction.hold("mouse.\(event.buttonNumber)", window: window, active: true)
    case .leftMouseUp, .rightMouseUp, .otherMouseUp: interaction.hold("mouse.\(event.buttonNumber)", window: window, active: false)
    case .beginGesture: interaction.hold("gesture", window: window, active: true)
    case .endGesture: interaction.hold("gesture", window: window, active: false)
    case .scrollWheel:
      if event.phase.contains(.began) || event.momentumPhase.contains(.began) { interaction.hold("scroll", window: window, active: true) }
      if event.phase.contains(.ended) || event.phase.contains(.cancelled) || event.momentumPhase.contains(.ended) || event.momentumPhase.contains(.cancelled) { interaction.hold("scroll", window: window, active: false) }
    default: break
    }
    interaction.activity()
    wakeIfNeeded()
  }

  private static func updatePause() {
    scheduler.paused = quitting || interaction.paused
  }

  private static func wakeIfNeeded() {
    updatePause()
    guard !quitting, !interaction.held, scheduler.hasReadyWindow, scheduler.pending > 0 else {
      timer?.invalidate()
      timer = nil
      return
    }
    guard scheduler.runnable || interaction.paused else {
      timer?.invalidate()
      timer = nil
      return
    }
    guard timer == nil else { return }
    let delay = interaction.retryDelay
    let created = Timer(timeInterval: delay, repeats: false) { _ in
      MainActor.assumeIsolated { timer = nil; updatePause() }
    }
    timer = created
    RunLoop.main.add(created, forMode: .common)
  }

  #if SOLARA_PROBES
  static func snapshot() -> [String: Any] {
    var value = scheduler.snapshot()
    value["admitted"] = admitted
    value["jobs"] = testJobs.sorted { $0.key < $1.key }.map { id, job in
      ["id": id, "runs": job.runs, "pending": scheduler.contains(job.token),
        "cancelled": !scheduler.contains(job.token) && job.runs == 0,
        "windowGeneration": job.generation.map { $0 as Any } ?? NSNull()] as [String: Any]
    }
    return value
  }

  static func dev(_ command: String, _ options: NativeLaunchWorkOptions) -> String {
    let id = options.id ?? UUID().uuidString
    switch command {
    case "queue":
      let chunks = min(100, max(1, options.chunks ?? 1))
      let milliseconds = min(2, max(0, options.milliseconds ?? 0))
      let window = options.windowId.flatMap { scheduler.window($0) }
      if let existing = testJobs[id] { scheduler.cancel(existing.token) }
      let token = scheduler.enqueue(id: id, window: window, priority: options.priority ?? 0,
        deadline: (options.deadlineMs ?? 30_000) / 1000) { deadline in
          let end = min(deadline, ProcessInfo.processInfo.systemUptime + milliseconds / 1000)
          while ProcessInfo.processInfo.systemUptime < end {}
          guard var job = testJobs[id] else { return true }
          job.runs += 1
          testJobs[id] = job
          return job.runs >= chunks
        }
      testJobs[id] = (token, 0, window?.generation)
    case "promote": if let job = testJobs[id] { scheduler.promote(job.token) }
    case "cancel": if let job = testJobs[id] { scheduler.cancel(job.token) }
    case "input": interaction.activity(quietFor: min(2000, max(0, options.holdMs ?? 120)) / 1000)
    default: break
    }
    wakeIfNeeded()
    guard let data = try? JSONSerialization.data(withJSONObject: snapshot()) else { return "null" }
    return String(data: data, encoding: .utf8) ?? "null"
  }
  #endif
}

@MainActor
final class NativeLaunchReadiness {
  let token: LaunchWorkScheduler.Window
  private weak var shell: NSView?
  private weak var root: NSView?
  private weak var ownerWindow: NSWindow?
  private weak var mountCoordinator: AnyObject?
  private var mountWatcher: LaunchMountWatcher?
  private var ownerReady = false
  private var guestReady = false
  private var committing = false
  private var stopped = false
  private var committed = false
  private var observers: [NSObjectProtocol] = []
  private var reveal: (() -> Void)?
  var coherent: (() -> Bool)?
  var guestsReady: (() -> Bool)?
  var revision: (() -> Int)?
  var onStop: (() -> Void)?

  init(windowId: String, generation: UInt64, shell: NSView, root: NSView) {
    NativeLaunchWork.install()
    token = NativeLaunchWork.scheduler.begin(windowId: windowId, generation: generation)
    self.shell = shell
    self.root = root
    observeMounting(root)
    let center = NotificationCenter.default
    for name in [Notification.Name("RCTContentDidAppearNotification"), PaneOverlays.changed] {
      observers.append(center.addObserver(forName: name, object: nil, queue: .main) { [weak self] note in
        let view = note.object as? NSView
        MainActor.assumeIsolated {
          guard let self, !self.stopped else { return }
          if let view, view === self.root {
            self.guestReady = true
            #if DEBUG || SOLARA_PERF_TRACE
            LayoutTrace.event("windowRootAppeared", self.token.id)
            #endif
          }
          DispatchQueue.main.async { [weak self] in self?.refresh() }
        }
      })
    }
    observers.append(center.addObserver(forName: NSWindow.willCloseNotification, object: nil, queue: .main) { [weak self] note in
      let window = note.object as? NSWindow
      MainActor.assumeIsolated {
        guard let self, let window, self.ownerWindow === window else { return }
        self.stop()
      }
    })
  }

  func attach(_ reveal: @escaping () -> Void) {
    guard !stopped else { return }
    ownerWindow = shell?.window
    if let number = ownerWindow?.windowNumber { NativeLaunchWork.attachOwner(token, number: number) }
    if committed { reveal(); return }
    self.reveal = reveal
    ownerReady = true
    refresh()
  }

  func refresh() {
    guard !stopped, !committed, !committing, let shell, let root, let ownerWindow,
      shell.window === ownerWindow, root.window === ownerWindow,
      NativeStoreHandle.opened, NativeStoreHandle.store != nil else { return }
    let scheduler = NativeLaunchWork.scheduler
    guard scheduler.reach(.store, window: token), ownerReady, scheduler.reach(.owner, window: token),
      !shell.bounds.isEmpty, coherent?() == true, scheduler.reach(.slots, window: token) else { return }
    #if DEBUG || SOLARA_PERF_TRACE
    LayoutTrace.event("windowSlotsReady", token.id)
    #endif
    guard guestReady, LaunchGuestReadiness.contains(in: root, windowId: token.id) else { return }
    #if DEBUG || SOLARA_PERF_TRACE
    LayoutTrace.event("windowGuestReady", token.id)
    #endif
    guard guestsReady?() != false, scheduler.reach(.guest, window: token) else { return }
    #if DEBUG || SOLARA_PERF_TRACE
    LayoutTrace.event("windowPaneGuestsReady", token.id)
    #endif
    committing = true
    FrameUpdates.flush()
    flushShellLayout(shell)
    let revision = revision?() ?? 0
    #if DEBUG || SOLARA_PERF_TRACE
    let traceWindowId = token.id
    #endif
    CATransaction.begin()
    CATransaction.setCompletionBlock { [weak self] in
      #if DEBUG || SOLARA_PERF_TRACE
      LayoutTrace.event("windowCACompleted", traceWindowId)
      #endif
      DispatchQueue.main.async {
        MainActor.assumeIsolated {
          guard let self, !self.stopped, !self.committed else { return }
          guard let shell = self.shell, let root = self.root, let ownerWindow = self.ownerWindow,
            shell.window === ownerWindow, root.window === ownerWindow else {
            self.committing = false
            return
          }
          FrameUpdates.flush()
          self.flushShellLayout(shell)
          guard shell.window === ownerWindow, root.window === ownerWindow,
            self.coherent?() == true, LaunchGuestReadiness.contains(in: root, windowId: self.token.id),
            self.guestsReady?() != false, (self.revision?() ?? 0) == revision else {
            self.committing = false
            self.refresh()
            return
          }
          guard NativeLaunchWork.scheduler.reach(.chromeCommit, window: self.token) else { return }
          if let at = NativeLaunchWork.scheduler.chromeCommittedAt { LaunchAdmission.recordChromeCommit(at) }
          self.committed = true
          self.committing = false
          self.stopMounting()
          self.reveal?()
          self.reveal = nil
          NotificationCenter.default.post(name: Notification.Name("SolaraWindowChromeCommitted"), object: shell)
          NativeLaunchWork.readinessChanged()
        }
      }
    }
    #if DEBUG || SOLARA_PERF_TRACE
    LayoutTrace.event("windowCABegin", token.id)
    #endif
    shell.displayIfNeeded()
    CATransaction.commit()
    CATransaction.flush()
  }

  func stop() {
    guard !stopped else { return }
    stopped = true
    stopMounting()
    reveal = nil
    coherent = nil
    guestsReady = nil
    revision = nil
    for observer in observers { NotificationCenter.default.removeObserver(observer) }
    observers = []
    NativeLaunchWork.endOwner(token)
    let onStop = onStop
    self.onStop = nil
    onStop?()
  }

  private func flushShellLayout(_ view: NSView) {
    #if DEBUG || SOLARA_PERF_TRACE
    let trace = LayoutTrace.begin("windowRevealShellLayout", token.id)
    defer { LayoutTrace.end(trace) }
    #endif
    if NativeWindowShell.nativeLayoutActive(token.id), let shell = view as? WindowShellView {
      #if DEBUG || SOLARA_PERF_TRACE
      LayoutTrace.event("windowRevealLayoutMode", "\(token.id) frame")
      #endif
      shell.layoutFrameIfNeeded()
    } else {
      #if DEBUG || SOLARA_PERF_TRACE
      LayoutTrace.event("windowRevealLayoutMode", "\(token.id) subtree")
      #endif
      view.layoutSubtreeIfNeeded()
    }
  }

  private func observeMounting(_ root: NSView) {
    guard root.responds(to: NSSelectorFromString("bridge")), let bridge = root.value(forKey: "bridge") as AnyObject?,
      let manager = bridge.value(forKey: "uiManager") as AnyObject?,
      let coordinator = manager.value(forKey: "observerCoordinator") as AnyObject?,
      coordinator.responds(to: NSSelectorFromString("addObserver:")) else { return }
    let watcher = LaunchMountWatcher { [weak self] in self?.refresh() }
    _ = coordinator.perform(NSSelectorFromString("addObserver:"), with: watcher)
    mountCoordinator = coordinator
    mountWatcher = watcher
  }

  private func stopMounting() {
    if let mountCoordinator, let mountWatcher {
      _ = mountCoordinator.perform(NSSelectorFromString("removeObserver:"), with: mountWatcher)
    }
    mountCoordinator = nil
    mountWatcher = nil
  }
}

@MainActor
private final class LaunchMountWatcher: NSObject {
  private let mounted: () -> Void

  init(_ mounted: @escaping () -> Void) { self.mounted = mounted }

  @objc nonisolated func uiManagerDidPerformMounting(_ manager: AnyObject) {
    DispatchQueue.main.async { [weak self] in self?.mounted() }
  }
}
