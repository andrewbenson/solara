import AppKit
import QuartzCore
import Testing
@testable import SolaraUI

@MainActor
struct SheetViewTests {
  static let dark = SheetStyle(dark: true, panel: "#312A35", panelBorder: "rgba(255,255,255,0.12)", panelShadowOpacity: 0.3)
  static let light = SheetStyle(dark: false, panel: "rgb(240,235,230)", panelBorder: "#00000022", panelShadowOpacity: 0.12)

  private static func window(size: CGSize = CGSize(width: 801, height: 603)) -> (NSWindow, NSView, SheetPageView, SheetView) {
    NSApplication.shared.setActivationPolicy(.prohibited)
    let window = NSWindow(contentRect: CGRect(origin: .zero, size: size), styleMask: [.borderless], backing: .buffered, defer: true)
    window.isReleasedWhenClosed = false
    let root = NSView(frame: CGRect(origin: .zero, size: size))
    window.contentView = root
    let page = SheetPageView(frame: root.bounds)
    root.addSubview(page)
    let sheet = SheetView(frame: root.bounds)
    root.addSubview(sheet)
    return (window, root, page, sheet)
  }

  static func present(_ sheet: SheetView, body: NSView = NSView(), height: CGFloat = 120, animated: Bool = false) {
    sheet.present(body: body, bodyHeight: height, style: dark, accessibilityTitle: "Test sheet", animated: animated)
  }

