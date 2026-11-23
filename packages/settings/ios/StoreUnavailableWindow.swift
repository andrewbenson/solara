import AppKit
import SolaraCore
import SolaraModel
import SolaraShell
import SolaraStore
import SolaraUI
import SwiftUI

@MainActor
public enum StoreUnavailableWindow {
  public private(set) static var presented = false
  private static var window: NSWindow?
  private static var hosting: NSHostingController<StoreUnavailableView>?
  private static var failure: StoreUnavailable?
  private static var reported: StoreUnavailableView.ReportedLink?
  private static var choices: [StoreUnavailableView.Choice] = []
  private static var context: StoreUnavailableView.Context = .launch
  private static var launchHideObserver: NSObjectProtocol?
  #if DEBUG
  private static var lastReportLink: String?
  private static var revealedFolder: String?
  private static var relaunchArguments: [String]?
  #endif

  private static var background: Bool { ProcessInfo.processInfo.environment["SOLARA_BACKGROUND"] == "1" }

  public static func presentIfLaunchFailed(handedOff: Bool) -> Bool {
    guard !NativeStoreHandle.opened, !handedOff, let failure = NativeSettingsHandle.unavailable else { return false }
    presented = true
    self.failure = failure
    choices = StoreUnavailableView.choices(
      failure: failure, context: .launch, safeModeAvailable: failure.offersSafeMode && LaunchSwitches.shared.usesDefaults,
      folderExists: StoreUnavailableView.folderExists(failure.dataFolder), reportAvailable: AdvancedAdapter.releaseRepo != nil)
    NSLog("[store] showing the store-unavailable window (%@, %@)", failure.causeName, choices.map(\.rawValue).joined(separator: ","))
    NSApp.mainMenu = makeMainMenu()
    if background {
      Task { @MainActor in showAtLaunch(failure) }
    } else {
      showAtLaunch(failure)
    }
    return true
  }

  private static func showAtLaunch(_ failure: StoreUnavailable) {
    showWithoutStealingFocus(makeWindow(failure))
    #if DEBUG
    traceVisibility()
    #endif
  }

  public static func presentForInertJS(detail: String) -> Bool {
    guard !presented else { return false }
    if let window, context == .inert {
      showWithoutStealingFocus(window)
      return true
    }
    let folder = try? DocumentStore.directoryURL()
    let failure = StoreUnavailable(cause: .openFailed, detail: detail, dataFolder: folder, errorType: "JSSavesNothing")
    self.failure = failure
    context = .inert
    choices = StoreUnavailableView.choices(
      failure: failure, context: .inert, safeModeAvailable: false,
      folderExists: StoreUnavailableView.folderExists(folder), reportAvailable: AdvancedAdapter.releaseRepo != nil)
    NSLog("[store] showing the store-unavailable window for a session that saves nothing (%@)", choices.map(\.rawValue).joined(separator: ","))
    showWithoutStealingFocus(makeWindow(failure))
    return true
  }

  public static var shown: Bool { window != nil }

  private static func makeWindow(_ failure: StoreUnavailable) -> NSWindow {
    let controller = NSHostingController(rootView: makeView(failure))
    controller.sizingOptions = []
    let made = NSWindow(contentViewController: controller)
    made.styleMask = [.titled, .closable, .miniaturizable]
    made.title = Bundle.main.productName
    made.isReleasedWhenClosed = false
    made.setContentSize(NSSize(width: 560, height: 440))
    made.center()
    hosting = controller
    window = made
    return made
  }

  public static func bringForward() {
    guard let window else { return }
    if background { return window.orderBack(nil) }
    NSApp.activate()
    window.makeKeyAndOrderFront(nil)
  }

  private static func showWithoutStealingFocus(_ window: NSWindow) {
    if background {
      window.orderBack(nil)
      orderBackAgainAfterLaunchHide()
    } else if SolaraCoreHost.launchedHidden {
      window.orderFront(nil)
    } else {
      NSApp.activate()
      window.makeKeyAndOrderFront(nil)
    }
  }

