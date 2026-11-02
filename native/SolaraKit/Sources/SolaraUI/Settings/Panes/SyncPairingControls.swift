import AppKit
import Darwin
import SwiftUI

public enum SyncPairingName {
  public static func isValid(_ name: String) -> Bool {
    let refused: Set<Unicode.GeneralCategory> = [.control, .format, .surrogate, .privateUse, .unassigned, .lineSeparator, .paragraphSeparator]
    let scalars = name.unicodeScalars
    return (1...128).contains(name.utf8.count) && scalars.count <= 64 && Array(name.utf8) == Array(name.precomposedStringWithCanonicalMapping.utf8) &&
      scalars.first?.properties.isWhitespace == false && scalars.last?.properties.isWhitespace == false &&
      scalars.allSatisfy { scalar in
        guard let age = scalar.properties.age, age <= (major: 15, minor: 0) else { return false }
        return !refused.contains(scalar.properties.generalCategory)
      }
  }

  public static func characters(_ name: String) -> String {
    name.unicodeScalars.map { String(format: "U+%04X", $0.value) }.joined(separator: " ")
  }

  public static func escaped(_ name: String) -> String {
    name.unicodeScalars.map { String(format: "\\u{%04X}", $0.value) }.joined()
  }

  public static func warning(_ name: String, knownNames: [String]) -> Bool? {
    guard let library = dlopen("/usr/lib/libicucore.A.dylib", RTLD_LOCAL | RTLD_NOW) else { return nil }
    defer { dlclose(library) }
    typealias Open = @convention(c) (UnsafeMutablePointer<Int32>?) -> UnsafeMutableRawPointer?
    typealias Close = @convention(c) (UnsafeMutableRawPointer?) -> Void
    typealias Check = @convention(c) (UnsafeMutableRawPointer?, UnsafePointer<CChar>?, Int32, UnsafeMutablePointer<Int32>?, UnsafeMutablePointer<Int32>?) -> Int32
    typealias Skeleton = @convention(c) (UnsafeMutableRawPointer?, UInt32, UnsafePointer<CChar>?, Int32, UnsafeMutablePointer<CChar>?, Int32, UnsafeMutablePointer<Int32>?) -> Int32
    guard let openSymbol = dlsym(library, "uspoof_open"), let closeSymbol = dlsym(library, "uspoof_close"),
          let checkSymbol = dlsym(library, "uspoof_checkUTF8"), let skeletonSymbol = dlsym(library, "uspoof_getSkeletonUTF8") else { return nil }
    let open = unsafeBitCast(openSymbol, to: Open.self)
    let close = unsafeBitCast(closeSymbol, to: Close.self)
    let check = unsafeBitCast(checkSymbol, to: Check.self)
    let skeleton = unsafeBitCast(skeletonSymbol, to: Skeleton.self)
    var status: Int32 = 0
    guard let checker = open(&status), status <= 0 else { return nil }
    defer { close(checker) }
    let flags = name.withCString { check(checker, $0, Int32(name.utf8.count), nil, &status) }
    guard status <= 0 else { return nil }
    if flags != 0 { return true }
    func signature(_ value: String) -> [CChar]? {
      var result = [CChar](repeating: 0, count: 2048)
      var error: Int32 = 0
      let length = value.withCString { skeleton(checker, 0, $0, Int32(value.utf8.count), &result, Int32(result.count), &error) }
      guard error <= 0, length >= 0, length < result.count else { return nil }
      return Array(result.prefix(Int(length)))
    }
    guard let value = signature(name) else { return nil }
    for known in knownNames {
      guard let other = signature(known) else { return nil }
      if value == other { return true }
    }
    return false
  }
}

@MainActor
public final class SyncAllowNativeButton: NSButton {
  public var invoke: () -> Void = {}
  public var deny: () -> Void = {}
  public override init(frame frameRect: NSRect) {
    super.init(frame: frameRect)
    title = "Allow"
    bezelStyle = .rounded
    keyEquivalent = ""
    setAccessibilityIdentifier("sync-pairing-allow")
    target = self
    action = #selector(pressed)
  }
  public required init?(coder: NSCoder) { nil }
  @objc private func pressed() { if isEnabled { invoke() } }
  public override func keyDown(with event: NSEvent) {
    if event.keyCode == 36 || event.keyCode == 76 { deny(); return }
    if event.keyCode == 49 { if isEnabled { invoke() }; return }
    super.keyDown(with: event)
  }
  public override func performKeyEquivalent(with event: NSEvent) -> Bool {
    if event.keyCode == 36 || event.keyCode == 76 { deny(); return true }
    return super.performKeyEquivalent(with: event)
  }
}