  static func key(_ code: UInt16, characters: String, flags: NSEvent.ModifierFlags = [], in window: NSWindow) throws -> NSEvent {
    try #require(NSEvent.keyEvent(
      with: .keyDown, location: .zero, modifierFlags: flags, timestamp: 0, windowNumber: window.windowNumber, context: nil,
      characters: characters, charactersIgnoringModifiers: characters, isARepeat: false, keyCode: code))
  }

  static func click(_ point: CGPoint, root: NSView, in window: NSWindow) throws {
    let target = try #require(root.hitTest(point))
    for type in [NSEvent.EventType.leftMouseDown, .leftMouseUp] {
      let event = try #require(NSEvent.mouseEvent(
        with: type, location: root.convert(point, to: nil), modifierFlags: [], timestamp: 0, windowNumber: window.windowNumber,
        context: nil, eventNumber: 0, clickCount: 1, pressure: type == .leftMouseUp ? 0 : 1))
      if type == .leftMouseDown { target.mouseDown(with: event) } else { target.mouseUp(with: event) }
    }
  }

  static func animations(_ layer: CALayer) -> [CABasicAnimation] {
    (layer.animationKeys() ?? []).compactMap { layer.animation(forKey: $0) as? CABasicAnimation }
  }

  static func layers(_ layer: CALayer) -> [CALayer] {
    [layer] + (layer.sublayers ?? []).flatMap { layers($0) }
  }

  static func expectGeometry(_ sheet: SheetView, height: CGFloat) {
    let frame = sheet.cardFrame
    let scale = sheet.window?.backingScaleFactor ?? 2
    #expect(frame.width == 380)
    #expect(frame.height == height + 40)
    #expect(abs(frame.midX - sheet.bounds.midX) <= 0.5 / scale)
    #expect(abs(frame.midY - sheet.bounds.midY) <= 0.5 / scale)
    #expect(abs(frame.minX * scale - (frame.minX * scale).rounded()) < 0.0001)
    #expect(abs(frame.minY * scale - (frame.minY * scale).rounded()) < 0.0001)
  }

  @Test func geometryFollowsBodyHeightAndOddContainerSizes() throws {
    let (window, _, _, sheet) = Self.window()
    defer { window.close() }
    let body = NSView()
    Self.present(sheet, body: body, height: 123)
    for size in [CGSize(width: 800, height: 600), CGSize(width: 801, height: 603), CGSize(width: 999, height: 777), CGSize(width: 421, height: 305)] {
      sheet.setFrameSize(size)
      sheet.layoutSubtreeIfNeeded()
      Self.expectGeometry(sheet, height: 123)
      #expect(body.frame == CGRect(x: 20, y: 20, width: 340, height: 123))
      #expect(body.superview?.frame == sheet.cardFrame)
    }
    sheet.setBodyHeight(211)
    Self.expectGeometry(sheet, height: 211)
    #expect(body.frame.height == 211)
    sheet.frame = CGRect(x: 0, y: 0, width: 713, height: 519)
    sheet.needsLayout = true
    sheet.layoutSubtreeIfNeeded()
    Self.expectGeometry(sheet, height: 211)
  }

  @Test func scrimDismissesUnlessBusyAndNeverClicksThePage() throws {
    let (window, root, page, sheet) = Self.window()
    defer { window.close() }
    Self.present(sheet)
    var dismissed = 0
    sheet.onDismiss = { dismissed += 1 }
    try Self.click(CGPoint(x: 5, y: 5), root: root, in: window)
    #expect(dismissed == 1)
    #expect(page.presses == 0)
    sheet.busy = true
    try Self.click(CGPoint(x: 5, y: 5), root: root, in: window)
    #expect(dismissed == 1)
    #expect(page.presses == 0)
    sheet.busy = false
    let cardPoint = root.convert(sheet.cardFrame.center, from: sheet)
    try Self.click(cardPoint, root: root, in: window)
    #expect(dismissed == 1)
  }

  @Test func aScrimPressThatSpansABodyReplacementDoesNotDismissTheNewBody() throws {
    let (window, root, _, sheet) = Self.window()
    defer { window.close() }
    Self.present(sheet, body: NSView())
    var dismissed = 0
    sheet.onDismiss = { dismissed += 1 }
    let point = CGPoint(x: 10, y: 10)
    let target = try #require(root.hitTest(point))
    let down = try #require(NSEvent.mouseEvent(
      with: .leftMouseDown, location: root.convert(point, to: nil), modifierFlags: [], timestamp: 0, windowNumber: window.windowNumber,
      context: nil, eventNumber: 0, clickCount: 1, pressure: 1))
    let up = try #require(NSEvent.mouseEvent(
      with: .leftMouseUp, location: root.convert(point, to: nil), modifierFlags: [], timestamp: 0, windowNumber: window.windowNumber,
      context: nil, eventNumber: 0, clickCount: 1, pressure: 0))
    target.mouseDown(with: down)
    Self.present(sheet, body: NSView())
    target.mouseUp(with: up)
    #expect(dismissed == 0)
    target.mouseDown(with: down)
    target.mouseUp(with: up)
    #expect(dismissed == 1)
  }

  @Test func everyPointOutsideTheCardStillHitsTheSheet() throws {
    let (window, root, page, sheet) = Self.window()
    defer { window.close() }
    Self.present(sheet)
    for point in [CGPoint(x: 1, y: 1), CGPoint(x: 800, y: 1), CGPoint(x: 1, y: 602), CGPoint(x: 800, y: 602)] {
      let hit = try #require(root.hitTest(point))
      #expect(hit !== page)
      #expect(hit === sheet || hit.isDescendant(of: sheet))
      #expect(sheet.hitTest(sheet.convert(point, from: root)) != nil)
    }
  }

  @Test func scrollEventsOverTheScrimAreSwallowed() throws {
    let (window, root, page, sheet) = Self.window()
    defer { window.close() }
    Self.present(sheet)
    let hit = try #require(root.hitTest(CGPoint(x: 5, y: 5)))
    let scroll = try #require(CGEvent(scrollWheelEvent2Source: nil, units: .pixel, wheelCount: 1, wheel1: 12, wheel2: 0, wheel3: 0))
    let event = try #require(NSEvent(cgEvent: scroll))
    hit.scrollWheel(with: event)
    #expect(page.scrolls == 0)
  }

  @Test func escapeAndCancelRespectBusyAndReturnRequiresCardFocus() throws {
    let (window, _, page, sheet) = Self.window()
    defer { window.close() }
    let body = NSView()
    let field = NSTextField(frame: CGRect(x: 0, y: 0, width: 200, height: 24))
    body.addSubview(field)
    Self.present(sheet, body: body)
    let card = try #require(body.superview)
    #expect(card.acceptsFirstResponder)
    #expect(window.firstResponder === card)
    var dismissed = 0
    var submitted = 0
    sheet.onDismiss = { dismissed += 1 }
    sheet.onSubmit = { submitted += 1 }
    card.cancelOperation(nil)
    card.keyDown(with: try Self.key(53, characters: "\u{1B}", in: window))
    #expect(dismissed == 2)
    sheet.busy = true
    card.cancelOperation(nil)
    card.keyDown(with: try Self.key(53, characters: "\u{1B}", in: window))
    #expect(dismissed == 2)
    sheet.busy = false
    card.keyDown(with: try Self.key(36, characters: "\r", in: window))
    card.keyDown(with: try Self.key(76, characters: "\u{3}", in: window))
    #expect(submitted == 2)
    #expect(window.makeFirstResponder(field))
    #expect(window.firstResponder !== card)
    window.firstResponder?.keyDown(with: try Self.key(36, characters: "\r", in: window))
    #expect(submitted == 2)
    card.keyDown(with: try Self.key(36, characters: "\r", in: window))
    #expect(submitted == 2)
    #expect(page.keys == 0)
  }

  @Test func tabTraversalStaysInsideTheBodyAndReturnsToTheCard() throws {
    let (window, _, page, sheet) = Self.window()
    defer { window.close() }
    let body = NSView()
    let first = NSTextField(frame: CGRect(x: 0, y: 0, width: 180, height: 24))
    let middle = NSTextField(frame: CGRect(x: 0, y: 30, width: 180, height: 24))
    let last = NSTextField(frame: CGRect(x: 0, y: 40, width: 180, height: 24))
    body.addSubview(first)
    body.addSubview(middle)
    body.addSubview(last)
    first.nextKeyView = last
    last.nextKeyView = middle
    page.nextKeyView = first
    middle.nextKeyView = page
    Self.present(sheet, body: body)
    let card = try #require(body.superview)
    #expect(first.nextKeyView === last)
    card.keyDown(with: try Self.key(48, characters: "\t", in: window))
    #expect(window.firstResponder === first || window.firstResponder === first.currentEditor())
    #expect(first.nextKeyView === last)
    #expect(sheet.performKeyEquivalent(with: try Self.key(48, characters: "\t", in: window)))
    #expect(window.firstResponder === last || window.firstResponder === last.currentEditor())
    #expect(sheet.performKeyEquivalent(with: try Self.key(48, characters: "\t", in: window)))
    #expect(window.firstResponder === middle || window.firstResponder === middle.currentEditor())
    #expect(middle.nextKeyView === card)
    #expect(card.canBecomeKeyView)
    #expect(sheet.performKeyEquivalent(with: try Self.key(48, characters: "\t", in: window)))
    #expect(window.firstResponder === card)
    card.keyDown(with: try Self.key(48, characters: "\t", flags: .shift, in: window))
    #expect(window.firstResponder === middle || window.firstResponder === middle.currentEditor())
    window.selectKeyView(preceding: first)
    #expect(window.firstResponder === card)
  }

  @Test func commandKeysStillReachTheMenusAndPlainKeysStayInTheSheet() throws {
    let (window, _, page, sheet) = Self.window()
    defer { window.close() }
    let body = NSView()
    Self.present(sheet, body: body)
    let card = try #require(body.superview)
    let command = try Self.key(12, characters: "q", flags: .command, in: window)
    #expect(!sheet.performKeyEquivalent(with: command))
    card.keyDown(with: try Self.key(0, characters: "a", in: window))
    #expect(sheet.performKeyEquivalent(with: try Self.key(53, characters: "\u{1B}", in: window)))
    #expect(page.keys == 0)
    #expect(window.firstResponder === card)
  }

  @Test func styleReachesTheScrimAndCardLayers() throws {
    let (window, _, _, sheet) = Self.window()
    defer { window.close() }
    let body = NSView()
    Self.present(sheet, body: body)
    let card = try #require(body.superview)
    #expect(sheet.devScrimAlpha == 0.35)
    #expect(card.layer?.backgroundColor == CSSColor(Self.dark.panel)?.cg)
    #expect(card.layer?.borderColor == CSSColor(Self.dark.panelBorder)?.cg)
    #expect(card.layer?.borderWidth == 0.5)
    #expect(card.layer?.cornerRadius == 14)
    #expect(card.layer?.cornerCurve == .continuous)
    let shadow = try #require(card.layer?.sublayers?.first { $0.shadowPath != nil })
    #expect(shadow.shadowColor == NSColor.black.cgColor)
    #expect(shadow.shadowOpacity == Float(Self.dark.panelShadowOpacity))
    #expect(shadow.shadowRadius == 30)
    #expect(abs(shadow.shadowOffset.height) == 12)
    #expect((shadow.mask as? CAShapeLayer)?.fillRule == .evenOdd)
    sheet.setStyle(Self.light)
    #expect(sheet.devScrimAlpha == 0.15)
    #expect(card.layer?.backgroundColor == CSSColor(Self.light.panel)?.cg)
    #expect(card.layer?.borderColor == CSSColor(Self.light.panelBorder)?.cg)
    #expect(shadow.shadowOpacity == Float(Self.light.panelShadowOpacity))
  }

  @Test func replacementBodyKeepsTheCardAndDoesNotAnimateAgain() throws {
    let (window, _, _, sheet) = Self.window()
    defer { window.close() }
    let first = NSView()
    Self.present(sheet, body: first)
    let card = try #require(first.superview)
    let second = NSView()
    sheet.present(body: second, bodyHeight: 200, style: Self.light, accessibilityTitle: "Replacement", animated: true)
    #expect(first.superview == nil)
    #expect(second.superview === card)
    #expect(sheet.cardFrame.height == 240)
    #expect(!sheet.devAppearAnimating)
    #expect(card.accessibilityLabel() == "Replacement")
    #expect(card.isAccessibilityElement())
    #expect(card.accessibilityRole() == .sheet || card.accessibilityRole() == .group)
    #expect(card.isAccessibilityModal())
    #expect(!sheet.isAccessibilityElement())
  }

  @Test func appearUsesOnlyCoreAnimationWithTheSpecifiedCubicCurve() throws {
    let (window, _, _, sheet) = Self.window()
    defer { window.close() }
    sheet.devReduceMotion = false
    let body = NSView()
    Self.present(sheet, body: body, animated: true)
    let card = try #require(body.superview)
    let cardLayer = try #require(card.layer)
    let rootLayer = try #require(sheet.layer)
    #expect(sheet.devAppearAnimating)
    #expect(cardLayer.anchorPoint == CGPoint(x: 0.5, y: 0.5))
    #expect(cardLayer.position == CGPoint(x: sheet.cardFrame.midX, y: sheet.cardFrame.midY))
    let cardAnimations = Self.animations(cardLayer)
    let opacity = try #require(cardAnimations.first { $0.keyPath == "opacity" })
    let transform = try #require(cardAnimations.first { $0.keyPath == "transform" || $0.keyPath == "transform.scale" })
    let scrimAnimations = Self.layers(rootLayer).filter { $0 !== cardLayer }.flatMap { Self.animations($0) }
    let scrimOpacity = try #require(scrimAnimations.first { $0.keyPath == "opacity" })
    for animation in [opacity, transform, scrimOpacity] {
      #expect(abs(animation.duration - 0.17) < 0.000001)
      let timing = try #require(animation.timingFunction)
      var first: [Float] = [0, 0]
      var second: [Float] = [0, 0]
      timing.getControlPoint(at: 1, values: &first)
      timing.getControlPoint(at: 2, values: &second)
      #expect(abs(first[0] - 0.215) < 0.00001)
      #expect(abs(first[1] - 0.61) < 0.00001)
      #expect(abs(second[0] - 0.355) < 0.00001)
      #expect(second[1] == 1)
    }
    #expect((opacity.fromValue as? NSNumber)?.doubleValue == 0)
    #expect((opacity.toValue as? NSNumber)?.doubleValue == 1)
    #expect((scrimOpacity.fromValue as? NSNumber)?.doubleValue == 0)
    #expect((scrimOpacity.toValue as? NSNumber)?.doubleValue == 1)
    if transform.keyPath == "transform.scale" {
      #expect((transform.fromValue as? NSNumber)?.doubleValue == 0.96)
      #expect((transform.toValue as? NSNumber)?.doubleValue == 1)
    } else {
      let from = try #require(transform.fromValue as? NSValue).caTransform3DValue
      let to = try #require(transform.toValue as? NSValue).caTransform3DValue
      #expect(abs(from.m11 - 0.96) < 0.000001)
      #expect(abs(from.m22 - 0.96) < 0.000001)
      #expect(CATransform3DIsIdentity(to))
    }
    #expect(!Mirror(reflecting: sheet).children.contains { String(reflecting: type(of: $0.value)).contains("CADisplayLink") })
    #expect(!Mirror(reflecting: card).children.contains { String(reflecting: type(of: $0.value)).contains("CADisplayLink") })
  }

  @Test func unanimatedAndReducedMotionPresentationsAttachNoAnimations() throws {
    for reduced in [false, true] {
      let (window, _, _, sheet) = Self.window()
      defer { window.close() }
      sheet.devReduceMotion = reduced
      Self.present(sheet, animated: reduced)
      let layer = try #require(sheet.layer)
      #expect(!sheet.devAppearAnimating)
      #expect(Self.layers(layer).allSatisfy { ($0.animationKeys() ?? []).isEmpty })
    }
  }
}

@MainActor
private final class SheetPageView: NSView {
  var presses = 0
  var keys = 0
  var equivalents = 0
  var scrolls = 0
  override var acceptsFirstResponder: Bool { true }
  override func mouseDown(with event: NSEvent) { presses += 1 }
  override func keyDown(with event: NSEvent) { keys += 1 }
  override func scrollWheel(with event: NSEvent) { scrolls += 1 }
  override func performKeyEquivalent(with event: NSEvent) -> Bool {
    equivalents += 1
    return false
  }
}

private extension CGRect {
  var center: CGPoint { CGPoint(x: midX, y: midY) }
}
