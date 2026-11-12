import AppKit
import Testing

@MainActor private final class AXObservingPanel: NSPanel {
  var geometryWrites = 0

  override func accessibilitySetValue(_ value: Any?, forAttribute attribute: NSAccessibility.Attribute) {
    if attribute == .position || attribute == .size { geometryWrites += 1 }
    super.accessibilitySetValue(value, forAttribute: attribute)
  }
}

@Suite @MainActor struct PictureInPictureWindowTests {
  private func panel() -> NSPanel {
    NSApplication.shared.setActivationPolicy(.prohibited)
    let panel = NSPanel(contentRect: NSRect(x: 100, y: 100, width: 320, height: 180), styleMask: [.nonactivatingPanel, .resizable], backing: .buffered, defer: true)
    panel.isReleasedWhenClosed = false
    return panel
  }

  @Test func floatingPiPJoinsOtherApplicationsAndAvoidsTiling() {
    let window = panel()
    defer { window.close() }
    window.collectionBehavior = [.moveToActiveSpace, .managed, .participatesInCycle, .fullScreenPrimary, .fullScreenAllowsTiling, .primary]
    SolaraPictureInPictureWindow.configure(window, keepOnTop: true)
    #expect(window.level == .floating)
    #expect(window.collectionBehavior.contains([.canJoinAllSpaces, .canJoinAllApplications, .fullScreenAuxiliary, .stationary, .ignoresCycle, .fullScreenDisallowsTiling]))
    #expect(window.collectionBehavior.intersection([.moveToActiveSpace, .managed, .transient, .participatesInCycle, .fullScreenPrimary, .fullScreenNone, .fullScreenAllowsTiling, .primary, .auxiliary]).isEmpty)
    #expect(window.isExcludedFromWindowsMenu)
    #expect(!window.hidesOnDeactivate)
    #expect(window.accessibilityRole() == .window)
    #expect(window.accessibilitySubrole() == .floatingWindow)
    #expect(!window.isVisible)
    #expect(!NSApp.isActive)
  }

  @Test func accessibilityGeometryRetainsAppKitPermissionsAndNativeMovement() {
    let window = panel()
    let other = panel()
    defer { window.close(); other.close() }
    let selector = NSSelectorFromString("setAccessibilityFrame:")
    let selectorAllowed = other.isAccessibilitySelectorAllowed(selector)
    let positionSettable = other.accessibilityIsAttributeSettable(.position)
    let sizeSettable = other.accessibilityIsAttributeSettable(.size)
    SolaraPictureInPictureWindow.configure(window, keepOnTop: true)
    #expect(window.isAccessibilitySelectorAllowed(selector) == selectorAllowed)
    #expect(window.accessibilityIsAttributeSettable(.position) == positionSettable)
    #expect(window.accessibilityIsAttributeSettable(.size) == sizeSettable)
    let moved = window.frame.offsetBy(dx: 20, dy: 30)
    window.setFrame(moved, display: false)
    #expect(window.frame == moved)
    SolaraPictureInPictureWindow.configure(window, keepOnTop: false)
    #expect(window.isAccessibilitySelectorAllowed(selector) == selectorAllowed)
    #expect(window.accessibilityIsAttributeSettable(.position) == positionSettable)
    #expect(window.accessibilityIsAttributeSettable(.size) == sizeSettable)
  }

  @Test func accessibilitySettersFollowTheSamePathAsUnconfiguredAppKitWindows() {
    NSApplication.shared.setActivationPolicy(.prohibited)
    func observingPanel() -> AXObservingPanel {
      let window = AXObservingPanel(contentRect: NSRect(x: 100, y: 100, width: 320, height: 180), styleMask: [.nonactivatingPanel, .resizable], backing: .buffered, defer: true)
      window.isReleasedWhenClosed = false
      return window
    }
    let configured = observingPanel()
    let baseline = observingPanel()
    defer { configured.close(); baseline.close() }
    SolaraPictureInPictureWindow.configure(configured, keepOnTop: true)
    for window in [configured, baseline] {
      window.accessibilitySetValue(NSValue(point: NSPoint(x: 600, y: 600)), forAttribute: .position)
      window.accessibilitySetValue(NSValue(size: NSSize(width: 640, height: 360)), forAttribute: .size)
    }
    #expect(configured.geometryWrites == 2)
    #expect(configured.geometryWrites == baseline.geometryWrites)
    #expect(configured.frame == baseline.frame)
  }

  @Test func closingPiPRemovesItsNotificationPolicy() {
    let window = panel()
    let baseline = window.accessibilityIsAttributeSettable(.position)
    SolaraPictureInPictureWindow.configure(window, keepOnTop: true)
    window.close()
    window.level = .normal
    window.collectionBehavior = []
    NSWorkspace.shared.notificationCenter.post(name: NSWorkspace.activeSpaceDidChangeNotification, object: nil)
    NotificationCenter.default.post(name: NSApplication.didBecomeActiveNotification, object: NSApp)
    #expect(window.level == .normal)
    #expect(window.collectionBehavior.isEmpty)
    #expect(window.accessibilityIsAttributeSettable(.position) == baseline)
  }

