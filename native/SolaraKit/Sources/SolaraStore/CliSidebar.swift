import SolaraModel

extension Store {
  @discardableResult
  public func cliSidebar(_ request: JSONValue) throws -> JSONValue {
    let preflight = try CliSidebarPlan(state: committedSnapshot.state, request: request)
    if preflight.operation == "sidebar.list" { return try preflight.inventory() }
    let preview = try preflight.mutation()
    if preflight.values["dryRun"]?.bool == true {
      return ["operation": .string(preflight.operation), "dryRun": true, "changes": JSONValue([preview.description])]
    }
    return try sequence {
      let planner = try CliSidebarPlan(state: state, request: request)
      if planner.operation == "sidebar.list" { return try planner.inventory() }
      let plan = try planner.mutation()
      let dryRun = planner.values["dryRun"]?.bool ?? false
      var response: JSONObject = ["operation": .string(planner.operation), "dryRun": .bool(dryRun), "changes": JSONValue([plan.description])]
      if !dryRun && !plan.commands.isEmpty {
        let commit = try dispatch(plan.commands, origin: .native)
        if plan.createsId, let id = commit.result?.string, !id.isEmpty { response["id"] = .string(id) }
      }
      return .object(response)
    }
  }
}

private struct CliSidebarMutation {
  let commands: [Command]
  let description: String
  var createsId = false
}

private struct CliSidebarPlan {
  let state: BrowserState
  let values: JSONObject
  let operation: String

  init(state: BrowserState, request: JSONValue) throws {
    guard let values = request.object, let operation = values["operation"]?.string else { throw CommandError("sidebar request needs an operation") }
    self.state = state
    self.values = values
    self.operation = operation
    try Self.bounded(operation, key: "operation", limit: 64)
    if let dryRun = values["dryRun"], dryRun.bool == nil { throw CommandError("dryRun must be a boolean") }
    let keys: Set<String>
    switch operation {
    case "sidebar.list": keys = []
    case "group.create": keys = ["name", "color", "tabs", "windowId"]
    case "folder.create": keys = ["name", "tabs", "windowId"]
    case "group.rename", "folder.rename": keys = ["id", "name", "windowId"]
    case "group.delete", "folder.delete": keys = ["id", "windowId"]
    case "tab.move": keys = ["id", "toGroup", "toFolder", "toWindow", "toProfile"]
    case "tab.pin", "tab.unpin": keys = ["id"]
    case "tab.rename": keys = ["id", "title"]
    case "tab.reorder": keys = ["id", "before", "after"]
    default: throw CommandError("unknown sidebar operation \(operation)")
    }
    guard Set(values.keys).isSubset(of: keys.union(["operation", "dryRun"])) else { throw CommandError("unexpected argument for \(operation)") }
    for key in keys where values[key] != nil {
      if key == "tabs" {
        guard let array = values[key]?.array, !array.isEmpty else { throw CommandError("tabs must contain at least one tab id") }
        guard array.count <= 500 else { throw CommandError("tabs must contain at most 500 entries") }
        for item in array {
          guard let id = item.string else { throw CommandError("tabs must contain tab ids") }
          try Self.identifier(id, key: "tabs")
        }
      } else {
        guard let value = values[key]?.string else { throw CommandError("\(key) must be a string") }
        switch key {
        case "name", "title", "toProfile": try Self.bounded(value, key: key, limit: 256)
        case "color": try Self.bounded(value, key: key, limit: 32)
        default: try Self.identifier(value, key: key)
        }
      }
    }
    if operation.hasPrefix("folder."), let name = values["name"]?.string, name != name.jsTrim() {
      throw CommandError("Folder names must not start or end with whitespace")
    }
  }

  static func bounded(_ value: String, key: String, limit: Int) throws {
    guard value.unicodeScalars.prefix(limit + 1).count <= limit else { throw CommandError("\(key) must contain at most \(limit) Unicode scalars") }
  }

  static func identifier(_ value: String, key: String) throws {
    try bounded(value, key: key, limit: 256)
    guard !value.isEmpty, value.utf8.allSatisfy({ (48...57).contains($0) || (65...90).contains($0) || (97...122).contains($0) || [45, 46, 58, 64, 95].contains($0) }) else {
      throw CommandError("\(key) must use only ASCII letters, digits, dot, underscore, colon, at sign or hyphen")
    }
  }

