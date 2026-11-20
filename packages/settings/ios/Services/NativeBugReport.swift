import AppKit
import SolaraModel
import SolaraShell
import SolaraStore
import SolaraUI

@MainActor
final class NativeBugReport {
  static let shared = NativeBugReport()
  nonisolated static let seenKey = "SolaraCrashReportSeen"

  private var checked = false
  private var prompt: CrashPromptPanel?
  private var parentClose: NSObjectProtocol?
  private var pending: (source: CrashSource, report: URL, summary: CrashSummary, mark: Double)?
  private var windowWatchers: [NSObjectProtocol] = []
  private var presentQueued = false
  #if DEBUG
  private(set) var lastOpened: String?
  private(set) var revealed: String?
  private(set) var answered: String?
  #endif

  nonisolated private static var environment: [String: String] { ProcessInfo.processInfo.environment }
  nonisolated private static var background: Bool { environment["SOLARA_BACKGROUND"] == "1" }
  nonisolated private static var isolated: Bool { background || environment["SOLARA_DATA_DIR"] != nil }

  func facts(windowId: String?) -> BugReportFacts? {
    guard let repo = AdvancedAdapter.releaseRepo else { return nil }
    let info = AppModule.systemInfo
    let state = NativeStoreHandle.ownsWorkspace ? NativeStoreHandle.store?.state : nil
    let target = state.flatMap { state in
      CommandRoute.resolve("reportBug", windowId: windowId, state: state, closing: NativeStoreHandle.store?.memory.closingWindows ?? []).windowId
    }
    return BugReportFacts(
      repo: repo,
      version: info["appVersion"] as? String ?? "",
      build: info["appBuild"] as? String ?? "",
      macOS: info["osVersion"] as? String ?? "",
      model: info["model"] as? String ?? "",
      layout: BugReport.layoutName(state, windowId: target))
  }

  func url(windowId: String?, crash: String? = nil) -> String? {
    facts(windowId: windowId).flatMap { BugReport.url($0, crash: crash) }
  }

  func report(windowId: String?, crash: String? = nil) {
    guard let url = url(windowId: windowId, crash: crash) else { return NSLog("[bug] no release repo in this build's identity") }
    open(url, windowId: windowId)
  }

  private func open(_ url: String, windowId: String?) {
    #if DEBUG
    lastOpened = url
    #endif
    guard NativeStoreHandle.ownsWorkspace, let store = NativeStoreHandle.store else {
      if Self.background { return NSLog("[bug] background instance, not opening the report page") }
      if let page = URL(string: url) { NSWorkspace.shared.open(page) }
      return
    }
    let state = store.state
    let route = CommandRoute.resolve("reportBug", windowId: windowId, state: state, closing: store.memory.closingWindows)
    if let target = route.windowId, state.windows[target]?.incognito != true {
      if let focus = route.focusWindow {
        _ = try? store.dispatch(Command("setFocusedWindow", [.string(focus)]), origin: .native)
        ShellScripting.showWindow(focus)
      }
      _ = try? store.dispatch(Command("newTab", [.string(target), ["url": .string(url)]]), origin: .native)
    } else {
      let created = try? store.dispatch(Command("createWindow", [["url": .string(url)]]), origin: .native)
      if let id = created?.result?.string { ShellScripting.showWindow(id) }
    }
    FrameUpdates.flush()
  }

  struct CrashSource {
    var directory: URL
    var markFile: URL?
    var seed: Double?

    static var current: CrashSource? {
      #if DEBUG
      if let dir = NativeBugReport.environment["SOLARA_DEV_CRASH_REPORTS_DIR"], !dir.isEmpty {
        let directory = URL(fileURLWithPath: dir, isDirectory: true)
        return CrashSource(
          directory: directory, markFile: directory.appendingPathComponent(".solara-crash-seen"),
          seed: NativeBugReport.environment["SOLARA_DEV_CRASH_SEEN"].flatMap(Double.init))
      }
      #endif
      guard !NativeBugReport.isolated else { return nil }
      let logs = FileManager.default.urls(for: .libraryDirectory, in: .userDomainMask).first?
        .appendingPathComponent("Logs/DiagnosticReports", isDirectory: true)
      return logs.map { CrashSource(directory: $0, markFile: nil, seed: nil) }
    }