  @Test func keepOnTopOffRetainsSpacesAndFloatingAccessibilityIdentity() {
    let window = panel()
    defer { window.close() }
    SolaraPictureInPictureWindow.configure(window, keepOnTop: true)
    let behavior = window.collectionBehavior
    SolaraPictureInPictureWindow.configure(window, keepOnTop: false)
    #expect(window.level == .normal)
    #expect(window.collectionBehavior == behavior)
    #expect(window.accessibilitySubrole() == .floatingWindow)
  }

  @Test func spaceNotificationReappliesSettingsWithoutChangingTheFrame() {
    let window = panel()
    defer { window.close() }
    SolaraPictureInPictureWindow.configure(window, keepOnTop: true)
    let frame = window.frame
    window.level = .normal
    window.collectionBehavior = []
    NSWorkspace.shared.notificationCenter.post(name: NSWorkspace.activeSpaceDidChangeNotification, object: nil)
    #expect(window.level == .floating)
    #expect(window.collectionBehavior.contains([.canJoinAllSpaces, .canJoinAllApplications, .stationary, .fullScreenAuxiliary]))
    #expect(window.frame == frame)
    #expect(!NSApp.isActive)
  }

  @Test func notificationsDoNotMoveAnUnchangedWindowOrActivateTheApp() {
    let window = panel()
    defer { window.close() }
    SolaraPictureInPictureWindow.configure(window, keepOnTop: true)
    let frame = window.frame
    NSWorkspace.shared.notificationCenter.post(name: NSWorkspace.activeSpaceDidChangeNotification, object: nil)
    NotificationCenter.default.post(name: NSApplication.didBecomeActiveNotification, object: NSApp)
    NotificationCenter.default.post(name: NSApplication.didChangeScreenParametersNotification, object: NSApp)
    #expect(window.frame == frame)
    #expect(!NSApp.isActive)
    #expect(!window.isVisible)
  }

  private let main = PictureInPictureDisplay(id: 1, frame: NSRect(x: 0, y: 0, width: 1440, height: 900), visibleFrame: NSRect(x: 0, y: 40, width: 1440, height: 835))
  private let second = PictureInPictureDisplay(id: 2, frame: NSRect(x: 1440, y: 0, width: 1920, height: 1080), visibleFrame: NSRect(x: 1440, y: 40, width: 1920, height: 1015))

  @Test func screenReorderingKeepsTheChosenDisplayAndExactFrame() {
    let frame = NSRect(x: 1900, y: 200, width: 320, height: 180)
    let placement = PictureInPicturePlacement(frame: frame, display: second)
    #expect(placement.reconciled(displays: [second, main]) == frame)
  }

  @Test func displayRearrangementUsesTheChosenDisplayIdentity() {
    let placement = PictureInPicturePlacement(frame: NSRect(x: 1900, y: 200, width: 320, height: 180), display: second)
    let above = PictureInPictureDisplay(id: 2, frame: NSRect(x: -200, y: 900, width: 1920, height: 1080), visibleFrame: NSRect(x: -200, y: 900, width: 1920, height: 1055))
    #expect(placement.reconciled(displays: [main, above]) == NSRect(x: 260, y: 1100, width: 320, height: 180))
  }

  @Test func disappearingDisplayRescuesToASurvivorWithoutResizing() {
    let placement = PictureInPicturePlacement(frame: NSRect(x: 1900, y: 200, width: 320, height: 180), display: second)
    #expect(placement.reconciled(displays: [main]) == NSRect(x: 1120, y: 200, width: 320, height: 180))
    #expect(placement.reconciled(displays: []) == placement.frame)
  }

  @Test func unchangedDisplayPreservesAnEdgeStash() {
    let frame = NSRect(x: 3332, y: 200, width: 320, height: 180)
    let placement = PictureInPicturePlacement(frame: frame, display: second)
    #expect(placement.reconciled(displays: [main, second]) == frame)
  }

  @Test func workAreaChangeDoesNotUnstashTheWindow() {
    let frame = NSRect(x: 3332, y: 200, width: 320, height: 180)
    let placement = PictureInPicturePlacement(frame: frame, display: second)
    let dockChanged = PictureInPictureDisplay(id: second.id, frame: second.frame, visibleFrame: NSRect(x: 1500, y: 0, width: 1860, height: 1080))
    #expect(placement.reconciled(displays: [main, dockChanged]) == frame)
  }

  @Test func smallerDisplayKeepsTheWindowReachable() {
    let placement = PictureInPicturePlacement(frame: NSRect(x: 3000, y: 800, width: 320, height: 180), display: second)
    let small = PictureInPictureDisplay(id: 2, frame: NSRect(x: 1440, y: 0, width: 800, height: 600), visibleFrame: NSRect(x: 1440, y: 40, width: 800, height: 535))
    #expect(placement.reconciled(displays: [main, small]) == NSRect(x: 1920, y: 395, width: 320, height: 180))
  }

  @Test func overlapUsesGeometryInsteadOfScreenArrayOrder() {
    #expect(PictureInPicturePlacement.display(for: NSRect(x: 1400, y: 200, width: 320, height: 180), displays: [main, second])?.id == 2)
    #expect(PictureInPicturePlacement.display(for: NSRect(x: 1400, y: 200, width: 320, height: 180), displays: [second, main])?.id == 2)
  }
}
