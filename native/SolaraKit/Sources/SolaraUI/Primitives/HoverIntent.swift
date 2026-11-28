import AppKit
import Foundation

public enum CardReach: String, Sendable {
  case covered, aiming, away

  public static func of(card: CGRect, from: CGPoint?, to p: CGPoint) -> CardReach {
    func inside(_ r: CGRect, _ q: CGPoint) -> Bool { q.x >= r.minX && q.x <= r.maxX && q.y >= r.minY && q.y <= r.maxY }
    func side(_ a: CGPoint, _ b: CGPoint, _ q: CGPoint) -> CGFloat { (b.x - a.x) * (q.y - a.y) - (b.y - a.y) * (q.x - a.x) }
    if inside(card, p) { return .covered }
    guard let from, !inside(card, from) else { return .away }
    let rightward = from.x <= card.minX
    let near = rightward ? card.minX : card.maxX
    if rightward ? p.x < from.x : p.x > from.x { return .away }
    let top = CGPoint(x: near, y: card.minY)
    let bottom = CGPoint(x: near, y: card.maxY)
    let a = side(from, top, p)
    let b = side(top, bottom, p)
    let c = side(bottom, from, p)
    return (a < 0 || b < 0 || c < 0) && (a > 0 || b > 0 || c > 0) ? .away : .aiming
  }
}

@MainActor
public final class HoverIntent {
  nonisolated public static let showDelay: TimeInterval = 0.5
  nonisolated public static let hideDelay: TimeInterval = 0.16
  nonisolated public static let aimDelay: TimeInterval = 0.2

  public var onShow: ((String) -> Void)?
  public var onHide: (() -> Void)?
  public var cardFrame: CGRect?
  public private(set) var shown: String?
  public private(set) var onCard = false
  public var suppressed = false { didSet { if suppressed { dismiss() } } }

  private var owner: String?
  private var exitPoint: CGPoint?
  private var waiting: String??
  private var held = false
  private(set) var showTimer: Timer?
  private(set) var hideTimer: Timer?
  private var aimTimer: Timer?
  private var ticket = 0

  public init() {}

  public func rowEntered(_ id: String, at point: CGPoint?) {
    if let point, onCard, let card = cardFrame, !card.contains(point) { onCard = false }
    if let shown, shown != id, let card = cardFrame, let point {
      let reach = CardReach.of(card: card, from: exitPoint, to: point)
      if reach != .away {
        hold(id)
        return
      }
    }
    enter(id)
  }

  public func rowLeft(_ id: String, at point: CGPoint?) {
    if case .some(.some(let pending)) = waiting, pending == id { waiting = nil }
    if shown == id { exitPoint = point }
    leave(from: id)
  }

  public func cardEntered() {
    guard shown != nil else { return }
    onCard = true
    aimTimer?.invalidate()
    keep()
  }

  public func cardLeft() {
    onCard = false
    let pending = waiting
    waiting = nil
    arrive(pending)
  }

  public func enter(_ id: String) {
    guard !suppressed else { return }
    showTimer?.invalidate()
    hideTimer?.invalidate()
    aimTimer?.invalidate()
    waiting = nil
    owner = id
    if shown == id { return }
    ticket += 1
    let mine = ticket
    if shown != nil { show(id, mine) } else { showTimer = schedule(Self.showDelay) { [weak self] in self?.show(id, mine) } }
  }

  public func leave(from id: String? = nil) {
    if held { return }
    if let id, id != owner { return }
    owner = nil
    ticket += 1
    showTimer?.invalidate()
    hideTimer?.invalidate()
    hideTimer = schedule(Self.hideDelay) { [weak self] in self?.hideCard() }
  }

  public func keep() {
    hideTimer?.invalidate()
    aimTimer?.invalidate()
  }

  public func hold(_ on: Bool) {
    guard on != held else { return }
    held = on
    if on { return keep() }
    guard let shown, !onCard else { return }
    if owner != shown { leave() }
  }

  public func dismiss() {
    held = false
    owner = nil
    ticket += 1
    showTimer?.invalidate()
    hideTimer?.invalidate()
    if shown != nil { hideCard() }
  }

  private func hold(_ id: String) {
    waiting = .some(id)
    hideTimer?.invalidate()
    aimTimer?.invalidate()
    aimTimer = schedule(Self.aimDelay) { [weak self] in
      guard let self, !self.onCard else { return }
      let pending = self.waiting
      self.waiting = nil
      self.arrive(pending)
    }
  }

  private func arrive(_ pending: String??) {
    guard case .some(.some(let id)) = pending else { return leave() }
    enter(id)
  }

  private func show(_ id: String, _ mine: Int) {
    guard mine == ticket, !suppressed else { return }
    if onCard && shown != nil { return }
    exitPoint = nil
    shown = id
    onShow?(id)
  }

  private func hideCard() {
    held = false
    onCard = false
    exitPoint = nil
    waiting = nil
    aimTimer?.invalidate()
    guard shown != nil else { return }
    shown = nil
    onHide?()
  }

  private func schedule(_ delay: TimeInterval, _ body: @escaping @MainActor () -> Void) -> Timer {
    let timer = Timer(timeInterval: delay, repeats: false) { _ in MainActor.assumeIsolated { body() } }
    RunLoop.main.add(timer, forMode: .common)
    return timer
  }
}