    func load() -> Double? {
      if let markFile {
        if let text = try? String(contentsOf: markFile, encoding: .utf8), let value = Double(text.trimmingCharacters(in: .whitespacesAndNewlines)) { return value }
        return seed
      }
      return UserDefaults.standard.object(forKey: NativeBugReport.seenKey) as? Double
    }

    func save(_ mark: Double) {
      if let markFile {
        try? String(mark).write(to: markFile, atomically: true, encoding: .utf8)
      } else {
        UserDefaults.standard.set(mark, forKey: NativeBugReport.seenKey)
      }
    }
  }

  func checkAtLaunch() {
    guard !checked, let source = CrashSource.current else { return }
    checked = true
    guard let mark = source.load() else { return source.save(Date().timeIntervalSince1970) }
    let executable = Bundle.main.executableURL?.lastPathComponent ?? ""
    let bundleId = Bundle.main.bundleIdentifier ?? ""
    let home = NSHomeDirectory()
    DispatchQueue.global(qos: .utility).async {
      let scan = CrashReport.scan(directory: source.directory, executable: executable, bundleId: bundleId, after: mark)
      let summary = scan.report.flatMap { report in
        (try? Data(contentsOf: report)).flatMap { CrashReport.summary($0, bundleId: bundleId, home: home) }
      }
      DispatchQueue.main.async {
        MainActor.assumeIsolated {
          guard let report = scan.report, let summary else { return source.save(scan.mark) }
          self.pending = (source, report, summary, scan.mark)
          self.watchWindows()
          self.presentWhenWindowIsUp()
        }
      }
    }
  }