  func string(_ key: String, empty: Bool = false) throws -> String {
    guard let value = values[key]?.string, empty || !value.jsTrim().isEmpty else { throw CommandError("\(operation) needs \(key)") }
    return value
  }

  func profile(_ id: String) throws {
    try Self.identifier(id, key: "profile id")
    guard !Ids.isIncognitoProfile(id) else { throw CommandError("Private profiles cannot be controlled by the CLI") }
    guard state.profiles[id] != nil else { throw CommandError("Unknown profile id: \(id)") }
  }

  @discardableResult
  func window(_ id: String) throws -> BrowserWindow {
    try Self.identifier(id, key: "window id")
    guard let window = state.windows[id] else { throw CommandError("Unknown window id: \(id)") }
    guard !window.incognito else { throw CommandError("Private windows cannot be controlled by the CLI") }
    try profile(window.profileId)
    guard !window.isSmall else { throw CommandError("Little Solara windows do not have an editable sidebar") }
    return window
  }

  func tab(_ id: String) throws -> Tab {
    try Self.identifier(id, key: "tab id")
    guard let tab = state.tabs[id] else { throw CommandError("Unknown tab id: \(id)") }
    try profile(tab.profileId)
    try window(tab.windowId)
    return tab
  }

  func group(_ id: String) throws -> TabGroup {
    try Self.identifier(id, key: "group id")
    guard let group = state.groups[id] else { throw CommandError("Unknown group id: \(id)") }
    try profile(group.profileId)
    try window(group.windowId)
    return group
  }

  func folder(_ id: String, windowId: String? = nil) throws -> (Tab, TileFolder) {
    try Self.identifier(id, key: "folder id")
    if let windowId { try window(windowId) }
    let owners = state.tabs.values.filter { tileFolderOf($0)?.id == id }
    guard !owners.isEmpty else { throw CommandError("Unknown folder id: \(id)") }
    let candidates = owners.filter { windowId == nil || $0.windowId == windowId }
    if candidates.isEmpty {
      for owner in owners { _ = try tab(owner.id) }
      throw CommandError("The folder is in another window; move the tab to that window first")
    }
    let preferred = candidates.first { $0.windowId == state.ui.focusedWindowId } ?? candidates.first!
    let owner = try tab(preferred.id)
    return (owner, tileFolderOf(owner)!)
  }

  func samePlace(_ a: Tab, _ b: Tab) throws {
    guard a.windowId == b.windowId && a.profileId == b.profileId else {
      throw CommandError("Tabs must belong to the same window and profile; move the tab to that window or profile first")
    }
  }

  func selectedTabs() throws -> [String] {
    let ids: [String]
    if let supplied = values["tabs"] {
      guard let array = supplied.array, !array.isEmpty, array.allSatisfy({ $0.string != nil }) else { throw CommandError("tabs must contain at least one tab id") }
      ids = OrderedSet(array.compactMap(\.string)).elements
    } else {
      let id = try values["windowId"].map { _ in try string("windowId") } ?? state.ui.focusedWindowId
      guard let id else { throw CommandError("No focused window; give --tabs with sidebar tab ids") }
      try window(id)
      guard let active = state.activeTabId(id) else { throw CommandError("No active tab; give --tabs with sidebar tab ids") }
      ids = [active]
    }
    let first = try tab(ids[0])
    if values["windowId"] != nil {
      let context = try string("windowId")
      try window(context)
      guard first.windowId == context else { throw CommandError("The tabs are not in the requested window") }
    }
    var selection = OrderedSet(ids)
    for id in ids {
      let panes = Splits.splitRowPanes(state, Splits.splitOf(state, id))
      guard panes.contains(id) else { continue }
      for pane in panes {
        selection.insert(pane)
        guard selection.count <= 500 else { throw CommandError("Expanded tabs must contain at most 500 tab ids") }
      }
    }
    let expanded = selection.elements
    for id in expanded { try samePlace(first, tab(id)) }
    return expanded
  }