struct SyncAllowButton: NSViewRepresentable {
  var title = "Allow"
  let enabled: Bool
  let invoke: () -> Void
  let deny: () -> Void
  func makeNSView(context: Context) -> SyncAllowNativeButton {
    let button = SyncAllowNativeButton(frame: .zero)
    button.title = title
    button.invoke = invoke
    button.deny = deny
    button.isEnabled = enabled
    return button
  }
  func updateNSView(_ button: SyncAllowNativeButton, context: Context) { button.isEnabled = enabled }
}

struct SyncMatchedCheckbox: NSViewRepresentable {
  @Binding var isOn: Bool
  @Environment(\.isEnabled) private var isEnabled

  @MainActor
  final class Coordinator: NSObject {
    var binding: Binding<Bool>
    init(_ binding: Binding<Bool>) { self.binding = binding }
    @objc func pressed(_ sender: NSButton) { binding.wrappedValue = sender.state == .on }
  }

  func makeCoordinator() -> Coordinator { Coordinator($isOn) }

  func makeNSView(context: Context) -> NSButton {
    let button = NSButton(checkboxWithTitle: "The code matches on my other Mac", target: context.coordinator, action: #selector(Coordinator.pressed(_:)))
    button.identifier = NSUserInterfaceItemIdentifier("sync-pairing-matched")
    button.setAccessibilityIdentifier("sync-pairing-matched")
    button.setContentHuggingPriority(.defaultLow, for: .horizontal)
    return button
  }

  func updateNSView(_ button: NSButton, context: Context) {
    context.coordinator.binding = $isOn
    button.state = isOn ? .on : .off
    button.isEnabled = isEnabled
  }
}

struct SyncClaimedNameText: NSViewRepresentable {
  let text: String
  final class PlainText: NSTextView {
    override func menu(for event: NSEvent) -> NSMenu? { nil }
  }
  func makeNSView(context: Context) -> PlainText {
    let view = PlainText()
    view.isEditable = false
    view.isSelectable = false
    view.isRichText = false
    view.importsGraphics = false
    view.isAutomaticLinkDetectionEnabled = false
    view.isAutomaticDataDetectionEnabled = false
    view.drawsBackground = false
    view.font = .systemFont(ofSize: 13)
    view.textColor = .labelColor
    view.textContainerInset = .zero
    view.textContainer?.lineFragmentPadding = 0
    view.textContainer?.widthTracksTextView = true
    view.isVerticallyResizable = true
    view.setAccessibilityIdentifier("sync-pairing-claimed-name")
    return view
  }
  func updateNSView(_ view: PlainText, context: Context) { view.string = text }
  func sizeThatFits(_ proposal: ProposedViewSize, nsView: PlainText, context: Context) -> CGSize? {
    let width = proposal.width ?? 440
    nsView.textContainer?.containerSize = NSSize(width: width, height: .greatestFiniteMagnitude)
    nsView.layoutManager?.ensureLayout(for: nsView.textContainer!)
    let height = nsView.layoutManager?.usedRect(for: nsView.textContainer!).height ?? 20
    return CGSize(width: width, height: max(20, height))
  }
}

@MainActor
final class SyncPairingProbeView: NSView {
  var attach: (NSWindow) -> Void = { _ in }
  var changed: (TrustedSurfaceEvent) -> Void = { _ in }
  var sensitive = false
  var deny: () -> Void = {}
  private var notifications: [NSObjectProtocol] = []
  private var keys: Any?
  private var visibility: NSKeyValueObservation?
  private weak var observedWindow: NSWindow?
  override func performKeyEquivalent(with event: NSEvent) -> Bool {
    if sensitive && (event.keyCode == 36 || event.keyCode == 76 || event.keyCode == 53) { deny(); return true }
    return super.performKeyEquivalent(with: event)
  }
  override func viewDidMoveToWindow() {
    super.viewDidMoveToWindow()
    if window === observedWindow { return }
    let previous = observedWindow
    stopObserving()
    if previous != nil { changed(sensitive ? .remounted : .removed) }
    guard let window else { return }
    observedWindow = window
    if sensitive { identifier = NSUserInterfaceItemIdentifier("sync-pairing-sensitive") }
    attach(window)
    for name in [NSWindow.didResignKeyNotification, NSWindow.didBecomeKeyNotification, NSWindow.didMiniaturizeNotification,
                 NSWindow.didDeminiaturizeNotification, NSWindow.didChangeOcclusionStateNotification,
                 NSApplication.didResignActiveNotification, NSApplication.didBecomeActiveNotification, NSApplication.didHideNotification,
                 NSApplication.didUnhideNotification] {
      notifications.append(NotificationCenter.default.addObserver(forName: name, object: nil, queue: .main) { [weak self, weak window] notification in
        let source = notification.object as? NSWindow
        MainActor.assumeIsolated {
          guard let self, let window else { return }
          if let source,
             source !== window && source !== window.sheetParent && !window.sheets.contains(where: { $0 === source }) { return }
          if !Self.isForeground(window) { self.changed(.visibilityChanged) }
        }
      })
    }
    notifications.append(NotificationCenter.default.addObserver(forName: NSWindow.willCloseNotification, object: window, queue: .main) { [weak self] _ in
      MainActor.assumeIsolated { self?.changed(.removed) }
    })
    visibility = window.observe(\.isVisible, options: [.new]) { [weak self] _, _ in
      MainActor.assumeIsolated { self?.changed(.visibilityChanged) }
    }
    if sensitive {
      keys = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self, weak window] event in
        let consumed = MainActor.assumeIsolated {
          guard let self, event.window === window else { return false }
          if event.keyCode == 36 || event.keyCode == 76 || event.keyCode == 53 { self.deny(); return true }
          return false
        }
        return consumed ? nil : event
      }
    }
  }
  static func isForeground(_ window: NSWindow) -> Bool {
    let parent = window.sheetParent ?? window
    let family = [parent] + parent.sheets
    return NSApp.isActive && !NSApp.isHidden && parent.isVisible && !parent.isMiniaturized &&
      family.contains { $0.isKeyWindow && $0.occlusionState.contains(.visible) }
  }
  func stopObserving() {
    for token in notifications { NotificationCenter.default.removeObserver(token) }
    notifications = []
    if let keys { NSEvent.removeMonitor(keys) }
    keys = nil
    visibility?.invalidate()
    visibility = nil
    observedWindow = nil
  }
}

