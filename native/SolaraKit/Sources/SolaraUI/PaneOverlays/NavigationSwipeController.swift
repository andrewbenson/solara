import AppKit
import QuartzCore

public struct NavigationSwipeItem: Equatable, Sendable {
  public var title: String
  public var url: String
  public var offset: Int
  public var newTab: Bool

  public init(title: String, url: String, offset: Int, newTab: Bool = false) {
    self.title = title
    self.url = url
    self.offset = offset
    self.newTab = newTab
  }

  public var capsule: SwipeCapsuleItem { .init(title: title, url: url, newTab: newTab) }
}

public enum NavigationSwipeAction: Equatable, Sendable {
  case step(SwipeCapsuleDirection)
  case item(NavigationSwipeItem)
}

public struct NavigationSwipeInteraction {
  public private(set) var active = false
  public private(set) var direction = SwipeCapsuleDirection.back
  public private(set) var confirmed = false
  public private(set) var items: [NavigationSwipeItem] = []
  public private(set) var listShown = false
  public private(set) var selected = 0
  public private(set) var nudge = 0.0
  private var token = 0
  private var idleAt = Double.infinity
  private var dy = 0.0
  private var listY = 0.0
  public var width: Double { listShown ? 200 : confirmed ? 82 : 72 }

  public init() {}

  @discardableResult
  public mutating func begin(_ direction: SwipeCapsuleDirection) -> Int {
    invalidate()
    active = true
    self.direction = direction
    return token
  }

  public mutating func invalidate() {
    token += 1
    active = false
    confirmed = false
    items = []
    listShown = false
    selected = 0
    nudge = 0
    idleAt = .infinity
    dy = 0
    listY = 0
  }

  public mutating func receive(_ items: [NavigationSwipeItem], token: Int) {
    guard active, token == self.token else { return }
    self.items = items
  }

  public mutating func move(distance: Double, dy: Double, at time: Double) {
    guard active else { return }
    self.dy = dy
    if listShown {
      let rows = (dy - listY) / 75
      selected = max(0, min(items.count - 1, Int(floor(rows + 0.5))))
      let past = rows < 0 ? rows : rows > Double(items.count - 1) ? rows - Double(items.count - 1) : 0
      nudge = (past < 0 ? -1 : 1) * 19 * (1 - 1 / (0.1 * abs(past) * 75 + 1))
    } else {
      confirmed = distance >= 75
      idleAt = confirmed ? time + 0.3 : .infinity
    }
  }

  public mutating func expand(at time: Double, height: Double) {
    guard active, confirmed, !listShown, time >= idleAt, items.count >= 2 else { return }
    let fit = max(2, Int(floor((height / 2 + 19 - 8 - 8) / 38)))
    items = Array(items.prefix(fit))
    listShown = true
    listY = dy
  }

  public mutating func end(cancelled: Bool) -> NavigationSwipeAction? {
    guard active else { return nil }
    let action: NavigationSwipeAction? = cancelled ? nil : listShown ? .item(items[selected]) : confirmed ? .step(direction) : nil
    invalidate()
    return action
  }

  public static func offset(distance: Double, width: Double) -> Double {
    let limit = width + 14
    let raw = max(0, distance / 75) * limit
    return (raw <= limit ? raw : limit + (1 - 1 / ((raw - limit) * 0.15 / limit + 1)) * limit) - width
  }
}

@MainActor
public final class NavigationSwipeController {
  public let capsule = SwipeCapsuleView(frame: .zero)
  public var loadHistory: ((SwipeCapsuleDirection, @escaping ([NavigationSwipeItem]) -> Void) -> Void)?
  public var navigate: ((NavigationSwipeAction) -> Void)?
  public var isCurrent: (() -> Bool)?
  public var onVerticalMotion: ((Bool) -> Void)?
  public var theme = SwipeCapsuleTheme(dark: false, textPrimary: "#000000D9", textSecondary: "#00000080")
  public var profileId = ""
  private var interaction = NavigationSwipeInteraction()
  private var idle: DispatchWorkItem?

  public init() {}

  public func stop() {
    idle?.cancel()
    idle = nil
    interaction.invalidate()
    onVerticalMotion?(false)
    capsule.dismiss()
  }

  public func input(phase: String, direction: SwipeCapsuleDirection, distance: Double, dy: Double) {
    guard isCurrent?() == true else { return stop() }
    let now = CACurrentMediaTime()
    if phase == "began" || phase == "swipe" {
      stop()
      let token = interaction.begin(direction)
      capsule.show(direction, theme: theme, profileId: profileId)
      loadHistory?(direction) { [weak self] items in
        guard let self, self.isCurrent?() == true else { return }
        self.interaction.receive(items, token: token)
        self.expand()
      }
    }
    guard interaction.active else { return }
    if phase == "cancelled" || phase == "ended" || phase == "swipe" {
      if phase == "swipe" {
        interaction.move(distance: 75, dy: dy, at: now)
        capsule.setConfirmed(true)
        capsule.move(x: 14)
      }
      let action = interaction.end(cancelled: phase == "cancelled")
      idle?.cancel()
      idle = nil
      onVerticalMotion?(false)
      capsule.dismiss(delay: phase == "swipe" ? 0.12 : 0)
      if let action, isCurrent?() == true { navigate?(action) }
      return
    }
    interaction.move(distance: distance, dy: dy, at: now)
    capsule.setConfirmed(interaction.confirmed)
    capsule.select(interaction.selected)
    capsule.move(x: NavigationSwipeInteraction.offset(distance: distance, width: interaction.width), nudge: interaction.nudge)
    idle?.cancel()
    guard interaction.confirmed, !interaction.listShown else { return }
    let task = DispatchWorkItem { [weak self] in MainActor.assumeIsolated { self?.expand() } }
    idle = task
    DispatchQueue.main.asyncAfter(deadline: .now() + 0.3, execute: task)
  }

  private func expand() {
    guard isCurrent?() == true else { return stop() }
    let wasShown = interaction.listShown
    interaction.expand(at: CACurrentMediaTime(), height: capsule.bounds.height)
    guard interaction.listShown, !wasShown else { return }
    capsule.presentList(interaction.items.map(\.capsule))
    onVerticalMotion?(true)
  }
}
