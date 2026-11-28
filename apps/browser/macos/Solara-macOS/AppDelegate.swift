import AppKit
import Expo
import React
import SolaraCore
import SolaraSettingsAdapter
import SolaraShell
import SolaraStoreAdapter
import SolaraSyncAdapter
import ReactAppDependencyProvider

final class AppDelegate: ExpoAppDelegate {
  private var reactNativeDelegate: ExpoReactNativeFactoryDelegate?
  private(set) var reactNativeFactory: RCTReactNativeFactory?
  private var storeUnavailable: Bool { MainActor.assumeIsolated { StoreUnavailableWindow.presented } }

  override func applicationDidFinishLaunching(_ notification: Notification) {
    #if SOLARA_PROBES
    MainActor.assumeIsolated { ProbeHost.start() }
    #endif
    #if DEBUG
    let environment = ProcessInfo.processInfo.environment
    let startsReactNativeAnyway = environment["SOLARA_TEST_START_RN_WHEN_UNAVAILABLE"] == "1" && environment["SOLARA_DATA_DIR"]?.isEmpty == false
    #else
    let startsReactNativeAnyway = false
    #endif
    if !startsReactNativeAnyway, MainActor.assumeIsolated({ StoreUnavailableWindow.presentIfLaunchFailed(handedOff: NativeStore.handedOff) }) { return }
    let delegate = ReactNativeDelegate()
    let factory = ExpoReactNativeFactory(delegate: delegate)
    delegate.dependencyProvider = RCTAppDependencyProvider()
    reactNativeDelegate = delegate
    reactNativeFactory = factory
    bindReactNativeFactory(factory)

    WindowHost.makeWindow = { BrowserWindow() }
    WindowHost.makeContentView = { [weak factory] windowId in
      (factory?.rootViewFactory as? ExpoReactRootViewFactory)?.superView(
        withModuleName: "main", initialProperties: ["windowId": windowId, "kind": WindowHost.openingKinds[windowId] ?? "browser"], launchOptions: nil) ?? NSView()
    }
    WindowHost.makeRootView = { [weak factory] module, props in
      (factory?.rootViewFactory as? ExpoReactRootViewFactory)?.superView(
        withModuleName: module, initialProperties: props, launchOptions: nil)
    }
    NativeLaunchScheduler.install()
    NativeSidebarPositionSupport.install()
    NativeHooks.start()
    factory.rootViewFactory.initializeReactHost(launchOptions: nil)

    super.applicationDidFinishLaunching(notification)
  }

  override func application(_ application: NSApplication, open urls: [URL]) {
    if storeUnavailable { return MainActor.assumeIsolated { StoreUnavailableWindow.droppedOpen(urls) } }
    let sourceApp = NSAppleEventManager.shared().currentAppleEvent != nil ? SolaraCoreHost.senderOfCurrentAppleEvent() : SolaraCoreHost.takeLaunchLinkSender()
    OpenURLInbox.receiveFromOutside(urls, sourceApp: sourceApp)
  }

  func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { storeUnavailable }

  func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
    ShellApp.shouldTerminate()
  }

  override func applicationWillTerminate(_ notification: Notification) {
    super.applicationWillTerminate(notification)
    atexit {
      fflush(nil)
      _exit(0)
    }
  }

  func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
    if storeUnavailable {
      MainActor.assumeIsolated { StoreUnavailableWindow.bringForward() }
      return false
    }
    return ShellApp.reopen(hasVisibleWindows: flag)
  }

  func applicationDockMenu(_ sender: NSApplication) -> NSMenu? {
    storeUnavailable ? nil : ShellApp.dockMenu()
  }

  override func application(_ application: NSApplication, willContinueUserActivityWithType userActivityType: String) -> Bool {
    if storeUnavailable { return false }
    return userActivityType == NSUserActivityTypeBrowsingWeb || super.application(application, willContinueUserActivityWithType: userActivityType)
  }

  override func application(
    _ application: NSApplication,
    continue userActivity: NSUserActivity,
    restorationHandler: @escaping ([any NSUserActivityRestoring]) -> Void
  ) -> Bool {
    if storeUnavailable { return false }
    return Handoff.continue(userActivity) || super.application(application, continue: userActivity, restorationHandler: restorationHandler)
  }

  func application(_ sender: NSApplication, delegateHandlesKey key: String) -> Bool {
    !storeUnavailable && ShellScripting.handles(key)
  }

  @objc var appleScriptWindows: [NSObject] { storeUnavailable ? [] : ShellScripting.windows }
  @objc var appleScriptProfiles: [NSObject] { storeUnavailable ? [] : ShellScripting.profiles }
  @objc var version: String { ShellScripting.version }
}

final class ReactNativeDelegate: ExpoReactNativeFactoryDelegate {
  override func sourceURL(for bridge: RCTBridge) -> URL? {
    bridge.bundleURL ?? bundleURL()
  }

  override func bundleURL() -> URL? {
    #if DEBUG
    if let location = ProcessInfo.processInfo.environment["SOLARA_JS_LOCATION"], !location.isEmpty {
      var arguments = UserDefaults.standard.volatileDomain(forName: UserDefaults.argumentDomain)
      arguments["RCT_jsLocation"] = location
      UserDefaults.standard.setVolatileDomain(arguments, forName: UserDefaults.argumentDomain)
    }
    return RCTBundleURLProvider.sharedSettings().jsBundleURL(forBundleRoot: "index")
    #else
    return Bundle.main.url(forResource: "main", withExtension: "jsbundle")
    #endif
  }
}