struct SyncPairingSurfaceProbe: NSViewRepresentable {
  let model: SyncTrustedPairingModel
  var sensitive = false
  func makeNSView(context: Context) -> SyncPairingProbeView {
    let view = SyncPairingProbeView()
    view.sensitive = sensitive
    view.attach = { [weak model] window in if !sensitive { model?.attach(to: window) } }
    view.changed = sensitive ? model.captureSurfaceChange() : { [weak model] event in model?.surfaceChanged(event) }
    view.deny = model.captureEnd(.deny)
    return view
  }
  func updateNSView(_ view: SyncPairingProbeView, context: Context) {
    if sensitive {
      view.changed = model.captureSurfaceChange()
      view.deny = model.captureEnd(.deny)
    } else if let window = view.window { model.attach(to: window) }
  }
  static func dismantleNSView(_ view: SyncPairingProbeView, coordinator: ()) { view.changed(view.sensitive ? .remounted : .removed); view.stopObserving() }
}

@MainActor
public final class SyncRequestNativeButton: NSButton {
  private let request: TrustedRequest
  private let select: (TrustedRequest) -> Void
  public init(request: TrustedRequest, select: @escaping (TrustedRequest) -> Void) {
    self.request = request
    self.select = select
    super.init(frame: .zero)
    title = "Connection \(request.sessionSuffix) · \(request.requestSuffix)"
    bezelStyle = .rounded
    target = self
    action = #selector(pressed)
  }
  public required init?(coder: NSCoder) { nil }
  @objc private func pressed() { if isEnabled { select(request) } }
}


struct SyncRequestButton: NSViewRepresentable {
  let request: TrustedRequest
  let select: (TrustedRequest) -> Void
  func makeNSView(context: Context) -> SyncRequestNativeButton { SyncRequestNativeButton(request: request, select: select) }
  func updateNSView(_ view: SyncRequestNativeButton, context: Context) {}
}
