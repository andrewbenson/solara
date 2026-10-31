import SolaraModel

public struct CommandError: Error, CustomStringConvertible {
  public let description: String
  public init(_ description: String) { self.description = description }
}

public struct Command: Sendable, Equatable {
  public var name: String
  public var args: [JSONValue]

  public init(_ name: String, _ args: [JSONValue] = []) {
    self.name = name
    self.args = args
  }

  public init(json: JSONValue) throws {
    guard let name = json["name"]?.string else { throw CommandError("command has no name") }
    guard Command.known.contains(name) else { throw CommandError("unknown command \(name)") }
    self.name = name
    args = json["args"]?.array ?? []
  }

  public var json: JSONValue { ["name": .string(name), "args": .array(args)] }

  public static let durable: Set<String> = [
    "updateSettings", "closeWindow", "restoreClosingWindow", "deleteProfile", "createProfile", "updateProfile", "reorderProfiles", "setDefaultProfile",
  ]

  public var isDurable: Bool { Command.durable.contains(name) }

  public static let known: Set<String> = [
    "importWorkspace", "setWindowLayout", "newTab", "closeTab", "closeTabs", "activate", "handOffPin", "activateIndex", "cycle", "navigate", "updateTab", "navigated", "faviconChanged",
    "duplicateTab", "togglePin", "moveTab", "moveTabBy", "createWindow", "closeWindow", "restoreClosingWindow", "forgetClosedWindow", "setWindowFrame", "setWindowFullScreen", "toggleSidebar",
    "switchProfile", "moveTabsToWindow", "moveTabToProfile", "mergeAllWindows", "reopenClosed", "reopenClosedTab", "reopenClosedWindow",
    "restoreClosed", "createProfile", "updateProfile", "deleteProfile", "reorderProfiles", "setDefaultProfile", "profileDataDeleted",
    "createGroup", "updateGroup", "addTabsToGroup", "removeTabsFromGroup", "ungroup", "newNestedGroup", "closeGroup", "deleteGroup",
    "placeTabs", "dropTabs", "pinTabs", "returnToPinnedUrl", "setPinnedUrl", "setMuted", "setSiteMuted", "groupTabs", "groupOnto", "moveGroup",
    "duplicateGroup", "newTabInGroup", "cleanUpTabs", "restoreCleaned", "clearUnpinnedTabs", "undoClearTabs", "removeClosedPin",
    "closeAbandonedNewTabs", "createSplit", "openSplitPane", "replaceSplitPane", "removeTabFromSplit", "separateSplit", "updateSplit",
    "flipSplit", "toggleSplitOrientation", "movePane", "focusPane", "toggleTabLayout", "openPeek", "closePeek", "peekToTab", "updateSettings",
    "setFocusedWindow", "upsertDownload", "removeDownload", "clearDownloads", "forgetDownloads", "hydrate", "tidyPins", "untidyPins",
    "renameTileFolder", "newTileFolder", "leaveTileFolder", "dissolveTileFolder", "openDraftGroups", "forgetClosedTab", "setWindowClosing",
    "setLastTabKeepsWindow", "noteRemotePinDeletion", "setHistoryHints", "setPlayingAudio", "setLaunchBackdrop", "setEarlyLaunchTab", "nextId", "nextNavigation",
    "syncPinsApply", "settlePinChoices", "beginFromSync", "endFromSync", "beginTransaction", "endTransaction", "closeTransactions", "stripSnapshot", "stripTransaction", "projectStrips", "stripCommandSent", "applyState",
    "setAppDark", "setFind", "setSelection", "setSelectionAnchor", "clickTab", "openPanel", "closePanel", "setDownloadsOpen",
  ]
}

public enum Effect: Sendable, Hashable {
  case swapTabs(a: String, b: String)
  case startNavigation(tabId: String, navigation: Navigation)
  case profileCreated(profileId: String, sharedWith: String?)
  case profileDeleted(profileId: String, shared: Bool)
  case cancelDownload(id: String)
  case endPrivateSession(session: String)
  case pinHandoff(tabId: String)
  case stripCommand(strip: Int, id: Int, command: JSONValue)

