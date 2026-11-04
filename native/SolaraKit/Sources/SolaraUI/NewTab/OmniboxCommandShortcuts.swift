import Foundation
import SolaraModel

public struct CommandMenuShortcut: Codable, Sendable {
  public let id: String
  public let defaultKey: String
  public let defaultModifiers: [String]
  public let remappable: Bool
  public let aliases: [[String]]?

  public init(id: String, defaultKey: String = "", defaultModifiers: [String] = [], remappable: Bool = true, aliases: [[String]]? = nil) {
    self.id = id
    self.defaultKey = defaultKey
    self.defaultModifiers = defaultModifiers
    self.remappable = remappable
    self.aliases = aliases
  }
}

public struct CommandShortcutSnapshot: Sendable {
  public let menu: [CommandMenuShortcut]?
  public let revision: Int

  public init(menu: [CommandMenuShortcut]? = nil, revision: Int = 0) {
    self.menu = menu
    self.revision = revision
  }

  public func hint(_ id: String, state: BrowserState) -> String? {
    hints(state: state)[JSKey(id)]
  }

  public func hints(state: BrowserState) -> [JSKey: String] {
    let overrides = state.settings["shortcuts"]?.object ?? [:]
    var sources = Self.catalog.map { CommandShortcutSource(id: $0.0, keys: $0.1.map(CommandKey.parse)) }
    for (i, id) in state.profileOrder.enumerated() {
      sources.append(CommandShortcutSource(id: "switchProfile:\(id)", keys: i < 9 ? [CommandKey.parse("⌃\(i + 1)")] : []))
      sources.append(CommandShortcutSource(id: "newLittleSolara:\(id)", keys: []))
    }
    for id in overrides.keys where id.jsStartsWith("openExtension:") {
      sources.append(CommandShortcutSource(id: id, keys: []))
    }
    if let menu {
      let listed = Set(menu.map { JSKey($0.id) })
      sources = sources.filter { listed.contains(JSKey($0.id)) }
      sources += menu.filter { !$0.remappable }.map {
        CommandShortcutSource(id: $0.id, keys: [CommandKey(key: $0.defaultKey, modifiers: $0.defaultModifiers)] + ($0.aliases ?? []).map(CommandKey.stored), fixed: true)
      }
    }
    let rebindable = Set(sources.filter { !$0.fixed }.map { JSKey($0.id) })
    var taken = Set<JSKey>()
    for (id, value) in overrides where rebindable.contains(JSKey(id)) {
      let stored = value.array?.compactMap(\.string) ?? []
      if !(stored.first ?? "").isEmpty { taken.insert(CommandKey.stored(stored).combo) }
    }
    var bindings: [JSKey: String] = [:]
    for source in sources {
      let stored = source.fixed ? nil : overrides[source.id]?.array?.compactMap(\.string)
      let candidates = stored.map { [CommandKey.stored($0)] } ?? source.keys.filter { source.fixed || !taken.contains($0.combo) }
      var seen = Set<JSKey>()
      let keys = candidates.filter { !$0.key.isEmpty && seen.insert($0.combo).inserted }
      bindings[JSKey(source.id)] = keys.first?.formatted
    }
    return bindings
  }