  func mutation() throws -> CliSidebarMutation {
    switch operation {
    case "group.create", "folder.create":
      let name = try string("name")
      let ids = try selectedTabs()
      if operation == "folder.create" {
        guard !ids.contains(where: { Splits.splitOf(state, $0) != nil }) else { throw CommandError("Split rows cannot be placed in a Top Apps folder; separate the split first") }
        return CliSidebarMutation(commands: [Command("newTileFolder", [JSONValue(ids), .string(name)])], description: "Create folder \(name) with tabs \(ids.joined(separator: ", "))", createsId: true)
      }
      var options: JSONObject = ["name": .string(name)]
      var colorDescription = ""
      if values["color"] != nil {
        let color = try string("color")
        guard ["neutral", "none", "grey", "blue", "red", "yellow", "green", "pink", "purple", "cyan", "orange"].contains(color) else { throw CommandError("Unknown group color: \(color)") }
        options["color"] = color == "neutral" ? .null : .string(color)
        colorDescription = " (color \(color))"
      }
      var commands: [Command] = []
      if ids.contains(where: { state.tabs[$0]?.pinned == true }) { commands.append(Command("pinTabs", [JSONValue(ids), false])) }
      commands.append(Command("createGroup", [JSONValue(ids), .object(options)]))
      return CliSidebarMutation(commands: commands, description: "Create group \(name)\(colorDescription) with tabs \(ids.joined(separator: ", "))", createsId: true)
    case "group.rename", "group.delete":
      let id = try string("id")
      let group = try group(id)
      if values["windowId"] != nil {
        let context = try string("windowId")
        try window(context)
        guard context == group.windowId else { throw CommandError("The group is not in the requested window") }
      }
      if operation == "group.delete" {
        return CliSidebarMutation(commands: [Command("deleteGroup", [.string(id)])], description: "Delete group \(id) and its tabs")
      }
      let name = try string("name")
      return CliSidebarMutation(commands: [Command("updateGroup", [.string(id), ["name": .string(name)]])], description: "Rename group \(id) to \(name)")
    case "folder.rename", "folder.delete":
      let id = try string("id")
      let windowId = try values["windowId"].map { _ in try string("windowId") }
      let (owner, _) = try folder(id, windowId: windowId)
      if operation == "folder.delete" {
        return CliSidebarMutation(commands: [Command("dissolveTileFolder", [.string(owner.windowId), .string(id)])], description: "Dissolve folder \(id), keeping its pinned tabs")
      }
      let name = try string("name")
      return CliSidebarMutation(commands: [Command("renameTileFolder", [.string(owner.windowId), .string(id), .string(name)])], description: "Rename folder \(id) to \(name)")
    case "tab.pin", "tab.unpin":
      let id = try string("id")
      let tab = try tab(id)
      let pinned = operation == "tab.pin"
      let already = pinned ? tab.pinned : !state.inPinnedContainer(id)
      return CliSidebarMutation(commands: already ? [] : [Command("pinTabs", [JSONValue([id]), .bool(pinned)])], description: "\(pinned ? "Pin" : "Unpin") tab \(id)\(already ? " (already set; no change)" : "")")
    case "tab.rename":
      let id = try string("id")
      _ = try tab(id)
      let title = try string("title", empty: true)
      return CliSidebarMutation(commands: [Command("updateTab", [.string(id), ["customTitle": title.isEmpty ? .null : .string(title)]])], description: "Rename tab \(id) to \(title)")
    case "tab.move": return try move()
    case "tab.reorder": return try reorder()
    default: throw CommandError("unknown sidebar operation \(operation)")
    }
  }

