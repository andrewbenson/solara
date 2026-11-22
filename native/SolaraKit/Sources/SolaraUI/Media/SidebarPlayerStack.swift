import AppKit
import QuartzCore

public enum MediaStackGeometry {
  public static let peek: CGFloat = 7
  public static let gap: CGFloat = 8
  public static let shrink: CGFloat = 0.04
  public static let openDelay: TimeInterval = 0.15
  public static let closeDelay: TimeInterval = 0.4
  public static let rise: TimeInterval = 0.28
  public static let stagger: TimeInterval = 0.03
  public static let contentFade: TimeInterval = 0.16
  public static let slideOut: TimeInterval = 0.2
  public static let slideDistance: CGFloat = 24
  public static let crossfade: TimeInterval = 0.12
  public static var curve: CAMediaTimingFunction { CAMediaTimingFunction(controlPoints: 0.2, 0.9, 0.25, 1) }

  public static func collapsedHeight(count: Int) -> CGFloat {
    count == 0 ? 0 : SidebarPlayerView.height + peek * CGFloat(min(count, MediaStack.limit) - 1)
  }

  public static func openHeight(count: Int) -> CGFloat {
    count == 0 ? 0 : CGFloat(count) * SidebarPlayerView.height + CGFloat(count - 1) * gap
  }

  public static var frameHeight: CGFloat { openHeight(count: MediaStack.limit) }

  public static func frames(count: Int, width: CGFloat, open: Bool, bottom: CGFloat? = nil) -> [CGRect] {
    let height = SidebarPlayerView.height
    let bottom = bottom ?? openHeight(count: count)
    return (0..<count).map { i in
      if open { return CGRect(x: 0, y: bottom - height - CGFloat(i) * (height + gap), width: width, height: height) }
      let w = width * (1 - shrink * CGFloat(i))
      return CGRect(x: (width - w) / 2, y: bottom - height - peek * CGFloat(i), width: w, height: height)
    }
  }
}

public final class SidebarPlayerStack: NSView {
  public var onAction: ((String, MediaAction) -> Void)?
  public var onScroll: ((NSEvent) -> Void)?
  public var backdrop: NSColor? {
    didSet {
      guard backdrop != oldValue else { return }
      if oldValue != nil, window != nil, !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion {
        for card in cards {
          let fade = CATransition()
          fade.type = .fade
          fade.duration = Self.backdropFade
          card.view.layer?.add(fade, forKey: "backdrop")
        }
      }
      cards.forEach { $0.view.backdrop = backdrop }
    }
  }
  static let backdropFade: TimeInterval = 0.2

  private struct Card {
    let tabId: String
    let view: SidebarPlayerView
  }

  private var cards: [Card] = []
  private var leaving: [SidebarPlayerView] = []
  private(set) public var isOpen = false
  private var openTimer: Timer?
  private var closeTimer: Timer?
  private var pointerOn: Set<ObjectIdentifier> = []
  private var keyMonitor: Any?
  private let more = NSTextField(labelWithString: "")
  private var resting = CGRect.zero

  public override var isFlipped: Bool { true }

  public override init(frame: NSRect) {
    super.init(frame: frame)
    wantsLayer = true
    more.font = .systemFont(ofSize: 10.5, weight: .semibold)
    more.alignment = .right
    more.isHidden = true
    addSubview(more)
  }

  required init?(coder: NSCoder) { fatalError() }

  public var tabIds: [String] { cards.map(\.tabId) }
  public var cardViews: [SidebarPlayerView] { cards.map(\.view) }
  public var leavingViews: [SidebarPlayerView] { leaving }
  private var laidOutWidth: CGFloat = 0

  public override func hitTest(_ point: NSPoint) -> NSView? {
    guard !isHidden, alphaValue > 0 else { return nil }
    let local = convert(point, from: superview)
    for card in cards {
      if let hit = card.view.hitTest(local) { return hit }
    }
    return nil
  }

  public func place(resting frame: CGRect) {
    resting = frame
    applyFrame()
  }