  private static let catalog: [(String, [String])] = [
    ("newTab", ["⌘T"]),
    ("newWindow", ["⌘N"]),
    ("newIncognitoWindow", ["⇧⌘N"]),
    ("newLittleSolara", ["⌥⌘N"]),
    ("toggleOpenLinksInLittleSolara", []),
    ("reopenClosedTab", ["⇧⌘T"]),
    ("reopenClosedWindow", []),
    ("restoreClosed", []),
    ("focusCommandBar", ["⌘L", "⌃F5"]),
    ("closeTab", ["⌘W"]),
    ("closeAllTabs", ["⇧⌘K"]),
    ("print", ["⌘P"]),
    ("copyUrl", ["⇧⌘C"]),
    ("copyUrlAsMarkdown", ["⌥⇧⌘C"]),
    ("findInPage", ["⌘F"]),
    ("findNext", ["⌘G"]),
    ("findPrevious", ["⇧⌘G"]),
    ("setAppearance", []),
    ("setAppearance:auto", []),
    ("setAppearance:light", []),
    ("setAppearance:dark", []),
    ("reload", ["⌘R"]),
    ("forceReload", ["⇧⌘R"]),
    ("toggleTabLayout", ["⇧⌘S"]),
    ("toggleSidebar", ["⌘S", "⇧⌘L", "⇧⌘F"]),
    ("openSplitPane", ["⌃⇧=", "⌃+"]),
    ("useSelectionForFind", ["⌘E"]),
    ("findAndReplace", ["⌥⌘F"]),
    ("jumpToSelection", ["⌘J"]),
    ("focusNextPane", ["⌃⇧]", "⌃}"]),
    ("focusPreviousPane", ["⌃⇧[", "⌃{"]),
    ("toggleFullUrl", []),
    ("toggleJavaScriptFromAppleEvents", []),
    ("toggleAddressBar", []),
    ("toggleSidebarIconsOnly", []),
    ("cast", []),
    ("zoomReset", ["⌘0"]),
    ("zoomIn", ["⌘+", "⌘="]),
    ("zoomOut", ["⌘-"]),
    ("devTools", ["⌥⌘I"]),
    ("toggleDeveloperMode", []),
    ("toggleDevTools", ["F12"]),
    ("javaScriptConsole", ["⌥⌘J"]),
    ("inspectElements", ["⌥⌘C"]),
    ("viewSource", ["⌥⌘U"]),
    ("back", ["⌘[", "⌘←"]),
    ("forward", ["⌘]", "⌘→"]),
    ("nextTab", ["⇧⌘]", "⌘}", "⌃⇟", "⌥⌘↓"]),
    ("previousTab", ["⇧⌘[", "⌘{", "⌃⇞", "⌥⌘↑"]),
    ("selectTab", []),
    ("selectTab:1", ["⌘1"]),
    ("selectTab:2", ["⌘2"]),
    ("selectTab:3", ["⌘3"]),
    ("selectTab:4", ["⌘4"]),
    ("selectTab:5", ["⌘5"]),
    ("selectTab:6", ["⌘6"]),
    ("selectTab:7", ["⌘7"]),
    ("selectTab:8", ["⌘8"]),
    ("selectLastTab", ["⌘9"]),
    ("togglePin", []),
    ("togglePin:tile", []),
    ("togglePinnedRow", ["⌘D"]),
    ("duplicateTab", []),
    ("moveTabToProfile", []),
    ("moveTabToWindow", []),
    ("bookmarkPage", ["⌥⇧⌘D"]),
    ("addBookmarkToFolder", []),
    ("openBookmark", []),
    ("addFolderToSidebar", []),
    ("restoreArcFolders", []),
    ("toggleMute", []),
    ("togglePageEngine", []),
    ("downloads", ["⇧⌘J", "⌥⌘L"]),
    ("mergeAllWindows", []),
    ("switchProfile", []),
    ("nextProfile", ["⌥⌘→"]),
    ("previousProfile", ["⌥⌘←"]),
    ("newProfile", []),
    ("openSettings", ["⌘,"]),
    ("importBrowserData", []),
    ("showHistory", ["⌘Y"]),
    ("clearBrowsingData", ["⇧⌘⌫"]),
    ("manageBookmarks", ["⌥⌘B"]),
    ("bookmarkAllTabs", ["⇧⌘D"]),
    ("setBookmarksBar", []),
    ("setBookmarksBar:always", []),
    ("setBookmarksBar:newTab", []),
    ("setBookmarksBar:never", []),
    ("toggleBookmarksBar", ["⇧⌘B"]),
    ("newTabInGroup", ["⌥⌘T", "⌃⌘C"]),
    ("newGroupWithTabs", ["⌃⌘N", "⌃⌘P"]),
    ("cleanUpTabs", ["⌥⌘K"]),
    ("tidyPins", []),
    ("searchTabs", ["⇧⌘A"]),
    ("renameTab", []),
    ("changeTabIcon", []),
    ("returnToPinnedUrl", ["⌘↩"]),
    ("tabSwitcher", []),
    ("tabSwitcher:forward", ["⌃⇥"]),
    ("tabSwitcher:backward", ["⌃⇧⇥"]),
    ("share", ["⌥⌘S"]),
    ("sendFeedback", ["⌥⇧⌘I"]),
    ("keyboardShortcuts", []),
    ("copyDiagnostics", []),
    ("recordPerformanceIssue", []),
    ("toolTour", []),
    ("videoTour", []),
    ("releaseNotes", []),
    ("showOnboarding", []),
    ("taskManager", []),
    ("openExtension", []),
    ("addExtension", []),
    ("manageExtensions", []),
    ("pinExtensions", []),
    ("autofill", []),
    ("autofill:contact", []),
    ("autofill:passwords", []),
    ("autofill:creditCard", []),
    ("openFile", ["⌘O"]),
    ("savePage", []),
    ("emailPageLocation", ["⇧⌘I"]),
    ("printWithSystemDialog", ["⌥⌘P"]),
    ("stop", ["⌘."]),
    ("caretBrowsing", ["F7"]),
    ("moveTabDown", ["⌃⇧⇟"]),
    ("moveTabUp", ["⌃⇧⇞"]),
    ("closeTabGroup", ["⌃⌘W"]),
    ("openProfileMenu", ["⇧⌘M"]),
    ("std:quit:", ["⌘Q"]),
    ("std:hide:", ["⌘H"]),
    ("std:hideOtherApplications:", ["⌥⌘H"]),
    ("std:unhideAllApplications:", []),
    ("std:closeWindow:", ["⇧⌘W"]),
    ("std:undo:", ["⌘Z"]),
    ("std:redo:", ["⇧⌘Z"]),
    ("std:cut:", ["⌘X"]),
    ("std:copy:", ["⌘C"]),
    ("std:paste:", ["⌘V"]),
    ("std:pasteAndMatchStyle:", ["⇧⌘V"]),
    ("std:delete:", []),
    ("std:selectAll:", ["⌘A"]),
    ("std:showGuessPanel:", ["⌘:"]),
    ("std:checkSpelling:", ["⌘;"]),
    ("std:toggleContinuousSpellChecking:", []),
    ("std:toggleGrammarChecking:", []),
    ("std:toggleAutomaticSpellingCorrection:", []),
    ("std:orderFrontSubstitutionsPanel:", []),
    ("std:toggleSmartInsertDelete:", []),
    ("std:toggleAutomaticQuoteSubstitution:", []),
    ("std:toggleAutomaticDashSubstitution:", []),
    ("std:toggleAutomaticLinkDetection:", []),
    ("std:toggleAutomaticDataDetection:", []),
    ("std:toggleAutomaticTextReplacement:", []),
    ("std:uppercaseWord:", []),
    ("std:lowercaseWord:", []),
    ("std:capitalizeWord:", []),
    ("std:startSpeaking:", []),
    ("std:stopSpeaking:", []),
    ("std:toggleFullScreen:", ["🌐F", "⌃⌘F"]),
    ("std:performMiniaturize:", ["⌘M"]),
    ("std:miniaturizeAll:", ["⌥⌘M"]),
    ("std:performZoom:", []),
    ("std:arrangeWindowsInFront:", []),
    ("std:toggleKeepOnTop:", []),
  ]
}

