import AppKit

@MainActor
public final class ShareBand {
  public static let duration: TimeInterval = 0.18
  public var onChange: ([String: CGFloat]) -> Void = { _ in }
  public private(set) var heights: [String: CGFloat] = [:]
  private var moves: [String: (from: CGFloat, to: CGFloat, start: TimeInterval)] = [:]
  private var timer: Timer?
  private let clock: () -> TimeInterval
  private let ticks: Bool

  public init(clock: @escaping () -> TimeInterval = { ProcessInfo.processInfo.systemUptime }, ticks: Bool = true) {
    self.clock = clock
    self.ticks = ticks
  }

  public var isMoving: Bool { !moves.isEmpty }
  public var isTicking: Bool { timer != nil }
  var scheduledTimer: Timer? { timer }

  public func target(_ tabId: String, shown: Bool) {
    let to: CGFloat = shown ? ShareBarView.height : 0
    if let move = moves[tabId] {
      if move.to == to { return }
    } else if (heights[tabId] ?? 0) == to {
      return
    }
    moves[tabId] = (heights[tabId] ?? 0, to, clock())
    if ticks, timer == nil {
      let made = Timer(timeInterval: 1.0 / 120, repeats: true) { [weak self] timer in
        let alive = MainActor.assumeIsolated { () -> Bool in
          guard let self else { return false }
          self.step()
          return true
        }
        if !alive { timer.invalidate() }
      }
      RunLoop.main.add(made, forMode: .common)
      timer = made
    }
  }

  public static func eased(_ t: Double) -> Double {
    let u = 1 - min(max(t, 0), 1)
    return 1 - u * u * u
  }

  public func step() {
    let now = clock()
    for (tabId, move) in moves {
      let t = (now - move.start) / Self.duration
      if t >= 1 {
        moves[tabId] = nil
        heights[tabId] = move.to == 0 ? nil : move.to
      } else {
        heights[tabId] = move.from + (move.to - move.from) * CGFloat(Self.eased(t))
      }
    }
    if moves.isEmpty {
      timer?.invalidate()
      timer = nil
    }
    onChange(heights)
  }

  public func stop() {
    timer?.invalidate()
    timer = nil
    moves = [:]
  }
}

public final class ShareBandClip: NSView {
  public let bar = ShareBarView()

  public override var isFlipped: Bool { true }

  public override init(frame: NSRect) {
    super.init(frame: frame)
    wantsLayer = true
    layer?.masksToBounds = true
    addSubview(bar)
  }

  required init?(coder: NSCoder) { fatalError() }

  public override func layout() {
    super.layout()
    bar.frame = CGRect(x: 0, y: 0, width: bounds.width, height: ShareBarView.height)
  }
}
