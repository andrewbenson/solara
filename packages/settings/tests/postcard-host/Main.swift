import AppKit
import Foundation
import SolaraUI

@main
struct PostcardHostTests {
  @MainActor
  static func main() async {
    NSApplication.shared.setActivationPolicy(.prohibited)
    HostedPostcard.register()
    var failures: [String] = []
    func expect(_ value: @autoclosure () -> Bool, _ message: String) { if !value() { failures.append(message) } }
    var events: [[String: Any]] = []
    HostedViews.emit = { events.append($0) }
    let compactContent = HostedViews.make(HostedPostcard.postcardKind, windowId: "compact")!
    let compact = compactContent.view as! PostcardView
    compact.frame = CGRect(x: 0, y: 0, width: 559, height: 419)
    compactContent.onState?(state())
    compact.inspectMotion(4)
    expect(compact.isHidden && compact.state != nil && compact.motion["opacity"] == 1 && compact.motion["drop"] == 0, "compact mount must settle its intro invisibly")
    compact.frame.size = CGSize(width: 800, height: 600)
    compact.layoutSubtreeIfNeeded()
    expect(!compact.isHidden && compact.motion["opacity"] == 1 && compact.motion["drop"] == 0, "enlarging a compact mount must reveal the settled card without replay")
    compactContent.onUnmount?()
    let cardContent = HostedViews.make(HostedPostcard.postcardKind, windowId: "card")!
    let card = cardContent.view as! PostcardView
    card.frame = CGRect(x: 0, y: 0, width: 800, height: 600)
    card.makeBackdrop = { _ in NSView() }
    cardContent.onState?(state())
    card.inspectMotion(0)
    if !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion {
      expect(card.trackingAreas.first?.rect == CGRect(x: 496, y: -334, width: 368, height: 256), "intro hover region must follow the offscreen postcard")
      expect(card.trackingAreas.first?.rect.contains(CGPoint(x: 700, y: 100)) == false, "offscreen postcard must not hover at its resting point")
    }
    card.inspectMotion(0.325)
    if !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion {
      expect(abs((card.motion["drop"] ?? 0) - 0.17897445) < 0.00001, "postcard drop must match RN critically damped 650ms spring at 325ms")
      expect(card.motion["opacity"] == 1, "postcard opacity must finish at 300ms")
      expect(abs((card.trackingAreas.first?.rect.minY ?? 0) - (-54 - 280 * 0.17897445)) < 0.00001, "midflight hover region must follow spring drop")
    }
    card.inspectMotion(4)
    expect(card.trackingAreas.first?.rect == CGRect(x: 496, y: -54, width: 368, height: 256), "settled hover region must match RN outer view")
    expect(!cardContent.takesFocus, "postcard must preserve page focus")
    expect(card.cardFrame == CGRect(x: 520, y: -30, width: 320, height: 200), "postcard overhang must match RN")
    expect(card.hitTest(CGPoint(x: 100, y: 300)) == nil, "postcard must pass through unrelated points")
    let plate = card.subviews.first!
    expect(plate.layer?.anchorPoint == .zero, "backing anchor must remain AppKit default")
    expect(plate.layer?.position == card.cardFrame.origin, "AppKit backing position must remain the frame origin")
    let center = CGPoint(x: 160, y: 100)
    let mappedCenter = center.applying(plate.layer!.affineTransform())
    expect(abs(mappedCenter.x - center.x) < 0.00001 && abs(mappedCenter.y - center.y) < 0.00001, "postcard affine must rotate around RN center with a default backing anchor")
    func artwork(in root: NSView) -> NSView? {
      if String(describing: type(of: root)) == "PostcardArtwork" { return root }
      return root.subviews.lazy.compactMap { artwork(in: $0) }.first
    }
    if let cg = artwork(in: card)?.layer?.backgroundColor, let fill = NSColor(cgColor: cg)?.usingColorSpace(.sRGB) {
      expect(abs(fill.redComponent - 97.0 / 255) < 0.00001 && abs(fill.greenComponent - 134.0 / 255) < 0.00001 && abs(fill.blueComponent - 118.0 / 255) < 0.00001, "artwork must retain midpoint fill even when native shader backdrop is injected")
    } else { failures.append("artwork must provide an opaque parent fill under its shader") }
    expect(HostedPostcard.drive("card", HostedPostcard.postcardKind, "press", "What's new in Solara")["accepted"] as? Bool == true, "postcard must expose AX press")
    expect(events.last?["name"] as? String == "open", "postcard opens existing release notes")
    expect((events.last?["payload"] as? [String: Any])?["presentationId"] as? String == "receipt", "native action must retain its JS receipt")
    failures += await verifyControlInput(card, labels: ["What's new in Solara"], present: { cardContent.onState?(state()); card.inspectMotion(4) }, count: { events.count })
    let actionWindow = NSWindow(contentRect: card.frame, styleMask: [.titled], backing: .buffered, defer: false)
    actionWindow.isReleasedWhenClosed = false
    actionWindow.alphaValue = 0
    actionWindow.contentView = card
    cardContent.onState?(state())
    try? await Task.sleep(for: .milliseconds(100))
    expect(plate.layer?.anchorPoint == .zero, "first AppKit window flush must retain the default backing anchor")
    card.inspectMotion(4)
    let attachedCenter = center.applying(plate.layer!.affineTransform())
    expect(abs(attachedCenter.x - center.x) < 0.00001 && abs(attachedCenter.y - center.y) < 0.00001, "first AppKit window flush must preserve centered rotation")
    card.frame.size = CGSize(width: 820, height: 620)
    card.layoutSubtreeIfNeeded()
    try? await Task.sleep(for: .milliseconds(100))
    let resizedCenter = center.applying(plate.layer!.affineTransform())
    expect(abs(resizedCenter.x - center.x) < 0.00001 && abs(resizedCenter.y - center.y) < 0.00001 && plate.layer?.anchorPoint == .zero, "resize after settled intro must preserve centered rotation")
    card.frame.size = CGSize(width: 800, height: 600)
    card.layoutSubtreeIfNeeded()
    if let focusCard = card.subviews.first?.subviews.first as? PostcardControl {
      actionWindow.makeFirstResponder(focusCard)
      expect(card.hovered, "explicit postcard focus must reveal tooltip controls")
      actionWindow.makeFirstResponder(nil)
      try? await Task.sleep(for: .milliseconds(30))
      expect(!card.hovered, "leaving all postcard keyboard controls must clear synthetic hover")
    } else { failures.append("postcard must expose focus control") }
    card.setHovered(true)
    try? await Task.sleep(for: .milliseconds(180))
    expect(HostedPostcard.drive("card", HostedPostcard.postcardKind, "find", "Dismiss release notes")["found"] as? Bool == true, "hover must expose dismiss")
    let beforeDismiss = events.count
    _ = HostedPostcard.drive("card", HostedPostcard.postcardKind, "press", "Dismiss release notes")
    expect(events.count == beforeDismiss && card.leaving, "dismiss must wait for 200ms exit")
    cardContent.onState?(state(profile: "replacement", receipt: "replacement"))
    try? await Task.sleep(for: .milliseconds(260))
    expect(events.count == beforeDismiss, "replacement must cancel old pending dismiss")
    func find(_ label: String, in root: NSView) -> PostcardControl? {
      if let control = root as? PostcardControl, control.accessibilityLabel() == label, control.isAccessibilityElement() { return control }
      return root.subviews.lazy.compactMap { find(label, in: $0) }.first
    }
    if let control = find("What's new in Solara", in: card) {
      let saved = control.onPress
      cardContent.onState?(state(profile: "third", receipt: "third"))
      let before = events.count
      saved?()
      expect(events.count == before, "retained action must reject profile replacement")
      expect(control.acceptsFirstMouse(for: nil), "original RN card must explicitly accept first click")
    }
    actionWindow.contentView = nil
    actionWindow.close()
    let edgeWindow = NSWindow(contentRect: card.frame, styleMask: [.titled], backing: .buffered, defer: false)
    edgeWindow.isReleasedWhenClosed = false
    edgeWindow.alphaValue = 0
    edgeWindow.contentView = card
    cardContent.onState?(state(receipt: "edge"))
    card.inspectMotion(4)
    let edge = CGPoint(x: 518, y: 154)
    if let target = card.hitTest(card.convert(edge, to: nil)) as? PostcardControl {
      let before = events.count
      for type in [NSEvent.EventType.leftMouseDown, .leftMouseUp] {
        let event = NSEvent.mouseEvent(with: type, location: card.convert(edge, to: nil), modifierFlags: [], timestamp: 0, windowNumber: edgeWindow.windowNumber, context: nil, eventNumber: 1, clickCount: 1, pressure: 1)!
        if type == .leftMouseDown { target.mouseDown(with: event) } else { target.mouseUp(with: event) }
      }
      expect(events.count == before + 1, "rotated postcard edge must receive matching down and up")
      let point = target.convert(CGPoint(x: 100, y: 100), to: nil)
      let down = NSEvent.mouseEvent(with: .leftMouseDown, location: point, modifierFlags: [], timestamp: 0, windowNumber: edgeWindow.windowNumber, context: nil, eventNumber: 1, clickCount: 1, pressure: 1)!
      target.mouseDown(with: down)
      target.removeFromSuperview()
      let beforeDetachedUp = events.count
      let up = NSEvent.mouseEvent(with: .leftMouseUp, location: point, modifierFlags: [], timestamp: 0, windowNumber: edgeWindow.windowNumber, context: nil, eventNumber: 1, clickCount: 1, pressure: 0)!
      target.mouseUp(with: up)
      expect(events.count == beforeDetachedUp, "detached control must cancel its mouse sequence")
    } else { failures.append("rotated postcard edge must hit card") }
    edgeWindow.contentView = nil
    edgeWindow.close()
    let defaultControl = PostcardControl(frame: .zero)
    expect(!defaultControl.acceptsFirstMouse(for: nil), "first click must be opt-in per control")
    let pageContent = HostedViews.make(HostedPostcard.pageKind, windowId: "page")!
    let page = pageContent.view as! PostcardView
    page.frame = CGRect(x: 0, y: 0, width: 800, height: 600)
    let window = NSWindow(contentRect: page.frame, styleMask: [.titled], backing: .buffered, defer: false)
    window.isReleasedWhenClosed = false
    window.alphaValue = 0
    window.contentView = page
    pageContent.onState?(state())
    page.inspectMotion(0.15)
    expect(abs((page.motion["progress"] ?? 0) - 0.80060996) < 0.00001, "page must retain RN friction9 tension55 spring at 150ms")
    page.inspectMotion(4)
    try? await Task.sleep(for: .milliseconds(100))
    let pagePlate = page.subviews.last!
    let pageCenter = CGPoint(x: page.pageFrame.width / 2, y: page.pageFrame.height / 2)
    let mappedPageCenter = pageCenter.applying(pagePlate.layer!.affineTransform())
    expect(abs(mappedPageCenter.x - pageCenter.x) < 0.00001 && abs(mappedPageCenter.y - pageCenter.y) < 0.00001 && pagePlate.layer?.anchorPoint == .zero, "page center must survive first AppKit flush")
    expect(!pageContent.takesFocus, "release notes must not steal focus")
    let paperGap = page.convert(CGPoint(x: page.pageFrame.midX, y: page.pageFrame.minY + 12), to: nil)
    let gapTarget = page.hitTest(paperGap)
    expect(gapTarget != nil && gapTarget?.accessibilityLabel() != "Close release notes", "paper gaps must swallow clicks without closing")
    page.frame.size = CGSize(width: 640, height: 600)
    page.layoutSubtreeIfNeeded()
    if let narrowStamp = pagePlate.subviews.first(where: { String(describing: type(of: $0)) == "PostcardStamp" }) {
      expect(narrowStamp.frame == CGRect(x: 450, y: 188, width: 110, height: 86), "stacked postcard stamp must anchor to its column above padded text")
    } else { failures.append("narrow page must include native stamp") }
    page.frame.size = CGSize(width: 800, height: 600)
    page.layoutSubtreeIfNeeded()
    if let pageArtwork = artwork(in: page) {
      expect(pageArtwork.frame == CGRect(x: 16, y: 16, width: 324, height: page.pageFrame.height - 32), "46 percent artwork must match Yoga pixel rounding")
    } else { failures.append("page must include artwork") }
    if let date = pagePlate.subviews.first(where: { $0.accessibilityLabel() == "SEPTEMBER 2026" }) {
      expect(date.frame.minX == 362 && date.frame.width == 234, "right column must begin on the same pixel boundary as Yoga")
    } else { failures.append("page must expose its date") }
    page.frame.size = CGSize(width: 820, height: 620)
    page.layoutSubtreeIfNeeded()
    try? await Task.sleep(for: .milliseconds(100))
    page.frame.size = CGSize(width: 800, height: 600)
    page.layoutSubtreeIfNeeded()
    try? await Task.sleep(for: .milliseconds(100))
    if let scroll = pagePlate.subviews.compactMap({ $0 as? NSScrollView }).first,
      let itemBorder = scroll.documentView?.subviews.first(where: { String(describing: type(of: $0)) == "PostcardItemBorder" }),
      itemBorder.layer != nil {
      expect(itemBorder.frame.height > 30 && itemBorder.hitTest(.zero) == nil, "stretched item border must cover wrapper bounds and pass through input")
      expect(itemBorder.layer?.isGeometryFlipped == true, "AppKit attachment flush must preserve item backing geometry flip")
      expect(itemBorder.layer?.sublayers?.first?.needsDisplayOnBoundsChange == false, "raw border image must survive resize without delegate-backed display invalidation")
      let document = scroll.documentView!
      let pixelWidth = Int(document.bounds.width * 2)
      let pixelHeight = Int(document.bounds.height * 2)
      let context = CGContext(data: nil, width: pixelWidth, height: pixelHeight, bitsPerComponent: 8, bytesPerRow: pixelWidth * 4, space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
      context.setFillColor(CGColor(srgbRed: 252.0 / 255, green: 252.0 / 255, blue: 250.0 / 255, alpha: 1))
      context.fill(CGRect(x: 0, y: 0, width: pixelWidth, height: pixelHeight))
      context.scaleBy(x: 2, y: 2)
      if document.isFlipped || document.layer!.isGeometryFlipped {
        context.translateBy(x: 0, y: document.bounds.height)
        context.scaleBy(x: 1, y: -1)
      }
      document.layer!.render(in: context)
      let bytes = context.data!.assumingMemoryBound(to: UInt8.self)
      func sample(_ fraction: Double) -> [Int] {
        let y = Int(((itemBorder.frame.minY + itemBorder.frame.height * fraction) * 2 + Double(pixelHeight) - document.bounds.height * 2).rounded())
        let index = (min(pixelHeight - 1, y) * pixelWidth + pixelWidth - 4) * 4
        return (0..<3).map { Int(bytes[index + $0]) }
      }
      for (fraction, expected) in [(0.75, [252, 252, 250]), (0.9, [247, 247, 245])] {
        let actual = sample(fraction)
        expect(zip(actual, expected).allSatisfy { abs($0 - $1) <= 1 }, "actual document border must match RN stretch-raster inner fade at \(fraction): \(actual), expected \(expected)")
      }
      let bottom = sample(1 - 0.5 / itemBorder.frame.height)
      expect(zip(bottom, [234, 234, 232]).allSatisfy { abs($0 - $1) <= 1 }, "actual document border must match RN bottom pixel: \(bottom)")
      if let path = ProcessInfo.processInfo.environment["SOLARA_HOST_TEST_BUILD"], let image = context.makeImage(), let png = NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:]) {
        try? png.write(to: URL(fileURLWithPath: path + "/item-document.png"))
      }
    } else { failures.append("page must include stretched item borders") }
    let close = find("Close release notes", in: page)!
    let closeCenter = CGPoint(x: close.bounds.midX, y: close.bounds.midY)
    let mappedCloseCenter = closeCenter.applying(close.layer!.affineTransform())
    expect(abs(mappedCloseCenter.x - closeCenter.x) < 0.00001 && abs(mappedCloseCenter.y - closeCenter.y) < 0.00001 && close.layer?.anchorPoint == .zero, "page close scale must preserve center with default backing anchor")
    if let stamp = pagePlate.subviews.first(where: { String(describing: type(of: $0)) == "PostcardStamp" }) {
      expect(stamp.frame == CGRect(x: pagePlate.bounds.width - 126, y: 16, width: 110, height: 86), "explicit stamp insets must ignore the right column padding like Yoga")
    } else { failures.append("release notes page must include native stamp") }
    expect(close.acceptsFirstMouse(for: nil) && close.acceptsFirstResponder && close.canBecomeKeyView, "page close must expose first click and keyboard focus")
    for (key, code) in [(" ", UInt16(49)), ("\r", 36), ("\u{3}", 76)] {
      pageContent.onState?(state(receipt: UUID().uuidString))
      page.inspectMotion(4)
      let before = events.count
      window.makeFirstResponder(close)
      let event = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0, windowNumber: window.windowNumber, context: nil, characters: key, charactersIgnoringModifiers: key, isARepeat: false, keyCode: code)!
      close.keyDown(with: event)
      expect(!close.accessibilityPerformPress(), "disabled page exit control must reject repeated accessibility activation")
      try? await Task.sleep(for: .milliseconds(280))
      expect(events.count == before + 1 && events.last?["name"] as? String == "close", "page key \(code) must close once after exit")
    }
    pageContent.onState?(state(receipt: "first-click"))
    page.inspectMotion(4)
    window.orderBack(nil)
    NSApp.deactivate()
    window.resignKey()
    let pageGlobalCenter = CGPoint(x: page.pageFrame.midX, y: page.pageFrame.midY)
    let localClose = CGPoint(x: page.pageFrame.maxX - pageGlobalCenter.x, y: page.pageFrame.minY - pageGlobalCenter.y)
    let rotatedClose = localClose.applying(CGAffineTransform(rotationAngle: -.pi / 180))
    let closePoint = page.convert(CGPoint(x: pageGlobalCenter.x + rotatedClose.x, y: pageGlobalCenter.y + rotatedClose.y), to: nil)
    let beforeFirstClick = events.count
    for type in [NSEvent.EventType.leftMouseDown, .leftMouseUp] {
      let event = NSEvent.mouseEvent(with: type, location: closePoint, modifierFlags: [], timestamp: 0, windowNumber: window.windowNumber, context: nil, eventNumber: 1, clickCount: 1, pressure: 1)!
      NSApp.sendEvent(event)
    }
    try? await Task.sleep(for: .milliseconds(280))
    expect(events.count == beforeFirstClick + 1 && events.last?["name"] as? String == "close", "page close must accept its first inactive AppKit click")
    pageContent.onState?(state(receipt: "escape"))
    page.inspectMotion(4)
    let beforeEscape = events.count
    window.makeFirstResponder(close)
    let escape = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0, windowNumber: window.windowNumber, context: nil, characters: "\u{1b}", charactersIgnoringModifiers: "\u{1b}", isARepeat: false, keyCode: 53)!
    window.sendEvent(escape)
    try? await Task.sleep(for: .milliseconds(280))
    expect(events.count == beforeEscape + 1, "Escape from focused page close must reach page dismissal")
    pageContent.onState?(state(receipt: "unmount"))
    let saved = close.onPress
    let beforeUnmount = events.count
    _ = close.accessibilityPerformPress()
    pageContent.onUnmount?()
    saved?()
    try? await Task.sleep(for: .milliseconds(280))
    expect(events.count == beforeUnmount, "unmount must cancel exit and retained callbacks")
    expect(page.state == nil && HostedPostcard.drive("page", HostedPostcard.pageKind, "state", nil)["active"] as? Bool == false, "unmount must clear state and Debug receipt")
    pageContent.onState?(state())
    expect(page.state == nil, "ended host must ignore updates")
    window.contentView = nil
    window.close()
    cardContent.onState?("invalid")
    expect(card.state == nil && card.isHidden, "invalid state must clear drawing and targets")
    cardContent.onUnmount?()
    await verifyFocus(&failures)
    await verifyOpenChain(&failures)
    if failures.isEmpty { print("PASS postcard/page host geometry, actions, receipt fences, motion, keyboard, AX, first click, invalid state and unmount") }
    else { failures.forEach { print("FAIL \($0)") }; exit(1) }
  }



  @MainActor
  static func verifyOpenChain(_ failures: inout [String]) async {
    let window = NSWindow(contentRect: CGRect(x: 0, y: 0, width: 800, height: 600), styleMask: [.titled], backing: .buffered, defer: false)
    window.isReleasedWhenClosed = false
    window.alphaValue = 0
    let root = NSView(frame: CGRect(x: 0, y: 0, width: 800, height: 600))
    window.contentView = root
    let field = NSTextField(string: "open chain selection")
    field.frame = CGRect(x: 300, y: 300, width: 200, height: 24)
    root.addSubview(field)
    window.makeFirstResponder(field)
    let selection = NSRange(location: 5, length: 5)
    (field.currentEditor() as? NSTextView)?.setSelectedRange(selection)
    let host = NSView(frame: root.bounds)
    root.addSubview(host)
    let card = HostedViews.make(HostedPostcard.postcardKind, windowId: "chain")!
    let cardMount = HostedMount(content: card, in: host, window: window)
    card.onState?(state())
    (card.view as! PostcardView).inspectMotion(4)
    _ = HostedPostcard.drive("chain", HostedPostcard.postcardKind, "focus", "What's new in Solara")
    _ = HostedPostcard.drive("chain", HostedPostcard.postcardKind, "key", "What's new in Solara|Return")
    cardMount.end()
    let page = HostedViews.make(HostedPostcard.pageKind, windowId: "chain")!
    let pageMount = HostedMount(content: page, in: host, window: window)
    page.onState?(state())
    (page.view as! PostcardView).inspectMotion(4)
    _ = HostedPostcard.drive("chain", HostedPostcard.pageKind, "focus", "Close release notes")
    _ = HostedPostcard.drive("chain", HostedPostcard.pageKind, "key", "Close release notes|Space")
    try? await Task.sleep(for: .milliseconds(280))
    if field.currentEditor() !== window.firstResponder || (field.currentEditor() as? NSTextView)?.selectedRange() != selection {
      failures.append("postcard open followed by page keyboard close must retain the original field and selection")
    }
    pageMount.end()
    window.contentView = nil
    window.close()
  }

  @MainActor
  static func verifyFocus(_ failures: inout [String]) async {
    for kind in [HostedPostcard.postcardKind, HostedPostcard.pageKind] {
      let window = NSWindow(contentRect: CGRect(x: 0, y: 0, width: 800, height: 600), styleMask: [.titled], backing: .buffered, defer: false)
      window.isReleasedWhenClosed = false
      window.alphaValue = 0
      let root = NSView(frame: CGRect(x: 0, y: 0, width: 800, height: 600))
      window.contentView = root
      let field = NSTextField(string: "new tab selection")
      field.frame = CGRect(x: 300, y: 300, width: 200, height: 24)
      let other = NSTextField(string: "other focus")
      other.frame = CGRect(x: 300, y: 350, width: 200, height: 24)
      root.addSubview(field)
      root.addSubview(other)
      window.makeFirstResponder(field)
      let selection = NSRange(location: 4, length: 3)
      (field.currentEditor() as? NSTextView)?.setSelectedRange(NSRange(location: 1, length: 2))
      let host = NSView(frame: root.bounds)
      root.addSubview(host)
      let content = HostedViews.make(kind, windowId: "focus-" + kind)!
      let mount = HostedMount(content: content, in: host, window: window)
      let view = content.view as! PostcardView
      content.onState?(state())
      view.inspectMotion(4)
      func expect(_ value: @autoclosure () -> Bool, _ message: String) { if !value() { failures.append(kind + ": " + message) } }
      expect(field.currentEditor() === window.firstResponder, "passive mount must preserve field editing")
      (field.currentEditor() as? NSTextView)?.setSelectedRange(selection)
      let label = kind == HostedPostcard.pageKind ? "Close release notes" : "Dismiss release notes"
      func dismiss() {
        view.setHovered(true)
        _ = HostedPostcard.drive("focus-" + kind, kind, "focus", label)
        _ = HostedPostcard.drive("focus-" + kind, kind, "key", label + "|Space")
      }
      dismiss()
      try? await Task.sleep(for: .milliseconds(280))
      expect(field.currentEditor() === window.firstResponder && field.stringValue == "new tab selection" && (field.currentEditor() as? NSTextView)?.selectedRange() == selection, "keyboard dismissal must restore field text and current selection")
      content.onState?(state(receipt: "moved-focus"))
      view.inspectMotion(4)
      dismiss()
      window.makeFirstResponder(other)
      try? await Task.sleep(for: .milliseconds(280))
      expect(other.currentEditor() === window.firstResponder, "dismissal must preserve focus moved elsewhere")
      content.onState?(state(receipt: "profile"))
      view.inspectMotion(4)
      dismiss()
      content.onState?(state(profile: "replacement", receipt: "replacement"))
      try? await Task.sleep(for: .milliseconds(280))
      expect(field.currentEditor() !== window.firstResponder, "profile replacement must not restore previous profile field")
      content.onState?(state(receipt: "page"))
      view.inspectMotion(4)
      dismiss()
      content.onState?(state(receipt: "page", context: "other-page"))
      content.onState?(state(receipt: "page"))
      try? await Task.sleep(for: .milliseconds(280))
      expect(field.currentEditor() !== window.firstResponder, "page replacement must not restore previous page field")
      mount.end()
      window.contentView = nil
      window.close()
    }
  }

  static func state(profile: String = "profile", receipt: String = "receipt", context: String = "page") -> String {
    "{\"notes\":{\"version\":\"1.0\",\"date\":\"September 2026\",\"title\":\"Hello, Solara\",\"summary\":\"Summary\",\"items\":[{\"title\":\"Feature\",\"body\":\"Body\"}]},\"profileId\":\"\(profile)\",\"presentationId\":\"\(receipt)\",\"dark\":true,\"tokens\":{},\"colors\":[\"#98beab\",\"#2a4d40\"],\"iconUri\":\"\",\"product\":\"Solara\",\"focusContext\":\"\(context)\"}"
  }
}
