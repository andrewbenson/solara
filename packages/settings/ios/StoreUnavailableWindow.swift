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
    showWithoutStealingFocus(made)
    return true
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
    } else if SolaraCoreHost.launchedHidden {
      window.orderFront(nil)
    } else {
      NSApp.activate()
      window.makeKeyAndOrderFront(nil)
    }
  }

  public static func droppedOpen(_ urls: [URL]) {
    let schemes = Set(urls.map { $0.scheme ?? "(none)" }).sorted().joined(separator: ",")
    NSLog("[store] store unavailable, not opening %ld link(s) (%@)", urls.count, schemes)
  }

  private static func makeView(_ failure: StoreUnavailable) -> StoreUnavailableView {
    StoreUnavailableView(
      failure: failure, appName: Bundle.main.productName, context: .launch, choices: choices, reported: reported,
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
      "buttons": presented ? choices.map(\.rawValue) : [],
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

  public static func press(_ name: String) -> Bool {
    guard presented, let choice = StoreUnavailableView.Choice(rawValue: name), choices.contains(choice), let failure else { return false }
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
