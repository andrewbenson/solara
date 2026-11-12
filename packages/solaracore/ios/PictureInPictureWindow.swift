import AppKit
import ObjectiveC

struct PictureInPictureDisplay: Equatable {
  let id: UInt32
  let frame: NSRect
  let visibleFrame: NSRect

  @MainActor static var connected: [PictureInPictureDisplay] {
    NSScreen.screens.compactMap { screen in
      guard let number = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber else { return nil }
      return PictureInPictureDisplay(id: number.uint32Value, frame: screen.frame, visibleFrame: screen.visibleFrame)
    }
  }
}

struct PictureInPicturePlacement {
  let frame: NSRect
  let display: PictureInPictureDisplay

  static func display(for frame: NSRect, displays: [PictureInPictureDisplay]) -> PictureInPictureDisplay? {
    displays.max { a, b in
      let aOverlap = frame.intersection(a.frame)
      let bOverlap = frame.intersection(b.frame)
      let aArea = aOverlap.isNull ? 0 : aOverlap.width * aOverlap.height
      let bArea = bOverlap.isNull ? 0 : bOverlap.width * bOverlap.height
      if aArea != bArea { return aArea < bArea }
      let aDistance = pow(frame.midX - a.frame.midX, 2) + pow(frame.midY - a.frame.midY, 2)
      let bDistance = pow(frame.midX - b.frame.midX, 2) + pow(frame.midY - b.frame.midY, 2)
      return aDistance == bDistance ? a.id > b.id : aDistance > bDistance
    }
  }

  func reconciled(displays: [PictureInPictureDisplay]) -> NSRect {
    let retained = displays.first { $0.id == display.id }
    guard let target = retained ?? Self.display(for: frame, displays: displays) else { return frame }
    if target.id == display.id && target.frame == display.frame { return frame }
    var next = frame
    if retained != nil {
      next.origin.x += target.frame.minX - display.frame.minX
      next.origin.y += target.frame.minY - display.frame.minY
    }
    next.origin.x = min(max(next.minX, target.visibleFrame.minX), max(target.visibleFrame.minX, target.visibleFrame.maxX - next.width))
    next.origin.y = min(max(next.minY, target.visibleFrame.minY), max(target.visibleFrame.minY, target.visibleFrame.maxY - next.height))
    return next
  }
}

private final class PictureInPictureObservations: @unchecked Sendable {
  var values: [(NotificationCenter, NSObjectProtocol)] = []

  deinit {
    for (center, token) in values { center.removeObserver(token) }
  }
}

@MainActor @objc(SolaraPictureInPictureWindow)
public final class SolaraPictureInPictureWindow: NSObject {
  private static var associationKey: UInt8 = 0
  private weak var window: NSWindow?
  private let observations = PictureInPictureObservations()
  private var displays: [PictureInPictureDisplay]
  private var placement: PictureInPicturePlacement?
  private var keepOnTop: Bool
  private var reconciling = false

  @objc(configure:keepOnTop:)
  public static func configure(_ window: NSWindow, keepOnTop: Bool) {
    if let policy = objc_getAssociatedObject(window, &associationKey) as? SolaraPictureInPictureWindow {
      policy.keepOnTop = keepOnTop
      policy.applySettings()
      return
    }
    let policy = SolaraPictureInPictureWindow(window: window, keepOnTop: keepOnTop)
    objc_setAssociatedObject(window, &associationKey, policy, .OBJC_ASSOCIATION_RETAIN_NONATOMIC)
  }

  @objc(reconcileDisplay:)
  public static func reconcileDisplay(_ window: NSWindow) {
    (objc_getAssociatedObject(window, &associationKey) as? SolaraPictureInPictureWindow)?.screensChanged()
  }

  private init(window: NSWindow, keepOnTop: Bool) {
    self.window = window
    self.keepOnTop = keepOnTop
    displays = PictureInPictureDisplay.connected
    super.init()
    rememberFrame()
    applySettings()
    for name in [NSWindow.didMoveNotification, NSWindow.didResizeNotification] {
      observe(NotificationCenter.default, name: name, object: window) { $0.rememberFrame() }
    }
    observe(NotificationCenter.default, name: NSWindow.willCloseNotification, object: window) { policy in
      guard let window = policy.window else { return }
      objc_setAssociatedObject(window, &Self.associationKey, nil, .OBJC_ASSOCIATION_RETAIN_NONATOMIC)
    }
    observe(NotificationCenter.default, name: NSApplication.didChangeScreenParametersNotification, object: nil) { $0.screensChanged() }
    observe(NotificationCenter.default, name: NSApplication.didBecomeActiveNotification, object: nil) { $0.applySettings() }
    observe(NSWorkspace.shared.notificationCenter, name: NSWorkspace.activeSpaceDidChangeNotification, object: nil) { $0.applySettings() }
  }

  private func observe(_ center: NotificationCenter, name: Notification.Name, object: AnyObject?, action: @escaping @MainActor (SolaraPictureInPictureWindow) -> Void) {
    let token = center.addObserver(forName: name, object: object, queue: .main) { [weak self] _ in
      MainActor.assumeIsolated {
        if let self { action(self) }
      }
    }
    observations.values.append((center, token))
  }

  private func applySettings() {
    guard let window else { return }
    let level: NSWindow.Level = keepOnTop ? .floating : .normal
    if window.level != level { window.level = level }
    var behavior = window.collectionBehavior
    behavior.subtract([.moveToActiveSpace, .managed, .transient, .participatesInCycle, .fullScreenPrimary, .fullScreenNone, .fullScreenAllowsTiling, .primary, .auxiliary])
    behavior.formUnion([.canJoinAllSpaces, .canJoinAllApplications, .fullScreenAuxiliary, .stationary, .ignoresCycle, .fullScreenDisallowsTiling])
    if window.collectionBehavior != behavior { window.collectionBehavior = behavior }
    window.isExcludedFromWindowsMenu = true
    window.hidesOnDeactivate = false
    window.setAccessibilityRole(.window)
    window.setAccessibilitySubrole(.floatingWindow)
  }

  private func rememberFrame() {
    guard !reconciling, let window else { return }
    let connected = PictureInPictureDisplay.connected
    guard connected.sorted(by: { $0.id < $1.id }) == displays.sorted(by: { $0.id < $1.id }),
          let display = PictureInPicturePlacement.display(for: window.frame, displays: displays) else { return }
    placement = PictureInPicturePlacement(frame: window.frame, display: display)
  }

  private func screensChanged() {
    guard let window else { return }
    reconciling = true
    displays = PictureInPictureDisplay.connected
    if let placement {
      let frame = placement.reconciled(displays: displays)
      if window.frame != frame { window.setFrame(frame, display: false) }
    }
    reconciling = false
    rememberFrame()
    applySettings()
  }
}
