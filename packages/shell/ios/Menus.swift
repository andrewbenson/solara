import AppKit

public enum NativeSidebarPositionCapability {
  nonisolated(unsafe) public static var enabled = false
}

public struct NativeBookmarkMenu {
  public struct Row {
    public let id: String
    public let title: String
    public let url: String?
    public let children: [Row]?

    public init(id: String, title: String, url: String? = nil, children: [Row]? = nil) {
      self.id = id
      self.title = title
      self.url = url
      self.children = children
    }
  }

  public let folders: [Row]
  public let recent: [Row]
  public let bar: [Row]
  public let other: [Row]

  public init(folders: [Row] = [], recent: [Row] = [], bar: [Row] = [], other: [Row] = []) {
    self.folders = folders
    self.recent = recent
    self.bar = bar
    self.other = other
  }
}

struct MenuState {
  struct Entry: Equatable {
    let id: String
    let title: String
    let current: Bool
  }

  static var current = MenuState()

  var warnBeforeQuitting = false
  var warnBeforeClosingWindow = false
  var undoReopensClosedTab = false
  var downloadsInProgress = 0
  var shortcuts: [String: [String]] = [:]
  var shortcutPrecedence: [String: String] = [:]
  var fromApp = false

  init() {}

  init(_ d: [String: Any]) {
    warnBeforeQuitting = d["warnBeforeQuitting"] as? Bool ?? false
    warnBeforeClosingWindow = d["warnBeforeClosingWindow"] as? Bool ?? false
    undoReopensClosedTab = d["undoReopensClosedTab"] as? Bool ?? false
    downloadsInProgress = d["downloadsInProgress"] as? Int ?? 0
    shortcuts = d["shortcuts"] as? [String: [String]] ?? [:]
    shortcutPrecedence = (d["shortcutPrecedence"] as? [String: Any] ?? [:]).compactMapValues { $0 as? String }
    fromApp = true

  }
}

protocol Rebindable: NSMenuItem {
  var shortcutId: String { get }
  var defaultTitle: String { get }
  var defaultKey: String { get }
  var defaultModifiers: NSEvent.ModifierFlags { get }
}

final class StandardItem: NSMenuItem, Rebindable {
  let shortcutId: String
  let defaultTitle: String
  let defaultKey: String
  let defaultModifiers: NSEvent.ModifierFlags

  init(_ title: String, _ action: Selector, key: String = "", _ mods: NSEvent.ModifierFlags = .command) {
    shortcutId = "std:" + NSStringFromSelector(action)
    defaultTitle = title
    defaultKey = key
    defaultModifiers = mods
    let shortcut = MainMenu.keyEquivalent(key, mods)
    super.init(title: title, action: action, keyEquivalent: shortcut.key)
    keyEquivalentModifierMask = shortcut.mods
    identifier = NSUserInterfaceItemIdentifier("solara.shortcut." + shortcutId)
  }

  override init(title: String, action: Selector?, keyEquivalent: String) {
    shortcutId = "std:" + (action.map(NSStringFromSelector) ?? title)
    defaultTitle = title
    defaultKey = keyEquivalent
    defaultModifiers = .command
    super.init(title: title, action: action, keyEquivalent: keyEquivalent)
    identifier = NSUserInterfaceItemIdentifier("solara.shortcut." + shortcutId)
  }

  required init(coder: NSCoder) { fatalError("init(coder:) is not supported") }
}

final class CommandItem: NSMenuItem, Rebindable {
  let command: String
  let arg: String?
  let defaultTitle: String
  var windowless = false
  var tracksChecked = true
  var hidesWhenDisabled = false
  private(set) var commandAlternateOf: CommandItem?
  let defaultKey: String
  let defaultModifiers: NSEvent.ModifierFlags

  var stateKey: String { arg.map { "\(command):\($0)" } ?? command }
  var shortcutId: String { stateKey }

  init(_ title: String, _ command: String, arg: String? = nil, key: String = "", _ mods: NSEvent.ModifierFlags = .command) {
    self.command = command
    self.arg = arg
    defaultTitle = title
    defaultKey = key
    defaultModifiers = mods
    let shortcut = MainMenu.keyEquivalent(key, mods)
    super.init(title: title, action: #selector(MenuTarget.performCommand(_:)), keyEquivalent: shortcut.key)
    keyEquivalentModifierMask = shortcut.mods
    identifier = NSUserInterfaceItemIdentifier("solara.command." + command)
    target = MenuTarget.shared
    tag = Self.chromeMenuTag
  }

  static let chromeMenuTag = 1

  required init(coder: NSCoder) { fatalError("init(coder:) is not supported") }

  func hiddenShortcut() -> CommandItem {
    isHidden = true
    allowsKeyEquivalentWhenHidden = true
    return self
  }

  func hiddenWhenDisabled() -> CommandItem {
    hidesWhenDisabled = true
    allowsKeyEquivalentWhenHidden = true
    return self
  }

  func alternate() -> CommandItem {
    isAlternate = true
    return self
  }

  func commandAlternate(of primary: CommandItem) -> CommandItem {
    commandAlternateOf = primary
    isAlternate = true
    return self
  }

  func followPrimaryShortcut(bound: Set<String>) {
    guard let primary = commandAlternateOf else { return }
    let mods = primary.keyEquivalentModifierMask.union(.command)
    if keyEquivalent != primary.keyEquivalent { keyEquivalent = primary.keyEquivalent }
    if keyEquivalentModifierMask != mods { keyEquivalentModifierMask = mods }
    let collides = !primary.keyEquivalent.isEmpty && bound.contains(MainMenu.comboKey(primary.keyEquivalent, mods))
    let hidden = primary.keyEquivalentModifierMask.contains(.command) || collides
    if isHidden != hidden { isHidden = hidden }
  }
}

enum SwitcherHold {
  static var onRelease: (() -> Void)?
  private static var held: NSEvent.ModifierFlags = []
  private static var serial = 0

  static func opened(by item: CommandItem) {
    let mods = MainMenu.heldModifiers(of: item)
    let event = NSApp.currentEvent
    held = !mods.isEmpty && event?.type == .keyDown && event?.modifierFlags.isSuperset(of: mods) == true ? mods : []
    serial += 1
    let receipt = serial
    if held.isEmpty { DispatchQueue.main.async { if receipt == serial { onRelease?() } } }
  }

  static func released(by flags: NSEvent.ModifierFlags) -> Bool {
    guard !held.isEmpty, !flags.isSuperset(of: held) else { return false }
    held = []
    return true
  }
}

public enum NativeMenuCommands {
  nonisolated(unsafe) public static var switcherRelease: (() -> Bool)?
  nonisolated(unsafe) public static var handlers: [String: (String?) -> Void] = [:]
  nonisolated(unsafe) public static var sidebarPositionInWindow: ((String) -> Bool)?
  nonisolated(unsafe) public static var browserRow: ((String, String?, String?) -> (enabled: Bool?, checked: Bool?, title: String?)?)?
  nonisolated(unsafe) public static var workspaceAvailability: ((String, String?, String?) -> Bool?)?
  nonisolated(unsafe) public static var argumentHandlers: [String: (String?, String?) -> Bool] = [:]
  nonisolated(unsafe) public static var keepsMenuDispatch: Set<String> = []
}

final class MenuTarget: NSObject, NSMenuItemValidation {
  static let shared = MenuTarget()
  var handler: ((String, String?, String?) -> Void)?

  static let focusMovingCommands: Set<String> = ["newTab", "focusCommandBar", "findInPage"]

  static func enabled(_ command: String, arg: String?, windowId: String?, browserEnabled: Bool?) -> Bool {
    if command == "findInPage", windowId == "settings" { return true }
    if command == "setSidebarPosition" {
      guard NativeSidebarPositionCapability.enabled, let windowId,
        NativeMenuCommands.sidebarPositionInWindow?(windowId) == true else { return false }
    }
    return browserEnabled != false && NativeMenuCommands.workspaceAvailability?(command, arg, windowId) != false
  }