  public var json: JSONValue {
    switch self {
    case .swapTabs(let a, let b): ["type": "swapTabs", "a": .string(a), "b": .string(b)]
    case .startNavigation(let tabId, let navigation): ["type": "startNavigation", "tabId": .string(tabId), "navigation": navigation.jsonValue]
    case .profileCreated(let profileId, let sharedWith): ["type": "profileCreated", "profileId": .string(profileId), "sharedWith": JSONValue(sharedWith)]
    case .profileDeleted(let profileId, let shared): ["type": "profileDeleted", "profileId": .string(profileId), "shared": .bool(shared)]
    case .cancelDownload(let id): ["type": "cancelDownload", "id": .string(id)]
    case .endPrivateSession(let session): ["type": "endPrivateSession", "session": .string(session)]
    case .pinHandoff(let tabId): ["type": "pinHandoff", "tabId": .string(tabId)]
    case .stripCommand(let strip, let id, let command): ["type": "stripCommand", "strip": JSONValue(strip), "id": JSONValue(id), "command": command]
    }
  }
}

struct Args {
  let name: String
  let values: [JSONValue]

  subscript(_ i: Int) -> JSONValue? {
    guard i < values.count else { return nil }
    let v = values[i]
    return v.isNull ? nil : v
  }

  func raw(_ i: Int) -> JSONValue? { i < values.count ? values[i] : nil }
  func string(_ i: Int) -> String? { self[i]?.string }
  func requireString(_ i: Int) throws -> String {
    guard let s = string(i) else { throw CommandError("\(name): argument \(i) is not a string") }
    return s
  }
  func strings(_ i: Int) -> [String] { self[i]?.array?.compactMap(\.string) ?? [] }
  func bool(_ i: Int) -> Bool { self[i]?.truthy ?? false }
  func optionalBool(_ i: Int) -> Bool? { self[i].map(\.truthy) }
  func int(_ i: Int) -> Int { Int(self[i]?.number ?? 0) }
  func number(_ i: Int) -> Double? { self[i]?.number }
  func object(_ i: Int) -> JSONObject { self[i]?.object ?? [:] }
  func update(_ i: Int) -> TabUpdate {
    var set = object(i)
    let unset = set["$unset"]?.array?.compactMap(\.string) ?? []
    set.removeValue(forKey: "$unset")
    return TabUpdate(set: set, unset: unset)
  }
}

func optionalString(_ o: JSONObject, _ key: String) -> String? {
  guard let v = o[key], !v.isNull else { return nil }
  return v.string
}

func newTabOptions(_ o: JSONObject?) -> NewTabOptions? {
  guard let o else { return nil }
  var out = NewTabOptions()
  out.url = optionalString(o, "url")
  out.background = o["background"].flatMap { $0.isNull ? nil : $0.truthy }
  out.adoptId = optionalString(o, "adoptId")
  out.openerId = optionalString(o, "openerId")
  out.profileId = optionalString(o, "profileId")
  out.pinned = o["pinned"].flatMap { $0.isNull ? nil : $0.truthy }
  if let snap = o["snapshot"]?.object { out.snapshot = tabPatch(snap) }
  out.index = o["index"]?.number.map { Int($0) }
  out.wakeAdoptId = optionalString(o, "wakeAdoptId")
  out.newTabCommand = o["newTabCommand"].flatMap { $0.isNull ? nil : $0.truthy }
  return out
}

func tabPatch(_ o: JSONObject) -> TabPatch {
  var p = TabPatch()
  if let v = o["url"]?.string { p.url = v }
  if let v = o["title"]?.string { p.title = v }
  if let v = o["favicon"] { p.favicon = .some(v.string) }
  if let v = o["pinned"]?.bool { p.pinned = v }
  if let v = o["muted"]?.bool { p.muted = v }
  if let v = o["zoom"]?.number { p.zoom = v }
  if let v = o["customTitle"] { p.customTitle = .some(v.string) }
  if let v = o["customIcon"] { p.customIcon = .some(v.string) }
  if let v = o["profileId"]?.string { p.profileId = v }
  if let v = o["pinnedUrl"] { p.pinnedUrl = .some(v.string) }
  if let v = o["pinnedAsRow"] { p.pinnedAsRow = .some(v.bool) }
  if let v = o["tileFolder"] { p.tileFolder = .some(try? TileFolder(value: v)) }
  if let v = o["engine"] { p.engine = .some(v.string) }
  let known: Set<String> = [
    "url", "title", "favicon", "pinned", "muted", "zoom", "customTitle", "customIcon", "profileId", "pinnedUrl", "pinnedAsRow", "tileFolder", "engine",
  ]
  for (key, value) in o where !known.contains(key) && key != "$unset" { p.extra[key] = value }
  return p
}