private struct CommandShortcutSource {
  let id: String
  let keys: [CommandKey]
  var fixed = false
}

private struct CommandKey {
  let key: String
  let modifiers: [String]

  static let modifierOrder = ["control", "option", "shift", "command", "function"]
  static let modifierGlyphs = ["⌃", "⌥", "⇧", "⌘", "🌐"]
  static let keyGlyphs: [(String, String)] = [
    ("\t", "⇥"), ("\r", "↩"), ("\u{3}", "⌤"), ("\u{8}", "⌫"), ("\u{7f}", "⌫"), ("\u{F728}", "⌦"),
    ("\u{1b}", "⎋"), (" ", "Space"), ("\u{F700}", "↑"), ("\u{F701}", "↓"), ("\u{F702}", "←"), ("\u{F703}", "→"),
    ("\u{F729}", "↖"), ("\u{F72B}", "↘"), ("\u{F72C}", "⇞"), ("\u{F72D}", "⇟"),
  ]

  static func ordered(_ modifiers: [String]) -> [String] {
    modifierOrder.filter { modifiers.contains($0) }
  }

  static func stored(_ stored: [String]) -> CommandKey {
    let first = stored.first ?? ""
    let modifiers = stored.dropFirst().filter { modifierOrder.contains($0) }
    let shifted = first.unicodeScalars.count == 1 && !first.jsEquals(first.lowercased())
    return CommandKey(key: shifted ? first.lowercased() : first, modifiers: ordered(Array(modifiers) + (shifted ? ["shift"] : [])))
  }

  static func parse(_ text: String) -> CommandKey {
    let glyphs = text.unicodeScalars.map(String.init)
    var modifiers: [String] = []
    var i = 0
    while i < glyphs.count - 1, let modifier = modifierGlyphs.firstIndex(of: glyphs[i]) {
      modifiers.append(modifierOrder[modifier])
      i += 1
    }
    let name = glyphs.dropFirst(i).joined()
    let key: String
    if let glyph = keyGlyphs.first(where: { $0.1.jsEquals(name) }) {
      key = glyph.0
    } else if name.range(of: "^F[0-9]{1,2}$", options: .regularExpression) != nil, let number = Int(name.dropFirst()) {
      key = String(utf16Units: [UInt16(0xF704 + number - 1)])
    } else {
      key = name.lowercased()
    }
    return CommandKey(key: key, modifiers: ordered(modifiers))
  }

  var combo: JSKey {
    let shifted = key.jsEquals(key.lowercased()) ? [] : ["shift"]
    return JSKey(Self.ordered(modifiers + shifted).joined(separator: "+") + "|" + key.lowercased())
  }

  var formatted: String {
    guard let first = key.utf16.first else { return "" }
    let name: String
    if let glyph = Self.keyGlyphs.first(where: { $0.0.jsEquals(key) }) {
      name = glyph.1
    } else if (0xF704...0xF717).contains(first) {
      name = "F\(first - 0xF704 + 1)"
    } else {
      name = key.uppercased()
    }
    return Self.ordered(modifiers).map { Self.modifierGlyphs[Self.modifierOrder.firstIndex(of: $0)!] }.joined() + name
  }
}