  @objc(commandDispatch:) func performCommand(_ sender: NSMenuItem) {
    guard let item = sender as? CommandItem else { return }
    let windowId = item.windowless ? nil : WindowManager.shared.keyWindowId
    let row = NativeMenuCommands.browserRow?(item.command, item.arg, windowId)
    guard Self.enabled(item.command, arg: item.arg, windowId: windowId, browserEnabled: row?.enabled) else { return }
    var prepared = false
    if let run = NativeMenuCommands.argumentHandlers[item.command] {
      if NativeMenuCommands.keepsMenuDispatch.contains(item.command) {
        prepareDispatch(item.command)
        prepared = true
      }
      if run(item.arg, windowId) {
        if item.command == "tabSwitcher" { SwitcherHold.opened(by: item) }
        return
      }
    }
    if let run = NativeMenuCommands.handlers[item.command] {
      return run(windowId)
    }
    if !prepared { prepareDispatch(item.command) }
    handler?(item.command, item.arg, windowId)
    if item.command == "tabSwitcher" { SwitcherHold.opened(by: item) }
  }

  private func prepareDispatch(_ command: String) {
    _ = FocusHandoff.shared.takeBegun()
    let settled = !FocusHandoff.shared.gatesKeyWindow
    if Self.focusMovingCommands.contains(command) || FocusHandoff.shared.gatesKeyWindow, let window = NSApp.keyWindow {
      FocusHandoff.shared.begin(in: window)
    }
    if settled, let window = WindowManager.shared.keyBrowserWindow {
      NotificationCenter.default.post(name: Notification.Name("SolaraCommandWillDispatch"), object: window, userInfo: ["command": command])
    }
  }

  func dispatchCommand(_ command: String, arg: String?, windowId: String?) {
    if command == "closeWindow" { return closeWindow(nil) }
    if NativeMenuCommands.argumentHandlers[command]?(arg, windowId) == true { return }
    handler?(command, arg, windowId)
  }