  private static func orderBackAgainAfterLaunchHide() {
    Task { @MainActor in orderBackIfHidden() }
    guard launchHideObserver == nil else { return }
    launchHideObserver = NotificationCenter.default.addObserver(forName: NSApplication.didHideNotification, object: nil, queue: .main) { _ in
      Task { @MainActor in
        if let observer = launchHideObserver { NotificationCenter.default.removeObserver(observer) }
        launchHideObserver = nil
        orderBackIfHidden()
      }
    }
  }

  private static func orderBackIfHidden() {
    guard let window, !window.isVisible else { return }
    window.orderBack(nil)
  }

  public static func droppedOpen(_ urls: [URL]) {
    let schemes = Set(urls.map { $0.scheme ?? "(none)" }).sorted().joined(separator: ",")
    NSLog("[store] store unavailable, not opening %ld link(s) (%@)", urls.count, schemes)
  }

  private static func makeView(_ failure: StoreUnavailable) -> StoreUnavailableView {
    StoreUnavailableView(
      failure: failure, appName: Bundle.main.productName, context: context, choices: choices, reported: reported,
      actions: .init(
        quit: { NSApp.terminate(nil) },
        showDataFolder: { showDataFolder($0) },
        openInSafeMode: { openInSafeMode() },
        reportBug: { reportBug() }))
  }

  private static func refresh() {
    guard let failure else { return }
    hosting?.rootView = makeView(failure)
  }

  private static func showDataFolder(_ folder: URL) {
    #if DEBUG
    revealedFolder = folder.path
    #endif
    if background { return NSLog("[store] background instance, not showing the data folder in Finder") }
    NSWorkspace.shared.activateFileViewerSelecting([folder])
  }

  private static func openInSafeMode() {
    guard choices.contains(.safeMode) else { return }
    let token = UUID().uuidString
    LaunchSwitches.requestSafeMode(token: token)
    #if DEBUG
    let development = true
    #else
    let development = false
    #endif
    let bundle = SafeModeRelaunch.originalBundleURL(Bundle.main.bundleURL)
    let arguments = SafeModeRelaunch.arguments(
      waitingFor: getpid(), bundlePath: bundle.path, executableName: Bundle.main.executableURL?.lastPathComponent ?? "Solara",
      environment: ProcessInfo.processInfo.environment, development: development,
      safeModeToken: token)
    #if DEBUG
    relaunchArguments = arguments.dropFirst(SafeModeRelaunch.fixedArgumentCount).map {
      $0.hasPrefix("\(LaunchSwitches.safeModeRequestVariable)=") ? "\(LaunchSwitches.safeModeRequestVariable)=<token>" : $0
    }
    #endif
    guard SafeModeRelaunch.spawn(arguments) else { return NSLog("[store] couldn't start the safe mode relaunch helper") }
    NSLog("[store] relaunching in safe mode once this instance quits")
    NSApp.terminate(nil)
  }

  private static func reportBug() {
    guard let failure else { return }
    let summary = StoreUnavailableReport.summary(
      failure, dataFolderPaths: StoreUnavailableReport.dataFolderPaths(failure.dataFolder), home: NSHomeDirectory())
    guard let link = NativeBugReport.shared.url(windowId: nil, crash: summary) else { return NSLog("[bug] no release repo in this build's identity") }
    #if DEBUG
    lastReportLink = link
    #endif
    let page = URL(string: link)
    NSLog("[bug] report link ready for %@://%@", page?.scheme ?? "", page?.host() ?? "")
    if background {
      NSLog("[bug] background instance, not copying the report link")
    } else {
      NSPasteboard.general.clearContents()
      NSPasteboard.general.setString(link, forType: .string)
    }
    reported = .init(link: link, copied: !background)
    refresh()
  }