  func move() throws -> CliSidebarMutation {
    let id = try string("id")
    let source = try tab(id)
    let destinations = ["toGroup", "toFolder", "toWindow", "toProfile"].filter { values[$0] != nil }
    guard destinations.count == 1 else { throw CommandError("tab.move needs exactly one destination") }
    let kind = destinations[0]
    let destination = try string(kind)
    let commands: [Command]
    switch kind {
    case "toGroup":
      let target = try group(destination)
      guard source.windowId == target.windowId && source.profileId == target.profileId else { throw CommandError("The group is in another window or profile; move the tab there first") }
      commands = [Command("placeTabs", [JSONValue([id]), ["pinned": false, "groupId": .string(destination)]])]
    case "toFolder":
      let (owner, _) = try folder(destination, windowId: source.windowId)
      try samePlace(source, owner)
      guard Splits.splitOf(state, id) == nil else { throw CommandError("Split rows cannot be placed in a Top Apps folder; separate the split first") }
      commands = owner.id == id ? [] : [Command("dropTabs", [JSONValue([id]), ["type": "folder", "ontoId": .string(owner.id)]])]
    case "toWindow":
      try window(destination)
      commands = source.windowId == destination ? [] : [Command("moveTabsToWindow", [JSONValue([id]), .string(destination)])]
    default:
      let matches = state.profiles.values.filter { $0.name == destination }
      guard !matches.isEmpty else {
        if Ids.isIncognitoProfile(destination) { throw CommandError("Private profiles cannot be controlled by the CLI") }
        throw CommandError("Unknown profile name: \(destination)")
      }
      guard matches.count == 1 else { throw CommandError("Ambiguous profile name: \(destination)") }
      let target = matches[0]
      try profile(target.id)
      commands = source.profileId == target.id ? [] : [Command("moveTabToProfile", [.string(id), .string(target.id)])]
    }
    let label = ["toGroup": "to group", "toFolder": "to folder", "toWindow": "to window", "toProfile": "to profile"][kind]!
    let detail = kind == "toProfile" && !commands.isEmpty ? " (fresh navigation in the destination profile)" : ""
    return CliSidebarMutation(commands: commands, description: "Move tab \(id) \(label) \(destination)\(detail)")
  }

  func reorder() throws -> CliSidebarMutation {
    let id = try string("id")
    let source = try tab(id)
    let anchors = ["before", "after"].filter { values[$0] != nil }
    guard anchors.count == 1 else { throw CommandError("tab.reorder needs exactly one of before or after") }
    let anchorId = try string(anchors[0])
    let anchor = try tab(anchorId)
    try samePlace(source, anchor)
    let groupId = Groups.innermostGroupOf(state.groups, id)?.id
    guard source.pinSection == anchor.pinSection,
      groupId == Groups.innermostGroupOf(state.groups, anchorId)?.id,
      tileFolderOf(source)?.id == tileFolderOf(anchor)?.id
    else { throw CommandError("Reorder within the same pin section, group and folder; use tab move to change containers") }
    let moving = Set(Splits.withSplitRows(state, [id]))
    let target = Set(Splits.withSplitRows(state, [anchorId]))
    if !moving.isDisjoint(with: target) {
      return CliSidebarMutation(commands: [], description: "Tab \(id) is already in the target row; no change")
    }
    let order = state.windows[source.windowId]!.tabIds
    let before: String?
    if anchors[0] == "before" { before = order.first { target.contains($0) } }
    else {
      let last = order.lastIndex { target.contains($0) }!
      before = order.dropFirst(last + 1).first { !moving.contains($0) }
    }
    let placement: JSONValue = ["pinned": .bool(source.pinned), "row": .bool(source.pinnedAsRow == true), "groupId": JSONValue(groupId), "beforeId": JSONValue(before), "last": .bool(before == nil)]
    return CliSidebarMutation(commands: [Command("placeTabs", [JSONValue([id]), placement])], description: "Move tab \(id) \(anchors[0]) tab \(anchorId)")
  }