  private func applyFrame() {
    let tall = max(MediaStackGeometry.frameHeight, MediaStackGeometry.openHeight(count: cards.count))
    let target = CGRect(x: resting.minX, y: resting.maxY - tall, width: resting.width, height: tall)
    if frame != target { frame = target }
  }

  public func update(_ players: [MediaPlayerState]) {
    let ids = players.map(\.tabId)
    let reduce = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
    for card in cards where !ids.contains(card.tabId) { leave(card.view, reduce: reduce) }
    var next: [Card] = []
    var arrived: [SidebarPlayerView] = []
    for state in players {
      if let card = cards.first(where: { $0.tabId == state.tabId }) {
        card.view.update(state)
        next.append(card)
      } else {
        let view = makeCard()
        view.update(state)
        next.append(Card(tabId: state.tabId, view: view))
        arrived.append(view)
      }
    }
    cards = next
    if cards.count < 2, isOpen { setOpen(false, animated: false) }
    applyFrame()
    let order = leaving + cards.reversed().map(\.view) + [more]
    if subviews != order { subviews = order }
    layoutCards(animated: window != nil, reduce: reduce, arrived: Set(arrived.map(ObjectIdentifier.init)))
  }

  private func makeCard() -> SidebarPlayerView {
    let view = SidebarPlayerView(frame: .zero)
    view.backdrop = backdrop
    view.onScroll = { [weak self] in self?.onScroll?($0) }
    view.onAction = { [weak self, weak view] action in
      guard let self, let view, let tabId = self.cards.first(where: { $0.view === view })?.tabId else { return }
      self.onAction?(tabId, action)
    }
    view.onPointer = { [weak self, weak view] on in
      guard let self, let view else { return }
      self.pointer(on, card: view)
    }
    view.onPeekPress = { [weak self] in self?.setOpen(true, animated: true) }
    addSubview(view, positioned: .below, relativeTo: more)
    return view
  }

  private func leave(_ view: SidebarPlayerView, reduce: Bool) {
    leaving.append(view)
    view.leaving = true
    pointerOn.remove(ObjectIdentifier(view))
    let end = { [weak self, weak view] in
      guard let view else { return }
      view.removeFromSuperview()
      self?.leaving.removeAll { $0 === view }
    }
    if reduce || window == nil {
      NSAnimationContext.runAnimationGroup({ ctx in
        ctx.duration = window == nil ? 0 : MediaStackGeometry.crossfade
        view.animator().alphaValue = 0
      }, completionHandler: end)
      return
    }
    NSAnimationContext.runAnimationGroup({ ctx in
      ctx.duration = MediaStackGeometry.slideOut
      ctx.timingFunction = CAMediaTimingFunction(name: .easeIn)
      view.animator().frame = view.frame.offsetBy(dx: -MediaStackGeometry.slideDistance, dy: 0)
      view.animator().alphaValue = 0
    }, completionHandler: end)
  }

  private var generation = 0