  private func watchWindows() {
    guard windowWatchers.isEmpty else { return }
    let center = NotificationCenter.default
    let names: [Notification.Name] = [
      NSWindow.didBecomeMainNotification, NSWindow.didDeminiaturizeNotification, NSWindow.didChangeOcclusionStateNotification,
      NSWindow.didExposeNotification, NSApplication.didBecomeActiveNotification, NSApplication.didUnhideNotification,
    ]
    windowWatchers = names.map { name in
      center.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
        MainActor.assumeIsolated { self?.presentWhenWindowIsUp() }
      }
    }
  }

  private func stopWatchingWindows() {
    for watcher in windowWatchers { NotificationCenter.default.removeObserver(watcher) }
    windowWatchers = []
  }

  private func browserWindow() -> (String, NSWindow)? {
    guard let state = NativeStoreHandle.store?.state else { return nil }
    let ids = [state.ui.focusedWindowId].compactMap { $0 } + state.windowOrder
    for id in ids where state.windows[id]?.isSmall == false {
      if let window = ShellDrag.window(id), window.isVisible, !window.isMiniaturized { return (id, window) }
    }
    return nil
  }

  private func presentWhenWindowIsUp(tries: Int = 120) {
    guard prompt == nil, pending != nil, !presentQueued else { return }
    guard browserWindow() != nil else {
      guard tries > 0 else { return }
      presentQueued = true
      DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) {
        self.presentQueued = false
        self.presentWhenWindowIsUp(tries: tries - 1)
      }
      return
    }
    presentQueued = true
    DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
      self.presentQueued = false
      guard self.prompt == nil, let pending = self.pending, let (windowId, window) = self.browserWindow() else { return }
      self.pending = nil
      self.stopWatchingWindows()
      self.present(over: window, windowId: windowId, report: pending.report, summary: pending.summary)
      pending.source.save(pending.mark)
    }
  }

  private func present(over window: NSWindow, windowId: String, report: URL, summary: CrashSummary) {
    let product = Bundle.main.productName
    let panel = CrashPromptPanel(message: "\(product) quit unexpectedly last time. Report it?")
    panel.onReport = { [weak self] in
      self?.dismiss(answer: "report")
      self?.report(windowId: windowId, crash: summary.text)
      self?.reveal(report)
    }
    panel.onNotNow = { [weak self] in self?.dismiss(answer: "notNow") }
    let hidden = Self.background && Self.environment["SOLARA_DRAW_WINDOWS"] != "1"
    panel.alphaValue = hidden ? 0 : window.alphaValue
    panel.place(over: window)
    window.addChildWindow(panel, ordered: .above)
    panel.orderFront(nil)
    prompt = panel
    parentClose = NotificationCenter.default.addObserver(forName: NSWindow.willCloseNotification, object: window, queue: .main) { [weak self] _ in
      MainActor.assumeIsolated { self?.dismiss(answer: "closed") }
    }
  }

  private func dismiss(answer: String) {
    #if DEBUG
    answered = answer
    #endif
    if let parentClose { NotificationCenter.default.removeObserver(parentClose) }
    parentClose = nil
    guard let panel = prompt else { return }
    prompt = nil
    panel.parent?.removeChildWindow(panel)
    panel.orderOut(nil)
  }

  private func reveal(_ report: URL) {
    #if DEBUG
    revealed = report.path
    #endif
    if Self.background { return NSLog("[bug] background instance, not showing the crash report in Finder") }
    NSWorkspace.shared.activateFileViewerSelecting([report])
  }

  #if DEBUG
  func drive(_ action: String, _ argument: String?) -> String {
    switch action {
    case "url":
      return Self.json(["url": url(windowId: argument) ?? NSNull()])
    case "urlWithCrash":
      return Self.json(["url": url(windowId: nil, crash: argument) ?? NSNull()])
    case "press":
      guard let prompt else { return Self.json(["error": "no prompt"]) }
      prompt.press(argument ?? "")
    case "click":
      guard let prompt else { return Self.json(["error": "no prompt"]) }
      return Self.json(["clicked": prompt.click(argument ?? "")])
    case "recheck":
      checked = false
      checkAtLaunch()
    case "minimize":
      guard let argument, let window = ShellDrag.window(argument) else { return Self.json(["error": "no window"]) }
      window.miniaturize(nil)
    case "deminiaturize":
      guard let argument, let window = ShellDrag.window(argument) else { return Self.json(["error": "no window"]) }
      window.deminiaturize(nil)
    case "snapshot":
      guard let prompt, let argument else { return Self.json(["error": "no prompt or path"]) }
      return Self.json(["written": prompt.snapshot(to: URL(fileURLWithPath: argument))])
    default:
      break
    }
    var promptState: [String: Any] = ["shown": false]
    if let prompt {
      promptState = [
        "shown": prompt.isVisible, "message": prompt.message, "parentNumber": prompt.parent?.windowNumber ?? -1,
        "frame": [prompt.frame.minX, prompt.frame.minY, prompt.frame.width, prompt.frame.height],
        "parentFrame": prompt.parent.map { [$0.frame.minX, $0.frame.minY, $0.frame.width, $0.frame.height] } ?? [],
        "isKey": prompt.isKeyWindow, "becomesKeyOnlyIfNeeded": prompt.becomesKeyOnlyIfNeeded, "label": prompt.accessibilityLabel() ?? "", "buttons": prompt.buttonTitles,
      ]
    }
    return Self.json([
      "checked": checked, "prompt": promptState, "lastOpened": lastOpened ?? NSNull(), "revealed": revealed ?? NSNull(),
      "answered": answered ?? NSNull(), "keyWindowNumber": NSApp.keyWindow?.windowNumber ?? -1, "pending": pending != nil,
    ])
  }

  private static func json(_ value: [String: Any]) -> String {
    let data = (try? JSONSerialization.data(withJSONObject: value, options: [.sortedKeys])) ?? Data("{}".utf8)
    return String(decoding: data, as: UTF8.self)
  }
  #endif
}

private final class FirstMouseButton: NSButton {
  override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
}

final class CrashPromptPanel: NSPanel {
  static let size = NSSize(width: 360, height: 92)
  let message: String
  var onReport: () -> Void = {}
  var onNotNow: () -> Void = {}
  private let reportButton = FirstMouseButton()
  private let notNowButton = FirstMouseButton()

