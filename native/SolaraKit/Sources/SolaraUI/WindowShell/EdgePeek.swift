import Foundation

@MainActor
public final class EdgePeek {
  public static let slideMs: Double = 180
  public static let hideDelayMs: Double = 120

  public private(set) var live = false
  public private(set) var enabled: Bool
  public let arc: Bool
  public var held: () -> Bool = { false }
  public var onSlideOut: () -> Void = {}
  public var onLive: (Bool) -> Void = { _ in }
  public var animate: (_ to: Double, _ curve: DockAnimator.Curve, _ done: @escaping () -> Void) -> Void = { _, _, done in done() }
  public var schedule: (_ seconds: Double, _ run: @escaping @MainActor () -> Void) -> AnyObject? = { seconds, run in
    let item = DispatchWorkItem { MainActor.assumeIsolated { run() } }
    DispatchQueue.main.asyncAfter(deadline: .now() + seconds, execute: item)
    return item
  }
  public var cancel: (AnyObject) -> Void = { ($0 as? DispatchWorkItem)?.cancel() }

  private var hideTimer: AnyObject?
  private var heldBack = false
  private var generation = 0
  private var hideGeneration = 0
  private var stopped = false

  public init(enabled: Bool, arc: Bool) {
    self.enabled = enabled
    self.arc = arc
  }

  public static func curve(to: Double, arc: Bool) -> DockAnimator.Curve {
    if arc { return to > 0 ? .spring(.arcPeek) : .timed(duration: DockMotion.arcPeekOutMs / 1000, ease: .inOutCubic) }
    return .timed(duration: slideMs / 1000, ease: .outCubic)
  }

  public func show() {
    guard !stopped else { return }
    clearHide()
    heldBack = false
    guard enabled else { return }
    setLive(true)
    run(to: 1, done: nil)
  }

  public func hide() {
    guard !stopped else { return }
    clearHide()
    let mine = hideGeneration
    hideTimer = schedule(Self.hideDelayMs / 1000) { [weak self] in
      guard let self, !self.stopped, self.hideGeneration == mine else { return }
      self.hideTimer = nil
      self.heldBack = self.held()
      if !self.heldBack { self.slideOut() }
    }
  }

  public func recheck() {
    guard !stopped, heldBack, !held() else { return }
    heldBack = false
    hide()
  }

  public func setEnabled(_ next: Bool) {
    guard !stopped, next != enabled else { return }
    enabled = next
    guard !next else { return }
    clearHide()
    if live { slideOut() }
  }

  public func stop() {
    stopped = true
    clearHide()
    setLive(false)
    generation += 1
  }

  private func slideOut() {
    onSlideOut()
    run(to: 0) { [weak self] in self?.setLive(false) }
  }

  private func run(to target: Double, done: (() -> Void)?) {
    generation += 1
    let mine = generation
    animate(target, Self.curve(to: target, arc: arc)) { [weak self] in
      guard let self, self.generation == mine else { return }
      done?()
    }
  }

  private func setLive(_ next: Bool) {
    guard next != live else { return }
    live = next
    onLive(next)
  }

  private func clearHide() {
    hideGeneration += 1
    if let hideTimer { cancel(hideTimer) }
    hideTimer = nil
  }
}