extension Session {
  public func apply(_ command: Command) throws {
    let a = Args(name: command.name, values: command.args)
    switch command.name {
    case "importWorkspace": result = try importWorkspace(a[0] ?? .null)
    case "setWindowLayout":
      let id = try a.requireString(0)
      let layout = try a.requireString(1)
      guard layout == "sidebar" || layout == "top", var window = state.windows[id] else { throw CommandError("setWindowLayout: invalid window or layout") }
      window.tabLayout = layout
      update { $0.windows[id] = window }
    case "newTab":
      result = .string(newTab(try a.requireString(0), newTabOptions(a[1]?.object)))
    case "closeTab": closeTab(try a.requireString(0))
    case "closeTabs":
      closeTabs(a.strings(0), lastClosesWindow: a[1]?["lastClosesWindow"]?.truthy ?? false,
                windowClosedByChrome: a[1]?["windowClosedByChrome"]?.truthy ?? false)
    case "activate": activate(try a.requireString(0))
    case "handOffPin": handOffPin(try a.requireString(0))
    case "activateIndex": activateIndex(try a.requireString(0), a.int(1))
    case "cycle": cycle(try a.requireString(0), a.int(1))
    case "navigate": navigate(try a.requireString(0), try a.requireString(1), userInitiated: a[2]?["userInitiated"].map(\.truthy) ?? true)
    case "updateTab": updateTab(try a.requireString(0), a.update(1))
    case "navigated": updateTab(try a.requireString(0), a.update(1))
    case "faviconChanged": updateTab(try a.requireString(0), TabUpdate(set: ["favicon": a.raw(1) ?? .null]))
    case "duplicateTab": result = JSONValue(duplicateTab(try a.requireString(0)))
    case "togglePin": togglePin(try a.requireString(0))
    case "moveTab": moveTab(try a.requireString(0), a.int(1))
    case "moveTabBy": moveTabBy(try a.requireString(0), a.int(1))
    case "createWindow":
      let o = a.object(0)
      var options = CreateWindowOptions()
      options.profileId = optionalString(o, "profileId")
      options.incognito = o["incognito"]?.truthy
      options.url = optionalString(o, "url")
      options.adoptId = optionalString(o, "adoptId")
      options.tabIds = o["tabIds"]?.array?.compactMap(\.string)
      options.frame = o["frame"]?.array?.compactMap(\.number)
      options.small = o["small"]?.truthy
      options.linkPointer = o["linkPointer"]?.array?.compactMap(\.number)
      options.background = o["background"]?.truthy
      options.chromeWindow = optionalString(o, "chromeWindow")
      result = .string(createWindow(options))
    case "closeWindow": closeWindow(try a.requireString(0))
    case "restoreClosingWindow":
      let snapshot = a.object(0)
      let window = try BrowserWindow(value: snapshot["window"] ?? .null)
      let tabs = try (snapshot["tabs"]?.array ?? []).map { try Tab(value: $0) }
      let groups = try (snapshot["groups"]?.array ?? []).map { try TabGroup(value: $0) }
      let splits = try (snapshot["splits"]?.array ?? []).map { try SplitView(value: $0) }
      result = JSONValue(restoreClosingWindow(window, tabs, groups, splits, chromeWindow: try a.requireString(1), liveTabIds: a.strings(2)))
    case "forgetClosedWindow": forgetClosedWindow(try a.requireString(0))
    case "setWindowFrame": setWindowFrame(try a.requireString(0), a[1]?.array?.compactMap(\.number) ?? [])
    case "setWindowFullScreen": setWindowFullScreen(try a.requireString(0), a.bool(1))
    case "toggleSidebar": toggleSidebar(try a.requireString(0))
    case "switchProfile": switchProfile(try a.requireString(0), try a.requireString(1))
    case "moveTabsToWindow": result = JSONValue(moveTabsToWindow(a.strings(0), a.string(1)))
    case "moveTabToProfile": moveTabToProfile(try a.requireString(0), try a.requireString(1))
    case "mergeAllWindows": mergeAllWindows(try a.requireString(0))
    case "reopenClosed": reopenClosed(a.string(0))
    case "reopenClosedTab": reopenClosedTab(a.string(0))
    case "reopenClosedWindow": reopenClosedWindow()
    case "restoreClosed": restoreClosed(try a.requireString(0), a.string(1))
    case "createProfile":
      let o = a.object(0)
      result = .string(
        try createProfile(
          name: o["name"]?.string ?? "", color: optionalString(o, "color"), icon: optionalString(o, "icon"), shareWith: optionalString(o, "shareWith")))
    case "updateProfile": try updateProfile(try a.requireString(0), a.update(1))
    case "deleteProfile": try deleteProfile(try a.requireString(0))
    case "reorderProfiles": try reorderProfiles(a.strings(0))
    case "setDefaultProfile": setDefaultProfile(try a.requireString(0))
    case "profileDataDeleted": profileDataDeleted(try a.requireString(0))
    case "createGroup":
      let o = a.object(1)
      result = .string(
        createGroup(
          a.strings(0), name: optionalString(o, "name"), icon: o["icon"].map { .some($0.string) } ?? nil,
          color: o["color"].map { .some($0.string) } ?? nil))
    case "updateGroup": updateGroup(try a.requireString(0), a.update(1))
    case "addTabsToGroup": addTabsToGroup(try a.requireString(0), a.strings(1))
    case "removeTabsFromGroup": removeTabsFromGroup(a.strings(0))
    case "ungroup": ungroup(try a.requireString(0))
    case "newNestedGroup": result = .string(newNestedGroup(try a.requireString(0)))
    case "closeGroup": closeGroup(try a.requireString(0))
    case "deleteGroup": deleteGroup(try a.requireString(0))
    case "placeTabs": placeTabs(a.strings(0), TabPlacement(json: a[1]))
    case "dropTabs": result = .bool(dropTabs(a.strings(0), Drop(json: a[1])))
    case "pinTabs": pinTabs(a.strings(0), pinned: a.bool(1), row: a.optionalBool(2))
    case "returnToPinnedUrl": returnToPinnedUrl(try a.requireString(0))
    case "setPinnedUrl": setPinnedUrl(try a.requireString(0), a.string(1))
    case "setMuted": setMuted(a.strings(0), a.bool(1))
    case "setSiteMuted": setSiteMuted(try a.requireString(0), a.bool(1))
    case "groupTabs":
      let o = a.object(1)
      result = .string(groupTabs(a.strings(0), pinned: o["pinned"].map(\.truthy) ?? true, name: optionalString(o, "name")))
    case "groupOnto": result = .string(groupOnto(a.strings(0), try a.requireString(1)))
    case "moveGroup":
      let p = a.object(1)
      moveGroup(
        try a.requireString(0),
        GroupPlacement(pinned: p["pinned"]?.truthy ?? false, beforeId: optionalString(p, "beforeId"), parentId: optionalString(p, "parentId")))
    case "duplicateGroup": result = .string(duplicateGroup(try a.requireString(0)))
    case "newTabInGroup": result = .string(newTabInGroup(try a.requireString(0)))
    case "cleanUpTabs": result = JSONValue(cleanUpTabs(try a.requireString(0), inactiveForMs: a[1]?["inactiveForMs"]?.number))
    case "restoreCleaned": restoreCleaned(a.string(0), a.string(1))
    case "clearUnpinnedTabs": result = clearUnpinnedTabs(try a.requireString(0))
    case "undoClearTabs": undoClearTabs(a[0] ?? .null)
    case "removeClosedPin": result = removeClosedPin(try a.requireString(0))
    case "closeAbandonedNewTabs": closeAbandonedNewTabs()
    case "createSplit": result = .string(createSplit(a.strings(0), orientation: a.string(1) ?? "horizontal"))
    case "openSplitPane":
      let o = a.object(1)
      var options = OpenPaneOptions()
      options.tabId = optionalString(o, "tabId")
      options.url = optionalString(o, "url")
      options.anchorTabId = optionalString(o, "anchorTabId")
      options.side = optionalString(o, "side")
      options.background = o["background"]?.truthy
      options.adoptId = optionalString(o, "adoptId")
      options.inPlaceOf = optionalString(o, "inPlaceOf")
      result = openSplitPane(try a.requireString(0), options)
    case "replaceSplitPane": replaceSplitPane(try a.requireString(0), try a.requireString(1))
    case "removeTabFromSplit": removeTabFromSplit(try a.requireString(0))
    case "separateSplit": separateSplit(try a.requireString(0))
    case "updateSplit":
      let o = a.object(1)
      updateSplit(try a.requireString(0), sizes: o["sizes"]?.array?.compactMap(\.number), stackSizes: o["stackSizes"]?.array?.compactMap(\.number))
    case "flipSplit": flipSplit(try a.requireString(0))
    case "toggleSplitOrientation": toggleSplitOrientation(try a.requireString(0))
    case "movePane": movePane(try a.requireString(0), a.int(1))
    case "focusPane": focusPane(try a.requireString(0), a.int(1))
    case "toggleTabLayout": toggleTabLayout(try a.requireString(0))
    case "openPeek": result = .string(openPeek(try a.requireString(0), try a.requireString(1), from: a[2].flatMap { try? PeekPoint(value: $0) }))
    case "closePeek": closePeek(try a.requireString(0))
    case "peekToTab": result = JSONValue(peekToTab(try a.requireString(0), activate: a[1]?["activate"].map(\.truthy) ?? true))
    case "updateSettings": updateSettings(a.object(0), fromSync: a[1]?["fromSync"]?.truthy ?? false)
    case "setFocusedWindow": setFocusedWindow(try a.requireString(0))
    case "upsertDownload": upsertDownload(Download(json: a.object(0)))
    case "removeDownload": removeDownload(try a.requireString(0))
    case "clearDownloads": clearDownloads(a.string(0))
    case "forgetDownloads": forgetDownloads(try a.requireString(0))
    case "hydrate":
      memory.closingWindowUndos.removeAll()
      hydrate(try HydrateData(json: a.object(0)))
    case "tidyPins": result = tidyPins(try a.requireString(0), a.string(1))
    case "untidyPins": untidyPins(try TidiedPins(json: a[0] ?? .null))
    case "renameTileFolder": set(renameTileFolder(state, try a.requireString(0), try a.requireString(1), a.string(2) ?? ""))
    case "newTileFolder": result = JSONValue(makeTileFolder(a.strings(0), a.string(1) ?? ""))
    case "leaveTileFolder": set(leaveTileFolder(state, a.strings(0)))
    case "dissolveTileFolder": set(dissolveTileFolder(state, try a.requireString(0), try a.requireString(1)))
    case "openDraftGroups":
      result = openDraftGroups(try a.requireString(0), try a.requireString(1), (a[2]?.array ?? []).map(GroupDraft.init(json:)))
    case "forgetClosedTab": forgetClosedTab(try a.requireString(0))
    case "setWindowClosing":
      let id = try a.requireString(0)
      if a.bool(1) { memory.closingWindows.insert(id) } else { memory.closingWindows.remove(id) }
    case "setLastTabKeepsWindow": break
    case "noteRemotePinDeletion":
      let profileId = try a.requireString(0)
      memory.remotePinDeletions[profileId] = (memory.remotePinDeletions[profileId] ?? 0) + 1
    case "setHistoryHints": break
    case "setPlayingAudio":
      state.caches.playingAudio = Set(a.strings(0))
    case "setEarlyLaunchTab", "setLaunchBackdrop": break
    case "nextId": result = .string(newId(try a.requireString(0)))
    case "nextNavigation": result = navigationTo(try a.requireString(0), userInitiated: a.bool(1)).jsonValue
    case "stripSnapshot": stripSnapshot(a[0] ?? .null)
    case "stripTransaction": stripTransaction(StripTransaction(json: a[0] ?? .null))
    case "projectStrips": projectStrips()
    case "stripCommandSent": stripCommandSent(a.int(0), a.int(1))
    case "syncPinsApply": result = try SyncPinsApplyRequest(command.args).apply(self)
    case "settlePinChoices": try SettledPinChoices(command.args).apply(self)
    case "applyState":
      var next = state
      for (key, value) in a.object(0) where !Session.commandOnlySlices.contains(key) { try next.applySlice(key, value) }
      next.ui.appDark = state.ui.appDark
      let remote = a[1]?["fromSync"]?.truthy ?? false
      if remote { memory.fromSyncDepth += 1 }
      defer { if remote { memory.fromSyncDepth -= 1 } }
      set(next)
    case "beginTransaction": beginTransaction()
    case "endTransaction": endTransaction()
    case "closeTransactions": closeTransactions()
    case "beginFromSync": memory.fromSyncDepth += 1
    case "endFromSync": memory.fromSyncDepth = max(0, memory.fromSyncDepth - 1)
    case "setAppDark": setAppDark(a.bool(0))
    case "setFind": setFind(try a.requireString(0), a.update(1))
    case "setSelection": setSelection(try a.requireString(0), a.strings(1))
    case "setSelectionAnchor": setSelectionAnchor(try a.requireString(0), try a.requireString(1))
    case "clickTab": clickTab(try a.requireString(0), try a.requireString(1), a.object(2))
    case "openPanel": openPanel(try a.requireString(0), a.string(1) ?? "", a[2])
    case "closePanel": closePanel(try a.requireString(0))
    case "setDownloadsOpen": setDownloadsOpen(try a.requireString(0), a.bool(1))
    default:
      throw CommandError("unknown command \(command.name)")
    }
  }
}