  private func layoutCards(animated: Bool, reduce: Bool, arrived: Set<ObjectIdentifier> = []) {
    generation += 1
    let current = generation
    let frames = MediaStackGeometry.frames(count: cards.count, width: bounds.width, open: isOpen, bottom: bounds.height)
    for (i, card) in cards.enumerated() {
      let view = card.view
      let target = frames[i]
      let isNew = arrived.contains(ObjectIdentifier(view))
      let peeking = !isOpen && i > 0
      if isNew {
        view.frame = reduce ? target : target.offsetBy(dx: -MediaStackGeometry.slideDistance, dy: 0)
        view.alphaValue = 0
      }
      let delay = isOpen ? MediaStackGeometry.stagger * Double(i) : MediaStackGeometry.stagger * Double(cards.count - 1 - i)
      let run = { [weak self, weak view] in
        guard let self, let view, self.generation == current else { return }
        if !animated || reduce {
          NSAnimationContext.runAnimationGroup({ ctx in
            ctx.duration = animated ? MediaStackGeometry.crossfade : 0
            view.frame = target
            view.animator().alphaValue = 1
          })
          view.setPeeking(peeking, duration: animated ? MediaStackGeometry.crossfade : 0)
          return
        }
        NSAnimationContext.runAnimationGroup({ ctx in
          ctx.duration = MediaStackGeometry.rise
          ctx.timingFunction = MediaStackGeometry.curve
          ctx.allowsImplicitAnimation = true
          view.animator().frame = target
          view.animator().alphaValue = 1
        })
        view.setPeeking(peeking, duration: MediaStackGeometry.contentFade)
      }
      if animated, !reduce, delay > 0 { DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: run) } else { run() }
    }
    let extra = cards.count - 1
    more.stringValue = extra > 0 ? "+\(extra)" : ""
    more.textColor = .secondaryLabelColor
    more.sizeToFit()
    let front = frames.first ?? .zero
    let top = (frames.last ?? .zero).minY
    more.frame = CGRect(x: front.maxX - more.frame.width - 6, y: top - 2, width: more.frame.width, height: more.frame.height)
    NSAnimationContext.runAnimationGroup { ctx in
      ctx.duration = animated ? MediaStackGeometry.contentFade : 0
      more.animator().alphaValue = isOpen || extra == 0 ? 0 : 1
    }
    more.isHidden = extra == 0
  }

  private func pointer(_ on: Bool, card: SidebarPlayerView) {
    let id = ObjectIdentifier(card)
    if on { pointerOn.insert(id) } else { pointerOn.remove(id) }
    if pointerOn.isEmpty {
      openTimer?.invalidate()
      openTimer = nil
      guard isOpen, closeTimer == nil else { return }
      closeTimer = Timer.scheduledTimer(withTimeInterval: MediaStackGeometry.closeDelay, repeats: false) { [weak self] _ in
        MainActor.assumeIsolated {
          guard let self else { return }
          self.closeTimer = nil
          if self.pointerOn.isEmpty { self.setOpen(false, animated: true) }
        }
      }
    } else {
      closeTimer?.invalidate()
      closeTimer = nil
      guard !isOpen, cards.count > 1, openTimer == nil else { return }
      openTimer = Timer.scheduledTimer(withTimeInterval: MediaStackGeometry.openDelay, repeats: false) { [weak self] _ in
        MainActor.assumeIsolated {
          guard let self else { return }
          self.openTimer = nil
          if !self.pointerOn.isEmpty { self.setOpen(true, animated: true) }
        }
      }
    }
  }

  public func setOpen(_ open: Bool, animated: Bool) {
    guard open != isOpen, !open || cards.count > 1 else { return }
    isOpen = open
    openTimer?.invalidate()
    openTimer = nil
    closeTimer?.invalidate()
    closeTimer = nil
    if open {
      keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
        guard let self, event.keyCode == 53, event.window === self.window, self.isOpen else { return event }
        self.setOpen(false, animated: true)
        return nil
      }
    } else if let keyMonitor {
      NSEvent.removeMonitor(keyMonitor)
      self.keyMonitor = nil
    }
    layoutCards(animated: animated && window != nil, reduce: NSWorkspace.shared.accessibilityDisplayShouldReduceMotion)
  }

  public func coverageMoved() {
    cards.forEach { $0.view.coverageMoved() }
  }

  public override func viewWillMove(toWindow newWindow: NSWindow?) {
    super.viewWillMove(toWindow: newWindow)
    if newWindow == nil { setOpen(false, animated: false) }
  }

  public override func layout() {
    super.layout()
    guard bounds.width != laidOutWidth else { return }
    laidOutWidth = bounds.width
    guard !cards.isEmpty else { return }
    let frames = MediaStackGeometry.frames(count: cards.count, width: bounds.width, open: isOpen, bottom: bounds.height)
    for (i, card) in cards.enumerated() { card.view.frame = frames[i] }
  }

  #if DEBUG
  public var cardFrames: [CGRect] { cards.map(\.view.frame) }
  public var moreText: String { more.isHidden ? "" : more.stringValue }
  #endif
}