  func inventory() throws -> JSONValue {
    let profiles = state.profiles.values.filter { !Ids.isIncognitoProfile($0.id) }
    let windows = state.windowOrder.compactMap { state.windows[$0] }.filter { !$0.incognito && !$0.isSmall && !Ids.isIncognitoProfile($0.profileId) && state.profiles[$0.profileId] != nil }
    let windowIds = Set(windows.map(\.id))
    let tabs = windows.flatMap { $0.tabIds }.compactMap { state.tabs[$0] }.filter { !Ids.isIncognitoProfile($0.profileId) && state.profiles[$0.profileId] != nil }
    let tabIds = Set(tabs.map(\.id))
    let groups = state.groups.values.filter { windowIds.contains($0.windowId) && !Ids.isIncognitoProfile($0.profileId) && state.profiles[$0.profileId] != nil }
    var folders: [JSONValue] = []
    var seen = Set<String>()
    for tab in tabs {
      guard let folder = tileFolderOf(tab), seen.insert(tab.windowId + "\u{1}" + folder.id).inserted else { continue }
      folders.append(["id": .string(folder.id), "windowId": .string(tab.windowId), "profileId": .string(tab.profileId), "name": .string(folder.name), "tabIds": JSONValue(folderMembers(state, tab.windowId, folder.id))])
    }
    var inventory = CliSidebarInventory(counts: ["profiles": JSONValue(profiles.count), "windows": JSONValue(windows.count), "tabs": JSONValue(tabs.count), "groups": JSONValue(groups.count), "folders": JSONValue(folders.count)])
    for profile in profiles { inventory.append(["id": .string(profile.id), "name": .string(profile.name)], to: "profiles") }
    for window in windows {
      inventory.append(["id": .string(window.id), "profileId": .string(window.profileId), "tabIds": JSONValue(window.tabIds.filter { tabIds.contains($0) })], to: "windows")
    }
    for group in groups {
      inventory.append(["id": .string(group.id), "windowId": .string(group.windowId), "profileId": .string(group.profileId), "name": .string(group.name), "color": JSONValue(group.color), "tabIds": JSONValue(group.tabIds)], to: "groups")
    }
    for folder in folders { inventory.append(folder.object!, to: "folders") }
    for tab in tabs {
      inventory.append(["id": .string(tab.id), "windowId": .string(tab.windowId), "profileId": .string(tab.profileId), "title": .string(tab.customTitle ?? tab.title), "url": .string(tab.url), "pinned": .bool(tab.pinned), "groupId": JSONValue(Groups.innermostGroupOf(state.groups, tab.id)?.id), "folderId": JSONValue(tileFolderOf(tab)?.id)], to: "tabs")
    }
    return inventory.value
  }
}

private struct CliSidebarInventory {
  private var rows: [String: [JSONValue]] = [:]
  private var more: JSONObject
  private var bytes = 0

  init(counts: JSONObject) {
    more = counts
    bytes = Self.wireBytes(value) + 32
  }

  var value: JSONValue {
    [
      "operation": "sidebar.list",
      "profiles": .array(rows["profiles"] ?? []),
      "windows": .array(rows["windows"] ?? []),
      "tabs": .array(rows["tabs"] ?? []),
      "groups": .array(rows["groups"] ?? []),
      "folders": .array(rows["folders"] ?? []),
      "more": .object(more),
    ]
  }

  mutating func append(_ source: JSONObject, to section: String) {
    let row = Self.capped(source)
    let size = Self.wireBytes(row) + 1
    guard bytes + size <= 262_144 else { return }
    bytes += size
    rows[section, default: []].append(row)
    more[section] = JSONValue(more[section]!.int! - 1)
  }

  private static func wireBytes(_ value: JSONValue) -> Int {
    let text = value.text()
    return text.utf8.count + text.unicodeScalars.reduce(0) { extra, scalar in
      switch scalar.value {
      case 0x3C: extra + 5
      case 0x2028, 0x2029: extra + 3
      default: extra
      }
    }
  }

  private static func capped(_ source: JSONObject) -> JSONValue {
    var row: JSONObject = [:]
    var more: JSONObject = [:]
    var truncated = false
    for (key, value) in source {
      if key == "tabIds", let ids = value.array {
        row[key] = .array(ids.prefix(500).map { capped($0, key: key, truncated: &truncated) })
        if ids.count > 500 {
          more[key] = JSONValue(ids.count - 500)
          truncated = true
        }
      } else {
        row[key] = capped(value, key: key, truncated: &truncated)
      }
    }
    if truncated { row["truncated"] = true }
    if !more.isEmpty { row["more"] = .object(more) }
    return .object(row)
  }

  private static func capped(_ value: JSONValue, key: String, truncated: inout Bool) -> JSONValue {
    guard let string = value.string else { return value }
    let limit: Int
    switch key {
    case "id", "windowId", "profileId", "groupId", "folderId", "tabIds": limit = 256
    case "url": limit = 8192
    case "color": limit = 32
    default: limit = 1024
    }
    let scalars = Array(string.unicodeScalars.prefix(limit + 1))
    guard scalars.count > limit else { return value }
    truncated = true
    return .string(String(String.UnicodeScalarView(scalars.prefix(limit))))
  }
}