  @objc(cut:) func cutEdit(_ sender: Any?) { forwardEdit(#selector(NSText.cut(_:)), from: sender) }
  @objc(copy:) func copyEdit(_ sender: Any?) { forwardEdit(#selector(NSText.copy(_:)), from: sender) }
  @objc(paste:) func pasteEdit(_ sender: Any?) { forwardEdit(#selector(NSText.paste(_:)), from: sender) }
  @objc(selectAll:) func selectAllEdit(_ sender: Any?) { forwardEdit(#selector(NSText.selectAll(_:)), from: sender) }

  static let undoAction = Selector(("undo:"))

  @objc(undo:) func undoOrReopenClosedTab(_ sender: Any?) {
    if Self.undoReopensClosedTab {
      if NativeMenuCommands.argumentHandlers["reopenClosedTab"]?(nil, WindowManager.shared.keyWindowId) != true {
        handler?("reopenClosedTab", nil, WindowManager.shared.keyWindowId)
      }
    } else {
      NSApp.sendAction(Self.undoAction, to: nil, from: sender)
    }
  }

  private static var undoReopensClosedTab: Bool {
    let state = MenuState.current
    let canReopen = NativeMenuCommands.workspaceAvailability?("reopenClosedTab", nil, WindowManager.shared.keyWindowId)
      ?? false
    guard state.undoReopensClosedTab, canReopen,
      WindowManager.shared.keyWindowId != "settings", let window = WindowManager.shared.keyBrowserWindow
    else { return false }
    return !MainMenu.editsText(window.firstResponder)
  }

  private func forwardEdit(_ action: Selector, from sender: Any?) {
    if FocusHandoff.shared.defers(action) { return }
    FocusHandoff.shared.noteForwarded(action)
    NSApp.sendAction(action, to: nil, from: sender)
  }

  private static func validateForwarded(_ menuItem: NSMenuItem, _ action: Selector) -> Bool {
    guard let target = NSApp.target(forAction: action) as? NSObject else { return false }
    typealias Validate = @convention(c) (AnyObject, Selector, NSMenuItem) -> ObjCBool
    for name in ["validateMenuItem:", "validateUserInterfaceItem:"] {
      let validate = NSSelectorFromString(name)
      if target.responds(to: validate) {
        return unsafeBitCast(target.method(for: validate), to: Validate.self)(target, validate, menuItem).boolValue
      }
    }
    return true
  }

  func validateMenuItem(_ menuItem: NSMenuItem) -> Bool {
    if let action = menuItem.action, FocusHandoff.editActions.contains(action), FocusHandoff.shared.gatesKeyWindow { return true }
    if let action = menuItem.action, FocusHandoff.editActions.contains(action), !(menuItem is CommandItem),
      action != #selector(pasteAndMatchStyle(_:)) {
      return Self.validateForwarded(menuItem, action)
    }
    if menuItem.action == #selector(closeWindow(_:)) { return WindowManager.shared.closableWindow != nil }
    if menuItem.action == #selector(toggleKeepOnTop(_:)) {
      guard let window = WindowManager.shared.keyBrowserWindow else { return false }
      menuItem.state = window.level == .floating ? .on : .off
      return true
    }
    if menuItem.action == Self.undoAction {
      let reopens = Self.undoReopensClosedTab
      let title = reopens ? "Undo Close Tab" : (menuItem as? StandardItem)?.defaultTitle ?? menuItem.title
      if menuItem.title != title { menuItem.title = title }
      return reopens || Self.validateForwarded(menuItem, Self.undoAction)
    }
    guard let item = menuItem as? CommandItem else { return true }
    let windowId = item.windowless ? nil : WindowManager.shared.keyWindowId
    let row = NativeMenuCommands.browserRow?(item.command, item.arg, windowId)
    if item.tracksChecked { item.state = row?.checked == true ? .on : .off }
    let title = row?.title ?? item.defaultTitle
    if item.title != title { item.title = title }
    if item.keyEquivalent == "\r", NSApp.keyWindow?.firstResponder is NSText { return false }
    if MainMenu.movesCaret(item), NSApp.currentEvent?.type == .keyDown, MainMenu.editsText(NSApp.keyWindow?.firstResponder) { return false }
    let enabled = Self.enabled(item.command, arg: item.arg, windowId: windowId, browserEnabled: row?.enabled)
    if item.hidesWhenDisabled, item.isHidden == enabled { item.isHidden = !enabled }
    return enabled
  }

  @objc func quit(_ sender: Any?) { WindowManager.shared.confirmQuit() }
  @objc func arrangeWindowsInFront(_ sender: Any?) { NSApp.arrangeInFront(sender) }
  @objc func toggleKeepOnTop(_ sender: Any?) { WindowManager.shared.toggleKeepOnTop() }
  @objc func closeWindow(_ sender: Any?) { WindowManager.shared.closableWindow?.performClose(sender) }

  @objc func pasteAndMatchStyle(_ sender: Any?) {
    let web = Selector(("pasteAndMatchStyle:"))
    if FocusHandoff.shared.defers(web) { return }
    if NSApp.target(forAction: web) != nil {
      NSApp.sendAction(web, to: nil, from: sender)
    } else {
      NSApp.sendAction(#selector(NSTextView.pasteAsPlainText(_:)), to: nil, from: sender)
    }
  }
}

enum MainMenu {
  private static var moveToProfile = NSMenu(title: "Move to Profile")
  private static var moveToWindow = NSMenu(title: "Move to Window")
  private static var bookmarkToFolder = NSMenu(title: "Add Bookmark to Folder")
  private static var profiles = NSMenu(title: "Profiles")
  private static var profilesItem = NSMenuItem(title: "Profiles", action: nil, keyEquivalent: "")
  private static var profilesSeparator = NSMenuItem.separator()
  private static var littleSolaraInProfile = NSMenu(title: "New Little \(Bundle.main.productName) Window in Profile")
  private static var littleSolaraInProfileItem = NSMenuItem(title: "New Little \(Bundle.main.productName) Window in Profile", action: nil, keyEquivalent: "")
  private static var bookmarks = NSMenu(title: "Bookmarks")
  private static var bookmarksFixedCount = 0
  private static var history = NSMenu(title: "History")
  private static var extensions = NSMenu(title: "Extensions")
  private static var extensionIcons: [String: NSImage] = [:]
  private static var undo: StandardItem?

  static func build() -> NSMenu {
    let appName = Bundle.main.productName
    let main = NSMenu()
    moveToProfile = NSMenu(title: "Move to Profile")
    moveToWindow = NSMenu(title: "Move to Window")
    bookmarkToFolder = NSMenu(title: "Add Bookmark to Folder")
    profiles = NSMenu(title: "Profiles")
    profilesSeparator = NSMenuItem.separator()
    littleSolaraInProfile = NSMenu(title: "New Little \(Bundle.main.productName) Window in Profile")

    func std(_ title: String, _ action: Selector, _ key: String = "", _ mods: NSEvent.ModifierFlags = .command) -> StandardItem {
      StandardItem(title, action, key: key, mods)
    }
    func sub(_ title: String, _ items: [NSMenuItem], menu: NSMenu? = nil) -> NSMenuItem {
      let submenu = menu ?? NSMenu(title: title)
      submenu.autoenablesItems = true
      items.forEach(submenu.addItem)
      let root = NSMenuItem(title: title, action: nil, keyEquivalent: "")
      root.submenu = submenu
      return root
    }
    func top(_ title: String, _ items: [NSMenuItem], menu: NSMenu? = nil) -> NSMenu {
      let item = sub(title, items, menu: menu)
      main.addItem(item)
      return item.submenu!
    }
    func cmd(_ title: String, _ command: String, arg: String? = nil, _ key: String = "", _ mods: NSEvent.ModifierFlags = .command) -> CommandItem {
      CommandItem(title, command, arg: arg, key: key, mods)
    }

    let shareMenu = NSMenu(title: "Share")
    shareMenu.delegate = ShareMenu.shared

    let quit = std("Quit \(appName)", #selector(MenuTarget.quit(_:)), "q")
    quit.target = MenuTarget.shared
    let closeWindow = std("Close Window", #selector(MenuTarget.closeWindow(_:)), "w", [.command, .shift])
    closeWindow.target = MenuTarget.shared
    let services = NSMenu(title: "Services")
    NSApp.servicesMenu = services
    _ = top(appName, [
      aboutItem("About \(appName)"),
      updatesItem(),
      restartToUpdateItem(appName),
      .separator(),
      cmd("Settings…", "openSettings", ","),
      cmd("Import from Another Browser…", "importBrowserData"),
      .separator(),
      sub("Services", [], menu: services),
      .separator(),
      std("Hide \(appName)", #selector(NSApplication.hide(_:)), "h"),
      std("Hide Others", #selector(NSApplication.hideOtherApplications(_:)), "h", [.command, .option]),
      std("Show All", #selector(NSApplication.unhideAllApplications(_:))),
      .separator(),
      quit,
    ])

    littleSolaraInProfileItem = sub("New Little \(Bundle.main.productName) Window in Profile", [], menu: littleSolaraInProfile)
    _ = top("File", [
      cmd("New Tab", "newTab", "t"),
      cmd("New Tab in Group", "newTabInGroup", "t", [.command, .option]),
      cmd("New Window", "newWindow", "n"),
      cmd("New Incognito Window", "newIncognitoWindow", "n", [.command, .shift]),
      cmd("New Little \(Bundle.main.productName) Window", "newLittleSolara", "n", [.command, .option]),
      littleSolaraInProfileItem,
      cmd("Open Links from Other Apps in Main Window", "toggleOpenLinksInLittleSolara"),
      cmd("Reopen Closed Tab", "reopenClosedTab", "t", [.command, .shift]),
      cmd("Reopen Closed Window", "reopenClosedWindow"),
      cmd("Open File…", "openFile", "o"),
      .separator(),
      cmd("Open Command Bar", "focusCommandBar", "l"),
      cmd("Open Command Bar", "focusCommandBar", functionKey(NSF5FunctionKey), .control).hiddenShortcut(),
      .separator(),
      closeWindow,
      cmd("Close Tab", "closeTab", "w"),
      cmd("Close All Tabs", "closeAllTabs", "k", [.command, .shift]),
      cmd("Clean Up Tabs", "cleanUpTabs", "k", [.command, .option]),
      .separator(),
      cmd("Save Page As…", "savePage"),
      cmd("Share…", "share", "s", [.command, .option]),
      sub("Share", [], menu: shareMenu),
      cmd("Email Page Location", "emailPageLocation", "i", [.command, .shift]),
      cmd("Print…", "print", "p"),
      cmd("Print Using System Dialog…", "printWithSystemDialog", "p", [.command, .option]),
    ])

    let paste = std("Paste and Match Style", #selector(MenuTarget.pasteAndMatchStyle(_:)), "v", [.command, .shift])
    paste.target = MenuTarget.shared
    let edits = [
      std("Cut", #selector(NSText.cut(_:)), "x"), std("Copy", #selector(NSText.copy(_:)), "c"),
      std("Paste", #selector(NSText.paste(_:)), "v"), std("Select All", #selector(NSText.selectAll(_:)), "a"),
    ]
    edits.forEach { $0.target = MenuTarget.shared }
    let undo = std("Undo", MenuTarget.undoAction, "z")
    Self.undo = undo
    _ = top("Edit", [
      undo,
      std("Redo", Selector(("redo:")), "z", [.command, .shift]),
      .separator(),
      edits[0],
      edits[1],
      cmd("Copy URL", "copyUrl", "c", [.command, .shift]),
      cmd("Copy URL as Markdown", "copyUrlAsMarkdown", "c", [.command, .option, .shift]),
      edits[2],
      paste,
      std("Delete", #selector(NSText.delete(_:))),
      edits[3],
      .separator(),
      sub("Find", [
        cmd("Find…", "findInPage", "f"),
        cmd("Find and Replace…", "findAndReplace", "f", [.command, .option]),
        cmd("Find Next", "findNext", "g"),
        cmd("Find Previous", "findPrevious", "g", [.command, .shift]),
        cmd("Use Selection for Find", "useSelectionForFind", "e"),
        cmd("Jump to Selection", "jumpToSelection", "j"),
      ]),
      sub("Spelling and Grammar", [
        std("Show Spelling and Grammar", #selector(NSText.showGuessPanel(_:)), ":"),
        std("Check Document Now", #selector(NSText.checkSpelling(_:)), ";"),
        .separator(),
        std("Check Spelling While Typing", #selector(NSTextView.toggleContinuousSpellChecking(_:))),
        std("Check Grammar With Spelling", #selector(NSTextView.toggleGrammarChecking(_:))),
        std("Correct Spelling Automatically", #selector(NSTextView.toggleAutomaticSpellingCorrection(_:))),
      ]),
      sub("Substitutions", [
        std("Show Substitutions", #selector(NSTextView.orderFrontSubstitutionsPanel(_:))),
        .separator(),
        std("Smart Copy/Paste", #selector(NSTextView.toggleSmartInsertDelete(_:))),
        std("Smart Quotes", #selector(NSTextView.toggleAutomaticQuoteSubstitution(_:))),
        std("Smart Dashes", #selector(NSTextView.toggleAutomaticDashSubstitution(_:))),
        std("Smart Links", #selector(NSTextView.toggleAutomaticLinkDetection(_:))),
        std("Data Detectors", #selector(NSTextView.toggleAutomaticDataDetection(_:))),
        std("Text Replacement", #selector(NSTextView.toggleAutomaticTextReplacement(_:))),
      ]),
      sub("Transformations", [
        std("Make Upper Case", #selector(NSResponder.uppercaseWord(_:))),
        std("Make Lower Case", #selector(NSResponder.lowercaseWord(_:))),
        std("Capitalize", #selector(NSResponder.capitalizeWord(_:))),
      ]),
      sub("Speech", [
        std("Start Speaking", #selector(NSTextView.startSpeaking(_:))),
        std("Stop Speaking", #selector(NSTextView.stopSpeaking(_:))),
      ]),
      sub("AutoFill", [
        cmd("Contact…", "autofill", arg: "contact"),
        cmd("Passwords…", "autofill", arg: "passwords"),
        cmd("Credit Card…", "autofill", arg: "creditCard"),
      ]),
    ])

    let fullScreen = std("Enter Full Screen", #selector(NSWindow.toggleFullScreen(_:)), "f", .function)
    let fullScreenAlias = std("Enter Full Screen", #selector(NSWindow.toggleFullScreen(_:)), "f", [.command, .control])
    fullScreenAlias.isHidden = true
    fullScreenAlias.allowsKeyEquivalentWhenHidden = true
    _ = top("View", [
      sub("Appearance", [
        cmd("Automatic", "setAppearance", arg: "auto"),
        cmd("Light", "setAppearance", arg: "light"),
        cmd("Dark", "setAppearance", arg: "dark"),
      ]),
      cmd("Stop", "stop", "."),
      cmd("Refresh", "reload", "r"),
      cmd("Force Refresh the Page", "forceReload", "r", [.command, .shift]).alternate(),
      .separator(),
      cmd("Show Tabs in Sidebar", "toggleTabLayout", "s", [.command, .shift]),
      cmd("Auto-Hide Tabs", "toggleSidebar", "s"),
      cmd("Auto-Hide Tabs", "toggleSidebar", "l", [.command, .shift]).hiddenShortcut(),
      cmd("Auto-Hide Tabs", "toggleSidebar", "f", [.command, .shift]).hiddenShortcut(),
      cmd("Icons-Only Sidebar", "toggleSidebarIconsOnly"),
      ] + (NativeSidebarPositionCapability.enabled ? [
        sub("Sidebar Position", [
          cmd("Left", "setSidebarPosition", arg: "left"),
          cmd("Right", "setSidebarPosition", arg: "right"),
        ]),
      ] : []) + [
      .separator(),
      cmd("Open Split Pane", "openSplitPane", "=", [.control, .shift]),
      cmd("Focus Next Split Pane", "focusNextPane", "]", [.control, .shift]),
      cmd("Focus Previous Split Pane", "focusPreviousPane", "[", [.control, .shift]),
      cmd("Open Split Pane", "openSplitPane", "+", .control).hiddenShortcut(),
      cmd("Focus Next Split Pane", "focusNextPane", "}", .control).hiddenShortcut(),
      cmd("Focus Previous Split Pane", "focusPreviousPane", "{", .control).hiddenShortcut(),
      .separator(),
      sub("Show Bookmarks Bar", [
        cmd("Always", "setBookmarksBar", arg: "always"),
        cmd("On New Tab Only", "setBookmarksBar", arg: "newTab"),
        cmd("Never", "setBookmarksBar", arg: "never"),
        .separator(),
        cmd("Toggle Bookmarks Bar", "toggleBookmarksBar", "b", [.command, .shift]),
      ]),
      .separator(),
      cmd("Show Full URL", "toggleFullUrl"),
      cmd("Show Address Bar in Sidebar", "toggleAddressBar"),
      cmd("Cast…", "cast"),
      cmd("Open Page in WebKit", "togglePageEngine"),
      .separator(),
      cmd("Zoom to Actual Size", "zoomReset", "0"),
      cmd("Zoom In", "zoomIn", "+"),
      cmd("Zoom In", "zoomIn", "=").hiddenShortcut(),
      cmd("Zoom Out", "zoomOut", "-"),
      .separator(),
      fullScreen,
      fullScreenAlias,
      .separator(),
      sub("Developer", [
        cmd("View Source", "viewSource", "u", [.command, .option]),
        cmd("Developer Tools", "devTools", "i", [.command, .option]),
        cmd("Inspect Elements", "inspectElements", "c", [.command, .option]),
        cmd("JavaScript Console", "javaScriptConsole", "j", [.command, .option]),
        cmd("Turn on Developer Mode for this site", "toggleDeveloperMode"),
        cmd("Allow JavaScript from Apple Events", "toggleJavaScriptFromAppleEvents"),
        cmd("Toggle Developer Tools", "toggleDevTools", functionKey(NSF12FunctionKey), []).hiddenShortcut(),
        cmd("Caret Browsing", "caretBrowsing", functionKey(NSF7FunctionKey), []).hiddenShortcut(),
      ]),
    ])

    let selectTab = (1...8).map { cmd("Select Tab \($0)", "selectTab", arg: "\($0)", "\($0)").hiddenShortcut() }
    _ = top("Tabs", [
      cmd("Go Back", "back", "["),
      cmd("Go Forward", "forward", "]"),
      cmd("Go Back", "back", leftArrow).hiddenShortcut(),
      cmd("Go Forward", "forward", rightArrow).hiddenShortcut(),
      .separator(),
      cmd("Next Tab", "nextTab", "]", [.command, .shift]),
      cmd("Previous Tab", "previousTab", "[", [.command, .shift]),
      cmd("Next Tab", "nextTab", "}").hiddenShortcut(),
      cmd("Previous Tab", "previousTab", "{").hiddenShortcut(),
      cmd("Next Tab", "nextTab", functionKey(NSPageDownFunctionKey), .control).hiddenShortcut(),
      cmd("Previous Tab", "previousTab", functionKey(NSPageUpFunctionKey), .control).hiddenShortcut(),
      cmd("Next Tab", "nextTab", functionKey(NSDownArrowFunctionKey), [.command, .option]).hiddenShortcut(),
      cmd("Previous Tab", "previousTab", functionKey(NSUpArrowFunctionKey), [.command, .option]).hiddenShortcut(),
      cmd("Move Tab Down", "moveTabDown", functionKey(NSPageDownFunctionKey), [.control, .shift]).hiddenShortcut(),
      cmd("Move Tab Up", "moveTabUp", functionKey(NSPageUpFunctionKey), [.control, .shift]).hiddenShortcut(),
      cmd("Search Tabs…", "searchTabs", "a", [.command, .shift]),
      cmd("Next Tab", "nextTab", "\t", .control).hiddenShortcut(),
      cmd("Previous Tab", "previousTab", "\t", [.control, .shift]).hiddenShortcut(),
      cmd("Tab Switcher (forward)", "tabSwitcher", arg: "forward", "`", .control).hiddenShortcut(),
      cmd("Tab Switcher (backward)", "tabSwitcher", arg: "backward").hiddenShortcut(),
      cmd("Back to Pinned URL", "returnToPinnedUrl", "\r").hiddenShortcut(),
    ] + selectTab + [
      cmd("Select Last Tab", "selectLastTab", "9").hiddenShortcut(),
      .separator(),
      cmd("Move to Top Apps", "togglePin"),
      cmd("Move Pinned Tab to Top Apps", "togglePin", arg: "tile").hiddenWhenDisabled(),
      cmd("Move to Pinned", "togglePinnedRow", "d"),
      cmd("Duplicate", "duplicateTab"),
      cmd("New Group with Tab", "newGroupWithTabs", "n", [.command, .control]),
      cmd("New Group with Tab", "newGroupWithTabs", "p", [.command, .control]).hiddenShortcut(),
      cmd("New Tab in Group", "newTabInGroup", "c", [.command, .control]).hiddenShortcut(),
      cmd("Close Group", "closeTabGroup", "w", [.command, .control]).hiddenShortcut(),
      .separator(),
      sub("Move to Profile", [], menu: moveToProfile),
      sub("Move to Window", [], menu: moveToWindow),
      .separator(),
      cmd("Add to Bookmarks…", "bookmarkPage", "d", [.command, .option, .shift]),
      sub("Add Bookmark to Folder", [], menu: bookmarkToFolder),
      .separator(),
      cmd("Rename…", "renameTab"),
      cmd("Change Icon…", "changeTabIcon"),
      cmd("Mute Site", "toggleMute"),
    ])

    bookmarks = top("Bookmarks", [
      cmd("Bookmark This Page", "bookmarkPage", "d", [.command, .option, .shift]),
      cmd("Bookmark All Tabs…", "bookmarkAllTabs", "d", [.command, .shift]),
      cmd("Manage Bookmarks", "manageBookmarks", "b", [.command, .option]),
    ])
    bookmarksFixedCount = bookmarks.items.count
    history = top("History", [])
    extensions = top("Extensions", [])

    profilesItem = sub("Profiles", [], menu: profiles)
    let minimizeAll = std("Minimize All", #selector(NSApplication.miniaturizeAll(_:)), "m", [.command, .option])
    let arrange = std("Arrange in Front", #selector(MenuTarget.arrangeWindowsInFront(_:)))
    arrange.target = MenuTarget.shared
    let keepOnTop = std("Keep Window on Top", #selector(MenuTarget.toggleKeepOnTop(_:)))
    keepOnTop.target = MenuTarget.shared
    minimizeAll.isAlternate = true
    let windowMenu = top("Window", [
      std("Minimize", #selector(NSWindow.performMiniaturize(_:)), "m"),
      minimizeAll,
      std("Zoom", #selector(NSWindow.performZoom(_:))),
      arrange,
      keepOnTop,
      .separator(),
      cmd("Downloads", "downloads", "j", [.command, .shift]),
      cmd("Downloads", "downloads", "l", [.command, .option]).hiddenShortcut(),
      CommandItem("Task Manager", "taskManager", key: ""),
      cmd("Merge All Windows", "mergeAllWindows"),
      profilesSeparator,
      profilesItem,
      cmd("Show Profiles Menu", "openProfileMenu", "m", [.command, .shift]).hiddenShortcut(),
    ])
    NSApp.windowsMenu = windowMenu

    NSApp.helpMenu = top("Help", helpItems())

    built = nil
    refreshBookmarkMenus()
    refresh()
    return main
  }

  static func keyEquivalent(_ key: String, _ mods: NSEvent.ModifierFlags) -> (key: String, mods: NSEvent.ModifierFlags) {
    guard mods.contains(.shift), key.count == 1, let scalar = key.unicodeScalars.first, ("a"..."z").contains(scalar) else {
      return (key, mods)
    }
    return (key.uppercased(), mods.subtracting(.shift))
  }

  private static func shortcut(of item: NSMenuItem) -> (key: String, mods: NSEvent.ModifierFlags) {
    let key = item.keyEquivalent
    guard key.count == 1, key != key.lowercased() else { return (key, item.keyEquivalentModifierMask) }
    return (key.lowercased(), item.keyEquivalentModifierMask.union(.shift))
  }

  private static func switcherItems() -> [CommandItem] {
    var items: [CommandItem] = []
    walk(NSApp.mainMenu) { item, _ in
      if let item = item as? CommandItem, item.command == "tabSwitcher", !item.keyEquivalent.isEmpty { items.append(item) }
    }
    return items
  }

  static func heldModifiers(of item: NSMenuItem) -> NSEvent.ModifierFlags {
    let mods = shortcut(of: item).mods
    let held = mods.intersection([.control, .option, .command])
    return held.isEmpty ? mods.intersection(.shift) : held
  }

  static func isSwitcherKey(_ event: NSEvent) -> Bool {
    var key = (event.charactersIgnoringModifiers ?? "").lowercased()
    if key == "\u{19}" { key = "\t" }
    let mods = event.modifierFlags.intersection([.control, .option, .command, .shift])
    return switcherItems().contains { item in
      let combo = shortcut(of: item)
      return combo.key.lowercased() == key && combo.mods.intersection([.control, .option, .command]) == mods.subtracting(.shift)
    }
  }

  private static func functionKey(_ key: Int) -> String { String(Character(UnicodeScalar(UInt16(key))!)) }
  static let leftArrow = functionKey(NSLeftArrowFunctionKey), rightArrow = functionKey(NSRightArrowFunctionKey)
  private static let caretArrows: Set<String> = [
    leftArrow, rightArrow, functionKey(NSUpArrowFunctionKey), functionKey(NSDownArrowFunctionKey),
  ]

  static func movesCaret(_ item: NSMenuItem) -> Bool {
    let mods = item.keyEquivalentModifierMask.intersection([.command, .shift, .option, .control])
    return caretArrows.contains(item.keyEquivalent) && (mods == .command || mods == [.command, .shift])
  }

  static func editsText(_ responder: NSResponder?) -> Bool {
    if responder is NSText { return true }
    let textInputType = NSSelectorFromString("textInputType")
    guard let page = responder, FocusHandoff.isPage(page), page.responds(to: textInputType) else { return false }
    typealias Getter = @convention(c) (AnyObject, Selector) -> Int32
    return unsafeBitCast(page.method(for: textInputType), to: Getter.self)(page, textInputType) != 0
  }

  private static func aboutItem(_ title: String) -> NSMenuItem {
    let item = NSMenuItem(title: title, action: #selector(AppUpdater.showAbout(_:)), keyEquivalent: "")
    item.target = AppUpdater.shared
    return item
  }

  private static func updatesItem() -> NSMenuItem {
    let item = NSMenuItem(title: "Check for Updates…", action: #selector(AppUpdater.checkForUpdates(_:)), keyEquivalent: "")
    item.target = AppUpdater.shared
    item.isHidden = !AppUpdater.shared.isAvailable
    return item
  }

  private static var restartToUpdate: NSMenuItem?
  private static var pendingUpdateObserver: NSObjectProtocol?

  private static func restartToUpdateItem(_ appName: String) -> NSMenuItem {
    let item = NSMenuItem(title: "Restart to Update \(appName)", action: #selector(AppUpdater.installPendingUpdate(_:)), keyEquivalent: "")
    item.target = AppUpdater.shared
    restartToUpdate = item
    showRestartToUpdate()
    if pendingUpdateObserver == nil {
      pendingUpdateObserver = NotificationCenter.default.addObserver(forName: AppUpdater.pendingUpdateChanged, object: nil, queue: .main) { _ in
        showRestartToUpdate()
      }
    }
    return item
  }

  #if DEBUG
  static var restartToUpdateShown: Bool? { restartToUpdate.map { !$0.isHidden } }
  #endif

  private static func showRestartToUpdate() {
    let pending = AppUpdater.shared.pendingUpdate
    restartToUpdate?.isHidden = pending == nil
    restartToUpdate?.toolTip = pending.map { "Installs \(Bundle.main.productName) \($0.version) and reopens your windows and tabs." }
  }

  private static func videoTourItem() -> NSMenuItem {
    let item = CommandItem("Video Tour", "videoTour", key: "")
    let url = Bundle.main.object(forInfoDictionaryKey: "ACVideoTourURL") as? String ?? ""
    item.isHidden = URL(string: url)?.scheme?.hasPrefix("http") != true
    return item
  }

  private static func releaseNotesItem() -> NSMenuItem {
    let item = CommandItem("Release Notes", "releaseNotes", key: "")
    let url = Bundle.main.object(forInfoDictionaryKey: "ACReleaseNotesURL") as? String ?? ""
    item.isHidden = URL(string: url)?.scheme?.hasPrefix("http") != true
    return item
  }

  private static func helpItems() -> [NSMenuItem] {
    var items: [NSMenuItem] = [
      CommandItem("Report a Bug…", "reportBug", key: ""),
      CommandItem("Send Feedback…", "sendFeedback", key: "i", [.command, .option, .shift]),
      CommandItem("Keyboard Shortcuts", "keyboardShortcuts", key: ""),
      CommandItem("Tool Tour", "toolTour", key: ""),
      videoTourItem(),
      releaseNotesItem(),
      .separator(),
      CommandItem("Copy Diagnostics", "copyDiagnostics", key: ""),
      CommandItem("Record Performance Issue…", "recordPerformanceIssue", key: ""),
    ]
    #if DEBUG
    items += [.separator(), CommandItem("Show Onboarding", "showOnboarding", key: "")]
    #endif
    return items
  }

  private static func extensionIcon(_ dataURL: String?) -> NSImage? {
    guard let dataURL, let comma = dataURL.firstIndex(of: ",") else { return nil }
    if let cached = extensionIcons[dataURL] { return cached }
    guard let data = Data(base64Encoded: String(dataURL[dataURL.index(after: comma)...])),
      let image = NSImage(data: data)
    else { return nil }
    image.size = NSSize(width: 16, height: 16)
    extensionIcons[dataURL] = image
    return image
  }

  private static var built: (profiles: [MenuState.Entry], windows: [MenuState.Entry], extensions: [String])?
  private static var profileEntries: [MenuState.Entry] = []
  private static var windowEntries: [MenuState.Entry] = []

  static func setWorkspaceDestinations(profiles: [(id: String, title: String, current: Bool)], windows: [(id: String, title: String)]) {
    let profiles = profiles.map { MenuState.Entry(id: $0.id, title: $0.title, current: $0.current) }
    let windows = windows.map { MenuState.Entry(id: $0.id, title: $0.title, current: false) }
    guard profiles != profileEntries || windows != windowEntries else { return }
    profileEntries = profiles
    windowEntries = windows
    refresh()
  }

  private static var recentlyClosed: [MenuState.Entry] = []
  private static var recentlyClosedGroups: [MenuState.Entry] = []

  static func setRecentlyClosed(entries: [(id: String, title: String)], groups: [(id: String, title: String)]) {
    let entries = entries.map { MenuState.Entry(id: $0.id, title: $0.title, current: false) }
    let groups = groups.map { MenuState.Entry(id: $0.id, title: $0.title, current: false) }
    guard entries != recentlyClosed || groups != recentlyClosedGroups else { return }
    recentlyClosed = entries
    recentlyClosedGroups = groups
    buildHistory()
    applyShortcuts(MenuState.current.shortcuts)
  }

  static func refresh() {
    let state = MenuState.current
    let extensionRows: [(id: String, title: String, icon: String?)] = MainActor.assumeIsolated {
      (ShellMenus.extensionCatalog?() ?? []).map {
        (id: $0["id"] as? String ?? "", title: $0["title"] as? String ?? "", icon: $0["icon"] as? String)
      }
    }
    let last = built
    let extensionKeys = extensionRows.map { "\($0.id)|\($0.title)|\($0.icon ?? "")" }
    built = (profileEntries, windowEntries, extensionKeys)
    if last?.profiles != profileEntries { buildProfileMenus() }
    if last?.windows != windowEntries { buildMoveToWindow() }
    if last?.extensions != extensionKeys { buildExtensions(extensionRows) }
    if last == nil { buildHistory() }
    if let undo, (undo.target != nil) != state.undoReopensClosedTab {
      undo.target = state.undoReopensClosedTab ? MenuTarget.shared : nil
      undo.title = undo.defaultTitle
    }
    applyShortcuts(state.shortcuts)
  }

  private static func buildProfileMenus() {
    moveToProfile.removeAllItems()
    for p in profileEntries {
      let item = CommandItem(p.title, "moveTabToProfile", arg: p.id)
      item.tracksChecked = false
      item.state = p.current ? .on : .off
      moveToProfile.addItem(item)
    }
    moveToProfile.addItem(.separator())
    moveToProfile.addItem(CommandItem("New Profile…", "moveTabToProfile", arg: "new"))

    profiles.removeAllItems()
    profilesItem.isHidden = profileEntries.count < 2
    profilesSeparator.isHidden = profilesItem.isHidden
    for (i, p) in profileEntries.enumerated() {
      let item = CommandItem(p.title, "switchProfile", arg: p.id, key: i < 9 ? "\(i + 1)" : "", .control)
      item.tracksChecked = false
      item.state = p.current ? .on : .off
      profiles.addItem(item)
      let newWindow = CommandItem("\(p.title) ↗", "newWindow", arg: p.id, key: "", []).commandAlternate(of: item)
      newWindow.tracksChecked = false
      profiles.addItem(newWindow)
    }
    profiles.addItem(.separator())
    profiles.addItem(CommandItem("Next Profile", "nextProfile", key: rightArrow, [.command, .option]))
    profiles.addItem(CommandItem("Previous Profile", "previousProfile", key: leftArrow, [.command, .option]))
    profiles.addItem(.separator())
    profiles.addItem(CommandItem("New Profile…", "newProfile"))

    littleSolaraInProfile.removeAllItems()
    littleSolaraInProfileItem.isHidden = profileEntries.count < 2
    for p in profileEntries { littleSolaraInProfile.addItem(CommandItem(p.title, "newLittleSolara", arg: p.id)) }
  }

  private static func buildMoveToWindow() {
    moveToWindow.removeAllItems()
    for w in windowEntries { moveToWindow.addItem(CommandItem(w.title, "moveTabToWindow", arg: w.id)) }
    if !windowEntries.isEmpty { moveToWindow.addItem(.separator()) }
    moveToWindow.addItem(CommandItem("New Window", "moveTabToWindow", arg: "new"))
  }

  static var bookmarkMenuSource: (() -> NativeBookmarkMenu)?

  static func refreshBookmarkMenus() { buildBookmarkMenus() }

  private static func buildBookmarkMenus() {
    deferBookmarkMenu(bookmarkToFolder) { menu in
      let state = bookmarkMenuSource?() ?? NativeBookmarkMenu()
      menu.removeAllItems()
      for f in state.folders { menu.addItem(CommandItem(f.title, "addBookmarkToFolder", arg: f.id)) }
      menu.addItem(.separator())
      menu.addItem(CommandItem("New Folder…", "addBookmarkToFolder", arg: "new"))
    }
    deferBookmarkMenu(bookmarks) { menu in
      let state = bookmarkMenuSource?() ?? NativeBookmarkMenu()
      while menu.items.count > bookmarksFixedCount { menu.removeItem(at: bookmarksFixedCount) }
      menu.addItem(.separator())
      if !state.recent.isEmpty {
        let header = NSMenuItem(title: "Recent Bookmarks", action: nil, keyEquivalent: "")
        header.isEnabled = false
        menu.addItem(header)
        addBookmarks(state.recent, to: menu)
        menu.addItem(.separator())
      }
      menu.addItem(folderItem("Bookmarks Bar", state.bar, holdsArcHolders: true))
      menu.addItem(folderItem("Other Bookmarks", state.other))
    }
  }

  private static func buildExtensions(_ rows: [(id: String, title: String, icon: String?)]) {
    extensions.removeAllItems()
    for ext in rows {
      let item = CommandItem(ext.title, "openExtension", arg: ext.id)
      item.image = extensionIcon(ext.icon)
      extensions.addItem(item)
    }
    if !rows.isEmpty { extensions.addItem(.separator()) }
    extensions.addItem(CommandItem("Add Extension…", "addExtension"))
    extensions.addItem(CommandItem("Manage Extensions…", "manageExtensions"))
    extensions.addItem(CommandItem("Pin Extensions…", "pinExtensions"))
  }

  private static func buildHistory() {
    history.removeAllItems()
    history.addItem(CommandItem("Show History…", "showHistory", key: "y"))
    history.addItem(CommandItem("Clear Browsing Data…", "clearBrowsingData", key: "\u{8}", [.command, .shift]))
    history.addItem(.separator())
    let header = NSMenuItem(title: "Recently Closed", action: nil, keyEquivalent: "")
    header.isEnabled = false
    history.addItem(header)
    for entry in recentlyClosed { history.addItem(CommandItem(entry.title, "restoreClosed", arg: entry.id)) }
    if recentlyClosed.isEmpty { history.addItem(emptyItem()) }
    if !recentlyClosedGroups.isEmpty {
      history.addItem(.separator())
      let groupsHeader = NSMenuItem(title: "Recently Closed Groups", action: nil, keyEquivalent: "")
      groupsHeader.isEnabled = false
      history.addItem(groupsHeader)
      for entry in recentlyClosedGroups { history.addItem(CommandItem(entry.title, "restoreClosed", arg: entry.id)) }
    }
  }

  private static let modifierNames: [(String, NSEvent.ModifierFlags)] = [
    ("control", .control), ("option", .option), ("shift", .shift), ("command", .command), ("function", .function),
  ]
  private static let dynamicCommands: Set<String> = [
    "openBookmark", "restoreClosed", "moveTabToProfile", "moveTabToWindow", "addBookmarkToFolder",
    "addFolderToSidebar", "restoreArcFolders",
  ]

  private static var backTabMonitor: Any?

  static func watchBackTab() {
    guard backTabMonitor == nil else { return }
    backTabMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
      MainActor.assumeIsolated { performBackTab(event) } ? nil : event
    }
  }

  private static func performBackTab(_ event: NSEvent) -> Bool {
    guard event.charactersIgnoringModifiers == "\u{19}" else { return false }
    let window = event.window ?? NSApp.keyWindow
    let context = BackTabShortcut.Context(
      browserKeyWindow: WindowManager.shared.isBrowserWindow(window), attachedSheet: window?.attachedSheet != nil,
      modal: NSApp.modalWindow != nil, markedText: (window?.firstResponder as? NSTextInputClient)?.hasMarkedText() == true)
    var items: [CommandItem] = []
    walk(NSApp.mainMenu) { item, _ in
      if let item = item as? CommandItem, item.keyEquivalent == "\t" { items.append(item) }
    }
    var updated = Set<ObjectIdentifier>()
    for item in items {
      if let menu = item.menu, updated.insert(ObjectIdentifier(menu)).inserted { menu.update() }
    }
    let bindings = items.map { BackTabShortcut.Binding(key: $0.keyEquivalent, modifiers: backTabModifiers($0.keyEquivalentModifierMask), enabled: $0.isEnabled) }
    guard let index = BackTabShortcut.binding(for: backTabModifiers(event.modifierFlags), in: context, among: bindings),
      let menu = items[index].menu else { return false }
    menu.performActionForItem(at: menu.index(of: items[index]))
    return true
  }

  private static func backTabModifiers(_ flags: NSEvent.ModifierFlags) -> BackTabShortcut.Modifiers {
    var out: BackTabShortcut.Modifiers = []
    if flags.contains(.control) { out.insert(.control) }
    if flags.contains(.option) { out.insert(.option) }
    if flags.contains(.command) { out.insert(.command) }
    if flags.contains(.shift) { out.insert(.shift) }
    return out
  }

  private static func walk(_ menu: NSMenu?, path: [String] = [], _ visit: (NSMenuItem, [String]) -> Void) {
    for item in menu?.items ?? [] where !item.isSeparatorItem {
      if let submenu = item.submenu {
        if submenu !== NSApp.servicesMenu { walk(submenu, path: path + [item.title], visit) }
      } else {
        visit(item, path)
      }
    }
  }

  private static func modifiers(_ names: some Sequence<String>) -> NSEvent.ModifierFlags {
    let names = Set(names)
    return NSEvent.ModifierFlags(modifierNames.filter { names.contains($0.0) }.map(\.1))
  }

  private final class CommandItemRef {
    weak var item: CommandItem?
    init(_ item: CommandItem) { self.item = item }
  }

  private static var commandItemCache: (commands: Set<String>, refs: [CommandItemRef])?

  static func command(for event: NSEvent, among commands: Set<String>, solaraFirst: Bool = false) -> String? {
    guard let key = event.charactersIgnoringModifiers?.lowercased(), !key.isEmpty else { return nil }
    let combo = comboKey(key, event.modifierFlags)
    return commandItems(among: commands).first { item in
      !item.keyEquivalent.isEmpty && (!item.isHidden || item.allowsKeyEquivalentWhenHidden)
        && comboKey(item.keyEquivalent, item.keyEquivalentModifierMask) == combo
        && (!solaraFirst || (precedence(of: item) == .solara && MenuTarget.shared.validateMenuItem(item)))
    }?.command
  }

  private static func commandItems(among commands: Set<String>) -> [CommandItem] {
    if let cache = commandItemCache, cache.commands == commands {
      let items = cache.refs.compactMap(\.item)
      if !items.isEmpty, items.count == cache.refs.count, items.allSatisfy(inMainMenu) { return items }
    }
    var items: [CommandItem] = []
    walk(NSApp.mainMenu) { item, _ in
      if let item = item as? CommandItem, commands.contains(item.command) { items.append(item) }
    }
    commandItemCache = (commands, items.map(CommandItemRef.init))
    return items
  }

  private static func inMainMenu(_ item: NSMenuItem) -> Bool {
    var menu = item.menu
    while let parent = menu?.supermenu { menu = parent }
    return menu != nil && menu === NSApp.mainMenu
  }

  static func comboKey(_ key: String, _ mods: NSEvent.ModifierFlags) -> String {
    let relevant = mods.intersection([.control, .option, .shift, .command, .function])
    let shift: NSEvent.ModifierFlags = key != key.lowercased() ? .shift : []
    return "\(key.lowercased())|\(relevant.union(shift).rawValue)"
  }

  private struct ShortcutGroup {
    var primary: Rebindable
    var path: [String]
    var items: [Rebindable]
  }

  private static func shortcutGroups() -> [(id: String, group: ShortcutGroup)] {
    var order: [String] = []
    var groups: [String: ShortcutGroup] = [:]
    walk(NSApp.mainMenu) { item, path in
      guard let item = item as? Rebindable, (item as? CommandItem)?.commandAlternateOf == nil else { return }
      let id = item.shortcutId
      if var group = groups[id] {
        group.items.append(item)
        if group.primary.isHidden && !item.isHidden { group.primary = item; group.path = path }
        groups[id] = group
      } else {
        order.append(id)
        groups[id] = ShortcutGroup(primary: item, path: path, items: [item])
      }
    }
    return order.map { ($0, groups[$0]!) }
  }

  private static func setShortcut(_ item: NSMenuItem, _ key: String, _ mods: NSEvent.ModifierFlags) {
    let shortcut = keyEquivalent(key, key.isEmpty ? [] : mods)
    if item.keyEquivalent != shortcut.key { item.keyEquivalent = shortcut.key }
    if item.keyEquivalentModifierMask != shortcut.mods { item.keyEquivalentModifierMask = shortcut.mods }
  }

  private static var announcedShortcuts: [String]?

  private static func announceShortcuts() {
    guard MenuState.current.fromApp else { return }
    var bound: [String] = []
    walk(NSApp.mainMenu) { item, _ in
      if item is Rebindable {
        let precedence = precedence(of: item)?.rawValue ?? ""
        bound.append("\(item.identifier?.rawValue ?? "")=\(item.keyEquivalent)|\(item.keyEquivalentModifierMask.rawValue)|\(precedence)")
      }
    }
    if bound != announcedShortcuts {
      announcedShortcuts = bound
      NotificationCenter.default.post(name: .init("SolaraMenuShortcutsChanged"), object: nil)
    }
  }

  private static func applyShortcuts(_ overrides: [String: [String]]) {
    defer { announceShortcuts() }
    let groups = shortcutGroups()
    let liveIds = Set(groups.map(\.id))
    let taken = Set(overrides.compactMap { id, o -> String? in
      guard liveIds.contains(id), let key = o.first, !key.isEmpty else { return nil }
      return comboKey(key, modifiers(o.dropFirst()))
    })
    for (id, group) in groups {
      let carriesOverride: (Rebindable) -> Bool = { $0 === group.primary || !$0.isHidden }
      for item in group.items {
        if let o = overrides[id] {
          if carriesOverride(item) { setShortcut(item, o.first ?? "", modifiers(o.dropFirst())) } else { setShortcut(item, "", []) }
        } else if !item.defaultKey.isEmpty, taken.contains(comboKey(item.defaultKey, item.defaultModifiers)) {
          setShortcut(item, "", [])
        } else {
          setShortcut(item, item.defaultKey, item.defaultModifiers)
        }
      }
    }
    var bound = Set<String>()
    walk(NSApp.mainMenu) { item, _ in
      guard !item.keyEquivalent.isEmpty, (item as? CommandItem)?.commandAlternateOf == nil else { return }
      bound.insert(comboKey(item.keyEquivalent, item.keyEquivalentModifierMask))
    }
    for case let item as CommandItem in profiles.items { item.followPrimaryShortcut(bound: bound) }
  }

  static func precedence(of item: NSMenuItem) -> ShortcutPrecedence? {
    guard let item = item as? Rebindable else { return nil }
    return ShortcutPrecedence.resolve(shortcutId: item.shortcutId, command: (item as? CommandItem)?.command, chosen: MenuState.current.shortcutPrecedence)
  }

  private static func standardPrecedence(of item: Rebindable) -> ShortcutPrecedence {
    ShortcutPrecedence.standard(shortcutId: item.shortcutId, command: (item as? CommandItem)?.command)
  }

  static func isTabNumberShortcut(_ event: NSEvent) -> Bool {
    guard let key = event.charactersIgnoringModifiers?.lowercased(), !key.isEmpty else { return false }
    let mods = event.modifierFlags.intersection(.deviceIndependentFlagsMask).subtracting(.capsLock)
    return shortcutGroups().contains { id, group in
      guard id.hasPrefix("selectTab:") || id == "selectLastTab" else { return false }
      let current = shortcut(of: group.primary)
      return current.key == key && current.mods.intersection(.deviceIndependentFlagsMask) == mods
    }
  }

  static func tabNumberHintBindings() -> [String: String] {
    var bindings: [String: String] = [:]
    for (id, group) in shortcutGroups() where id.hasPrefix("selectTab:") || id == "selectLastTab" {
      let item = group.primary
      let current = shortcut(of: item)
      let names = modifierNames.filter { current.mods.contains($0.1) }.map(\.0)
      bindings[id] = TabNumberShortcut.formatted(key: current.key, modifiers: names)
    }
    return bindings
  }

  static func shortcutList() -> [[String: Any]] {
    var list: [[String: Any]] = []
    func names(_ mods: NSEvent.ModifierFlags) -> [String] {
      modifierNames.filter { mods.contains($0.1) }.map(\.0)
    }
    for (id, group) in shortcutGroups() {
      let item = group.primary
      if let command = item as? CommandItem, dynamicCommands.contains(command.command) { continue }
      guard !item.defaultTitle.isEmpty else { continue }
      let current = shortcut(of: item)
      let defaultCombo = comboKey(item.defaultKey, item.defaultModifiers)
      var aliases: [[String]] = []
      var seen: Set<String> = [defaultCombo]
      for other in group.items where other !== item && !other.defaultKey.isEmpty {
        if seen.insert(comboKey(other.defaultKey, other.defaultModifiers)).inserted {
          aliases.append([other.defaultKey] + names(other.defaultModifiers))
        }
      }
      list.append([
        "id": id, "title": item.defaultTitle, "path": group.path, "key": current.key,
        "modifiers": current.key.isEmpty ? [] : names(current.mods), "defaultKey": item.defaultKey,
        "defaultModifiers": item.defaultKey.isEmpty ? [] : names(item.defaultModifiers), "remappable": true,
        "aliases": aliases, "precedence": (precedence(of: item) ?? .website).rawValue, "defaultPrecedence": standardPrecedence(of: item).rawValue,
        "precedenceFixed": ShortcutPrecedence.isFixed(shortcutId: item.shortcutId, command: (item as? CommandItem)?.command),
      ])
    }
    var seen = Set<String>()
    walk(NSApp.mainMenu) { item, path in
      guard !(item is Rebindable), !item.isHidden, !item.title.isEmpty, !item.keyEquivalent.isEmpty, item.action != nil else { return }
      let id = "system:" + (path + [item.title]).joined(separator: " > ")
      guard seen.insert(id).inserted else { return }
      let current = shortcut(of: item)
      let mods = names(current.mods)
      list.append([
        "id": id, "title": item.title, "path": path, "key": current.key, "modifiers": mods,
        "defaultKey": current.key, "defaultModifiers": mods, "remappable": false, "aliases": [[String]](),
      ])
    }
    return list
  }

  private static func emptyItem() -> NSMenuItem {
    let item = NSMenuItem(title: "Empty", action: nil, keyEquivalent: "")
    item.isEnabled = false
    return item
  }

  private static func deferBookmarkMenu(_ menu: NSMenu, populate: @escaping (NSMenu) -> Void) {
    let delegate = BookmarkMenuUpdate(populate)
    menu.delegate = delegate
    objc_setAssociatedObject(menu, &BookmarkMenuUpdate.key, delegate, .OBJC_ASSOCIATION_RETAIN)
  }

  private static func folderItem(_ title: String, _ children: [NativeBookmarkMenu.Row], id: String? = nil, holdsArcHolders: Bool = false, arcHolder: Bool = false) -> NSMenuItem {
    let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
    let menu = NSMenu(title: title)
    deferBookmarkMenu(menu) { menu in
      addBookmarks(children, to: menu, holdsArcHolders: holdsArcHolders)
      if children.isEmpty { menu.addItem(emptyItem()) }
      if let id, hasGroupLinks(children) {
        menu.addItem(.separator())
        menu.addItem(CommandItem("Add to Sidebar as Group", "addFolderToSidebar", arg: id))
        if arcHolder && children.contains(where: { $0.children.map(hasGroupLinks) ?? false }) {
          menu.addItem(CommandItem("Restore Arc Folders as Groups", "restoreArcFolders", arg: id))
        }
      }
    }
    item.submenu = menu
    item.image = NSImage(systemSymbolName: "folder", accessibilityDescription: nil)
    return item
  }

  private static func hasGroupLinks(_ nodes: [NativeBookmarkMenu.Row]) -> Bool {
    nodes.contains { node in
      if let children = node.children { return hasGroupLinks(children) }
      let url = (node.url ?? "").lowercased()
      return url.hasPrefix("http:") || url.hasPrefix("https:") || url.hasPrefix("file:")
    }
  }

  private static func addBookmarks(_ nodes: [NativeBookmarkMenu.Row], to menu: NSMenu, holdsArcHolders: Bool = false) {
    for node in nodes {
      if let children = node.children {
        menu.addItem(folderItem(node.title, children, id: node.id, arcHolder: holdsArcHolders && node.title.hasSuffix(" (Arc)")))
      } else {
        menu.addItem(CommandItem(node.title.isEmpty ? (node.url ?? "") : node.title, "openBookmark", arg: node.id))
      }
    }
  }

  static func dockMenu() -> NSMenu {
    let menu = NSMenu()
    if profileEntries.count > 1 {
      for p in profileEntries {
        let item = CommandItem("New \(p.title) Window", "newWindow", arg: p.id)
        item.windowless = true
        menu.addItem(item)
      }
    } else {
      let item = CommandItem("New Window", "newWindow")
      item.windowless = true
      menu.addItem(item)
    }
    let incognito = CommandItem("New Incognito Window", "newIncognitoWindow")
    incognito.windowless = true
    menu.addItem(incognito)
    let small = CommandItem("New Little \(Bundle.main.productName) Window", "newLittleSolara")
    small.windowless = true
    menu.addItem(small)
    if profileEntries.count > 1 {
      let inProfile = NSMenu(title: "New Little \(Bundle.main.productName) Window in Profile")
      for p in profileEntries {
        let item = CommandItem(p.title, "newLittleSolara", arg: p.id)
        item.windowless = true
        inProfile.addItem(item)
      }
      let root = NSMenuItem(title: inProfile.title, action: nil, keyEquivalent: "")
      root.submenu = inProfile
      menu.addItem(root)
    }
    return menu
  }
}

private final class BookmarkMenuUpdate: NSObject, NSMenuDelegate {
  static var key = 0
  private var populate: ((NSMenu) -> Void)?

  init(_ populate: @escaping (NSMenu) -> Void) { self.populate = populate }

  func menuNeedsUpdate(_ menu: NSMenu) {
    guard let populate else { return }
    self.populate = nil
    populate(menu)
  }
}