  init(message: String) {
    self.message = message
    super.init(contentRect: NSRect(origin: .zero, size: Self.size), styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
    isFloatingPanel = false
    becomesKeyOnlyIfNeeded = true
    hidesOnDeactivate = false
    isReleasedWhenClosed = false
    backgroundColor = .clear
    isOpaque = false
    hasShadow = true
    animationBehavior = .utilityWindow
    setAccessibilityLabel(message)
    setAccessibilitySubrole(.dialog)
    contentView = makeContent()
  }

  required init?(coder: NSCoder) { nil }

  override var canBecomeKey: Bool { true }
  override var canBecomeMain: Bool { false }

  var buttonTitles: [String] { [notNowButton.title, reportButton.title] }

  private func makeContent() -> NSView {
    let effect = NSVisualEffectView(frame: NSRect(origin: .zero, size: Self.size))
    effect.material = .popover
    effect.state = .active
    effect.wantsLayer = true
    effect.layer?.cornerRadius = 12
    effect.layer?.masksToBounds = true
    let icon = NSImageView(image: NSImage(systemSymbolName: "exclamationmark.triangle.fill", accessibilityDescription: nil) ?? NSImage())
    icon.symbolConfiguration = NSImage.SymbolConfiguration(pointSize: 18, weight: .regular)
    icon.contentTintColor = .systemYellow
    let label = NSTextField(wrappingLabelWithString: message)
    label.font = .systemFont(ofSize: 13, weight: .medium)
    label.maximumNumberOfLines = 2
    for (button, title, action) in [(notNowButton, "Not Now", #selector(notNow)), (reportButton, "Report", #selector(reportPressed))] {
      button.title = title
      button.bezelStyle = .push
      button.controlSize = .regular
      button.target = self
      button.action = action
      button.refusesFirstResponder = true
    }
    reportButton.bezelColor = .controlAccentColor
    for view in [icon, label, notNowButton, reportButton] as [NSView] {
      view.translatesAutoresizingMaskIntoConstraints = false
      effect.addSubview(view)
    }
    NSLayoutConstraint.activate([
      icon.leadingAnchor.constraint(equalTo: effect.leadingAnchor, constant: 16),
      icon.topAnchor.constraint(equalTo: effect.topAnchor, constant: 16),
      icon.widthAnchor.constraint(equalToConstant: 22),
      label.leadingAnchor.constraint(equalTo: icon.trailingAnchor, constant: 10),
      label.trailingAnchor.constraint(equalTo: effect.trailingAnchor, constant: -16),
      label.topAnchor.constraint(equalTo: effect.topAnchor, constant: 15),
      reportButton.trailingAnchor.constraint(equalTo: effect.trailingAnchor, constant: -14),
      reportButton.bottomAnchor.constraint(equalTo: effect.bottomAnchor, constant: -12),
      notNowButton.trailingAnchor.constraint(equalTo: reportButton.leadingAnchor, constant: -8),
      notNowButton.centerYAnchor.constraint(equalTo: reportButton.centerYAnchor),
    ])
    return effect
  }

  func place(over window: NSWindow) {
    let frame = window.frame
    let origin = NSPoint(x: frame.maxX - Self.size.width - 16, y: frame.maxY - Self.size.height - 60)
    setFrame(NSRect(origin: origin, size: Self.size), display: false)
  }

  @objc private func reportPressed() { onReport() }
  @objc private func notNow() { onNotNow() }

  #if DEBUG
  func press(_ name: String) {
    switch name {
    case "report": reportButton.performClick(nil)
    case "notNow": notNowButton.performClick(nil)
    default: break
    }
  }

  func click(_ name: String) -> Bool {
    let button: NSButton
    switch name {
    case "report": button = reportButton
    case "notNow": button = notNowButton
    default: return false
    }
    let point = button.convert(NSPoint(x: button.bounds.midX, y: button.bounds.midY), to: nil)
    func event(_ type: NSEvent.EventType) -> NSEvent? {
      NSEvent.mouseEvent(with: type, location: point, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
        windowNumber: windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: type == .leftMouseDown ? 1 : 0)
    }
    guard let down = event(.leftMouseDown), let up = event(.leftMouseUp) else { return false }
    NSApp.postEvent(up, atStart: false)
    sendEvent(down)
    return true
  }

  func snapshot(to url: URL) -> Bool {
    guard let view = contentView, let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { return false }
    view.cacheDisplay(in: view.bounds, to: rep)
    guard let png = rep.representation(using: .png, properties: [:]) else { return false }
    return (try? png.write(to: url)) != nil
  }
  #endif
}