  private static func makeMainMenu() -> NSMenu {
    let name = Bundle.main.productName
    let menu = NSMenu()
    func submenu(_ title: String, _ items: [NSMenuItem]) {
      let holder = NSMenuItem(title: title, action: nil, keyEquivalent: "")
      let inner = NSMenu(title: title)
      for item in items { inner.addItem(item) }
      holder.submenu = inner
      menu.addItem(holder)
    }
    let minimize = NSMenuItem(title: "Minimize", action: #selector(NSWindow.performMiniaturize(_:)), keyEquivalent: "m")
    submenu(name, [
      NSMenuItem(title: "Hide \(name)", action: #selector(NSApplication.hide(_:)), keyEquivalent: "h"),
      .separator(),
      NSMenuItem(title: "Quit \(name)", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q"),
    ])
    submenu("Edit", [
      NSMenuItem(title: "Copy", action: #selector(NSText.copy(_:)), keyEquivalent: "c"),
      NSMenuItem(title: "Select All", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a"),
    ])
    submenu("Window", [
      minimize,
      NSMenuItem(title: "Close", action: #selector(NSWindow.performClose(_:)), keyEquivalent: "w"),
    ])
    return menu
  }

  #if DEBUG
  public static func probeState() -> [String: Any] {
    let others = NSApp.windows.filter { $0 !== window && $0.isVisible }
    return [
      "shown": window?.isVisible ?? false,
      "cause": orNull(failure?.causeName),
      "errorType": orNull(failure?.errorType),
      "offersSafeMode": failure?.offersSafeMode ?? false,
      "launchWasSafeMode": failure?.launchWasSafeMode ?? false,
      "buttons": window != nil ? choices.map(\.rawValue) : [],
      "context": window == nil ? NSNull() : context == .inert ? "inert" : "launch",
      "windowCount": NSApp.windows.filter(\.isVisible).count,
      "otherWindows": others.map { NSStringFromClass(type(of: $0)) },
      "isKey": window?.isKeyWindow ?? false,
      "storeOpened": NativeStoreHandle.opened,
      "lastReport": orNull(lastReportLink),
      "reportCopied": reported?.copied ?? false,
      "revealedFolder": orNull(revealedFolder),
      "relaunchArguments": orNull(relaunchArguments),
    ]
  }

  private static func orNull(_ value: Any?) -> Any { value ?? NSNull() }

  #if DEBUG
  private static func onScreen(_ window: NSWindow) -> Bool {
    guard window.windowNumber > 0, let info = CGWindowListCopyWindowInfo(.optionIncludingWindow, CGWindowID(window.windowNumber)) as? [[String: Any]] else { return false }
    return info.first?[kCGWindowIsOnscreen as String] as? Bool ?? false
  }

  private static func traceVisibility() {
    guard ProcessInfo.processInfo.environment["SOLARA_DATA_DIR"]?.isEmpty == false, let window else { return }
    func line(_ when: String) {
      let visible = NSApp.windows.filter(\.isVisible).map { "\(type(of: $0))#\($0.windowNumber)" }
      NSLog(
        "[store] unavailable window %@: visible=%d onScreen=%d occlusionVisible=%d number=%ld level=%ld appHidden=%d appActive=%d policy=%ld frame=%@ screen=%d visibleWindows=%@",
        when, window.isVisible, onScreen(window),
        window.occlusionState.contains(.visible), window.windowNumber, window.level.rawValue, NSApp.isHidden, NSApp.isActive,
        NSApp.activationPolicy().rawValue, NSStringFromRect(window.frame), window.screen != nil, visible.joined(separator: ","))
    }
    line("shown")
    for delay in [0.0, 0.2, 1.0, 3.0] {
      DispatchQueue.main.asyncAfter(deadline: .now() + delay) { MainActor.assumeIsolated { line("after \(delay) s") } }
    }
    let center = NotificationCenter.default
    for name in [NSApplication.didHideNotification, NSApplication.didUnhideNotification, NSApplication.didFinishLaunchingNotification] {
      center.addObserver(forName: name, object: nil, queue: .main) { note in
        let name = note.name.rawValue
        MainActor.assumeIsolated { line(name) }
      }
    }
    for name in [NSWindow.willCloseNotification, NSWindow.didMiniaturizeNotification, NSWindow.didChangeOcclusionStateNotification] {
      center.addObserver(forName: name, object: window, queue: .main) { note in
        let name = note.name.rawValue
        MainActor.assumeIsolated { line(name) }
      }
    }
  }
  #endif

  public static func press(_ name: String) -> Bool {
    guard window != nil, let choice = StoreUnavailableView.Choice(rawValue: name), choices.contains(choice), let failure else { return false }
    NSLog("[store] pressed %@ in the store-unavailable window", name)
    switch choice {
    case .quit: NSApp.terminate(nil)
    case .safeMode: openInSafeMode()
    case .showFolder: if let folder = failure.dataFolder { showDataFolder(folder) }
    case .report: reportBug()
    }
    return true
  }
  #endif
}
