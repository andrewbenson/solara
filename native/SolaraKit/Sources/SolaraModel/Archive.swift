public let lookKeys: Set<String> = ["icon", "color"]

public struct TabSnapshot: JSONConvertible {
  public var url: String
  public var title: String
  public var favicon: String? { didSet { absent.remove("favicon") } }
  public var pinned: Bool
  public var muted: Bool
  public var zoom: Double
  public var customTitle: String? { didSet { absent.remove("customTitle") } }
  public var customIcon: String? { didSet { absent.remove("customIcon") } }
  public var profileId: String
  public var pinnedUrl: String? { didSet { absent.remove("pinnedUrl") } }
  public var pinnedAsRow: Bool?
  public var tileFolder: TileFolder?
  public var engine: String?
  public var extra: JSONObject = [:]
  public var keyOrder: [String]? = nil
  public internal(set) var absent: Set<String> = []

  public init(url: String, title: String, favicon: String?, pinned: Bool, muted: Bool, zoom: Double, customTitle: String?,
    customIcon: String?, profileId: String, pinnedUrl: String?)
  {
    self.url = url
    self.title = title
    self.favicon = favicon
    self.pinned = pinned
    self.muted = muted
    self.zoom = zoom
    self.customTitle = customTitle
    self.customIcon = customIcon
    self.profileId = profileId
    self.pinnedUrl = pinnedUrl
  }

  public var hasPinnedUrlKey: Bool { !absent.contains("pinnedUrl") }

  public var undefined: Set<String> = []

  public mutating func inheritAbsent(_ keys: Set<String>) {
    let inherited = keys.intersection(["favicon", "customTitle", "customIcon", "pinnedUrl"])
    absent.formUnion(inherited)
    undefined.formUnion(inherited)
  }

  static let keys: Set<String> = [
    "url", "title", "favicon", "pinned", "muted", "zoom", "customTitle", "customIcon", "profileId", "pinnedUrl", "pinnedAsRow", "tileFolder",
    "engine",
  ]

  public init(json: JSONObject) throws {
    try self.init(json: json, alsoKnown: [])
  }

  public init(json: JSONObject, alsoKnown: Set<String>) throws {
    let f = Fields(json, known: Self.keys.union(alsoKnown))
    url = f.string("url")
    title = f.string("title")
    favicon = f.optionalString("favicon")
    pinned = f.bool("pinned")
    muted = f.bool("muted")
    zoom = f.number("zoom", default: 1)
    customTitle = f.optionalString("customTitle")
    customIcon = f.optionalString("customIcon")
    profileId = f.string("profileId")
    pinnedUrl = f.optionalString("pinnedUrl")
    pinnedAsRow = f.optionalBool("pinnedAsRow")
    tileFolder = try f.model("tileFolder")
    engine = f.optionalString("engine")
    extra = f.extra
    keyOrder = f.order
    absent = f.absent(["favicon", "customTitle", "customIcon", "pinnedUrl"])
  }

  public var json: JSONObject {
    var e = Encoder(extra: extra, order: keyOrder)
    e.set("url", url)
    e.set("title", title)
    e.nullable("favicon", favicon, absent: absent)
    e.set("pinned", pinned)
    e.set("muted", muted)
    e.set("zoom", zoom)
    e.nullable("customTitle", customTitle, absent: absent)
    e.nullable("customIcon", customIcon, absent: absent)
    e.nullable("pinnedUrl", pinnedUrl, absent: absent)
    e.optional("pinnedAsRow", pinnedAsRow)
    e.optional("tileFolder", tileFolder)
    e.optional("engine", engine)
    e.set("profileId", profileId)
    return e.object
  }
}

public struct ClosedGroupInfo: JSONConvertible {
  public var id: String
  public var name: String
  public var icon: String? { didSet { absent.remove("icon") } }
  public var color: String? { didSet { absent.remove("color") } }
  public var absent: Set<String> = []
  public var pinned: Bool?
  public var extra: JSONObject = [:]
  public var keyOrder: [String]? = nil

  public init(id: String, name: String, icon: String?, color: String?, pinned: Bool?) {
    self.id = id
    self.name = name
    self.icon = icon
    self.color = color
    self.pinned = pinned
  }

  public init(json: JSONObject) throws {
    let f = Fields(json, known: ["id", "name", "icon", "color", "pinned"])
    id = f.string("id")
    name = f.string("name")
    icon = f.optionalString("icon")
    color = f.optionalString("color")
    absent = f.absent(["icon", "color"])
    pinned = f.optionalBool("pinned")
    extra = f.extra
    keyOrder = f.order
  }

  public var json: JSONObject {
    var e = Encoder(extra: extra, order: keyOrder)
    e.set("id", id)
    e.set("name", name)
    e.nullable("icon", icon, absent: absent)
    e.nullable("color", color, absent: absent)
    e.optional("pinned", pinned)
    return e.object
  }
}

public struct ClosedTab: JSONConvertible {
  public var id: String
  public var tab: TabSnapshot
  public var tabId: String?
  public var restoreFrom: String?
  public var windowId: String
  public var index: Int
  public var group: ClosedGroupInfo?
  public var parents: [ClosedGroupInfo]?
  public var closedAt: Double
  public var pinnedTile: Bool?
  public var small: Bool?
  public var extra: JSONObject = [:]
  public var keyOrder: [String]? = nil

  public init(id: String, tab: TabSnapshot, tabId: String?, restoreFrom: String?, windowId: String, index: Int, group: ClosedGroupInfo?,
    parents: [ClosedGroupInfo]?, closedAt: Double, pinnedTile: Bool? = nil, small: Bool? = nil)
  {
    self.id = id
    self.tab = tab
    self.tabId = tabId
    self.restoreFrom = restoreFrom
    self.windowId = windowId
    self.index = index
    self.group = group
    self.parents = parents
    self.closedAt = closedAt
    self.pinnedTile = pinnedTile
    self.small = small
  }

  public init(json: JSONObject) throws {
    let f = Fields(json, known: ["kind", "id", "tab", "tabId", "restoreFrom", "windowId", "index", "group", "parents", "closedAt", "pinnedTile", "small"])
    id = f.string("id")
    tab = try f.model("tab") ?? TabSnapshot(json: [:])
    tabId = f.optionalString("tabId")
    restoreFrom = f.optionalString("restoreFrom")
    windowId = f.string("windowId")
    index = Int(f.number("index"))
    group = try f.model("group")
    parents = try f.optionalModels("parents")
    closedAt = f.number("closedAt")
    pinnedTile = f.optionalBool("pinnedTile")
    small = f.optionalBool("small")
    extra = f.extra
    keyOrder = f.order
  }

  public var json: JSONObject {
    var e = Encoder(extra: extra, order: keyOrder)
    e.set("kind", "tab")
    e.set("id", id)
    e.set("tab", tab)
    e.optional("tabId", tabId)
    e.optional("restoreFrom", restoreFrom)
    e.set("windowId", windowId)
    e.set("index", Double(index))
    e.nullable("group", group)
    e.optional("parents", parents)
    e.set("closedAt", closedAt)
    e.optional("pinnedTile", pinnedTile)
    e.optional("small", small)
    return e.object
  }
}

public struct ClosedWindowTab: JSONConvertible {
  public var snapshot: TabSnapshot
  public var active: Bool
  public var tabId: String? { didSet { tabIdIsNull = false } }
  public var tabIdIsNull = false

  public init(snapshot: TabSnapshot, active: Bool, tabId: String?) {
    self.snapshot = snapshot
    self.active = active
    self.tabId = tabId
  }

  public init(json: JSONObject) throws {
    snapshot = try TabSnapshot(json: json, alsoKnown: ["active", "tabId"])
    active = json["active"]?.bool ?? false
    tabId = json["tabId"]?.string
    tabIdIsNull = json["tabId"] == .null
  }

  public var json: JSONObject {
    var out = snapshot.json
    out["active"] = .bool(active)
    if let tabId { out["tabId"] = .string(tabId) } else if tabIdIsNull { out["tabId"] = .null }
    return out.ordered(by: snapshot.keyOrder)
  }
}

public struct ClosedWindowGroup: JSONConvertible {
  public var id: String
  public var profileId: String
  public var name: String
  public var icon: String? { didSet { absent.remove("icon") } }
  public var color: String? { didSet { absent.remove("color") } }
  public var absent: Set<String> = []
  public var collapsed: Bool
  public var pinned: Bool
  public var createdAt: Double
  public var autoUngroup: Bool?
  public var pinnedOpenerId: String?
  public var pinKey: String?
  public var parentId: String?
  public var tabIndexes: [Int]
  public var extra: JSONObject = [:]
  public var keyOrder: [String]? = nil

  public init(group g: TabGroup, tabIndexes: [Int]) {
    id = g.id
    profileId = g.profileId
    name = g.name
    icon = g.icon
    color = g.color
    collapsed = g.collapsed
    pinned = g.pinned
    createdAt = g.createdAt
    autoUngroup = g.autoUngroup
    pinnedOpenerId = g.pinnedOpenerId
    pinKey = g.pinKey
    parentId = g.parentId
    extra = g.extra
    absent = g.absent.intersection(lookKeys)
    self.tabIndexes = tabIndexes
  }

  public init(json: JSONObject) throws {
    let f = Fields(json, known: TabGroupFields.keys.union(["tabIndexes"]))
    id = f.string("id")
    profileId = f.string("profileId")
    name = f.string("name")
    icon = f.optionalString("icon")
    color = f.optionalString("color")
    absent = f.absent(["icon", "color"])
    collapsed = f.bool("collapsed")
    pinned = f.bool("pinned")
    createdAt = f.number("createdAt")
    autoUngroup = f.optionalBool("autoUngroup")
    pinnedOpenerId = f.optionalString("pinnedOpenerId")
    pinKey = f.optionalString("pinKey")
    parentId = f.optionalString("parentId")
    tabIndexes = f.numbers("tabIndexes").map { Int($0) }
    extra = f.extra
    keyOrder = f.order
  }

  public var json: JSONObject {
    var e = Encoder(extra: extra, order: keyOrder)
    e.set("id", id)
    e.set("profileId", profileId)
    e.set("name", name)
    e.nullable("icon", icon, absent: absent)
    e.nullable("color", color, absent: absent)
    e.set("collapsed", collapsed)
    e.set("pinned", pinned)
    e.set("createdAt", createdAt)
    e.optional("autoUngroup", autoUngroup)
    e.optional("pinnedOpenerId", pinnedOpenerId)
    e.optional("pinKey", pinKey)
    e.optional("parentId", parentId)
    e.set("tabIndexes", tabIndexes.map(Double.init))
    return e.object
  }
}

public struct ClosedWindow: JSONConvertible {
  public var id: String
  public var profileId: String
  public var sidebarOpen: Bool
  public var frame: [Double]?
  public var tabLayout: String?
  public var fullScreen: Double?
  public var sidebarWidth: Double?
  public var sidebarIconsOnly: Bool?
  public var sidePanelWidth: Double?
  public var tabs: [ClosedWindowTab]
  public var groups: [ClosedWindowGroup]
  public var closedAt: Double
  public var extra: JSONObject = [:]
  public var keyOrder: [String]? = nil
  public var windowExtra: JSONObject = [:]
  public var windowKeyOrder: [String]? = nil
  public var absent: Set<String> = []

  public init(id: String, profileId: String, sidebarOpen: Bool, frame: [Double]?, tabs: [ClosedWindowTab], groups: [ClosedWindowGroup], closedAt: Double) {
    self.id = id
    self.profileId = profileId
    self.sidebarOpen = sidebarOpen
    self.frame = frame
    self.tabs = tabs
    self.groups = groups
    self.closedAt = closedAt
  }

  public init(json: JSONObject) throws {
    let f = Fields(json, known: ["kind", "id", "window", "tabs", "groups", "closedAt"])
    id = f.string("id")
    let w = Fields(f.value("window")?.object ?? [:], known: ["profileId", "sidebarOpen", "frame", "tabLayout", "fullScreen", "sidebarWidth", "sidebarIconsOnly", "sidePanelWidth"])
    profileId = w.string("profileId")
    sidebarOpen = w.bool("sidebarOpen")
    frame = w.optionalNumbers("frame")
    tabLayout = w.optionalString("tabLayout")
    fullScreen = w.optionalNumber("fullScreen")
    sidebarWidth = w.optionalNumber("sidebarWidth")
    sidebarIconsOnly = w.optionalBool("sidebarIconsOnly")
    sidePanelWidth = w.optionalNumber("sidePanelWidth")
    windowExtra = w.extra
    windowKeyOrder = w.order
    absent = w.absent(["frame"])
    tabs = try f.strictModels("tabs")
    groups = try f.models("groups")
    closedAt = f.number("closedAt")
    extra = f.extra
    keyOrder = f.order
  }

  public var json: JSONObject {
    var w = Encoder(extra: windowExtra, order: windowKeyOrder)
    w.set("profileId", profileId)
    w.set("sidebarOpen", sidebarOpen)
    w.optional("tabLayout", tabLayout)
    w.optional("fullScreen", fullScreen)
    w.optional("sidebarWidth", sidebarWidth)
    w.optional("sidebarIconsOnly", sidebarIconsOnly)
    w.optional("sidePanelWidth", sidePanelWidth)
    if !absent.contains("frame") { w.nullable("frame", frame) }
    var e = Encoder(extra: extra, order: keyOrder)
    e.set("kind", "window")
    e.set("id", id)
    e.set("window", .object(w.object))
    e.set("tabs", tabs)
    e.set("groups", groups)
    e.set("closedAt", closedAt)
    return e.object
  }
}

public struct ParkedTab: JSONConvertible {
  public var snapshot: TabSnapshot
  public var id: String
  public var groupId: String?
  public var restoreFrom: String?

  public init(snapshot: TabSnapshot, id: String, groupId: String?, restoreFrom: String?) {
    self.snapshot = snapshot
    self.id = id
    self.groupId = groupId
    self.restoreFrom = restoreFrom
  }

  public init(json: JSONObject) throws {
    snapshot = try TabSnapshot(json: json, alsoKnown: ["id", "groupId", "restoreFrom"])
    id = json["id"]?.string ?? ""
    groupId = json["groupId"]?.string
    restoreFrom = json["restoreFrom"]?.string
  }

  public var json: JSONObject {
    var out = snapshot.json
    if let restoreFrom { out["restoreFrom"] = .string(restoreFrom) }
    out["id"] = .string(id)
    out["groupId"] = JSONValue(groupId)
    return out.ordered(by: snapshot.keyOrder)
  }
}

public struct ParkedGroup: JSONConvertible {
  public var id: String
  public var name: String
  public var icon: String? { didSet { absent.remove("icon") } }
  public var color: String? { didSet { absent.remove("color") } }
  public var absent: Set<String> = []
  public var collapsed: Bool
  public var parentId: String?
  public var extra: JSONObject = [:]
  public var keyOrder: [String]? = nil

  public init(id: String, name: String, icon: String?, color: String?, collapsed: Bool, parentId: String?) {
    self.id = id
    self.name = name
    self.icon = icon
    self.color = color
    self.collapsed = collapsed
    self.parentId = parentId
  }

  public init(json: JSONObject) throws {
    let f = Fields(json, known: ["id", "name", "icon", "color", "collapsed", "parentId"])
    id = f.string("id")
    name = f.string("name")
    icon = f.optionalString("icon")
    color = f.optionalString("color")
    absent = f.absent(["icon", "color"])
    collapsed = f.bool("collapsed")
    parentId = f.optionalString("parentId")
    extra = f.extra
    keyOrder = f.order
  }

  public var json: JSONObject {
    var e = Encoder(extra: extra, order: keyOrder)
    e.set("id", id)
    e.set("name", name)
    e.nullable("icon", icon, absent: absent)
    e.nullable("color", color, absent: absent)
    e.set("collapsed", collapsed)
    e.optional("parentId", parentId)
    return e.object
  }
}

public struct ParkedSplit: JSONConvertible {
  public var ids: [String]
  public var orientation: String
  public var sizes: [Double]
  public var stack: SplitStack?

  public init(ids: [String], orientation: String, sizes: [Double], stack: SplitStack?) {
    self.ids = ids
    self.orientation = orientation
    self.sizes = sizes
    self.stack = stack
  }

  public init(json: JSONObject) throws {
    let f = Fields(json, known: [])
    ids = f.strings("ids")
    orientation = f.string("orientation")
    sizes = f.numbers("sizes")
    stack = try f.model("stack")
  }

  public var json: JSONObject {
    var e = Encoder()
    e.set("ids", ids)
    e.set("orientation", orientation)
    e.set("sizes", sizes)
    e.optional("stack", stack)
    return e.object
  }
}

public struct ParkedPins: JSONConvertible {
  public var tabs: [ParkedTab]
  public var groups: [ParkedGroup]
  public var splits: [ParkedSplit]?
  public var extra: JSONObject = [:]
  public var keyOrder: [String]? = nil

  public init(tabs: [ParkedTab], groups: [ParkedGroup], splits: [ParkedSplit]?) {
    self.tabs = tabs
    self.groups = groups
    self.splits = splits
  }

  public init(json: JSONObject) throws {
    let f = Fields(json, known: ["tabs", "groups", "splits"])
    tabs = try f.models("tabs")
    groups = try f.models("groups")
    splits = try f.optionalModels("splits")
    extra = f.extra
    keyOrder = f.order
  }

  public var json: JSONObject {
    var e = Encoder(extra: extra, order: keyOrder)
    e.set("tabs", tabs)
    e.set("groups", groups)
    e.optional("splits", splits)
    return e.object
  }
}

public struct NestedGroupSnapshot: JSONConvertible {
  public var id: String
  public var name: String
  public var icon: String? { didSet { absent.remove("icon") } }
  public var color: String? { didSet { absent.remove("color") } }
  public var absent: Set<String> = []
  public var collapsed: Bool
  public var parentId: String
  public var tabIndexes: [Int]

  public init(id: String, name: String, icon: String?, color: String?, collapsed: Bool, parentId: String, tabIndexes: [Int]) {
    self.id = id
    self.name = name
    self.icon = icon
    self.color = color
    self.collapsed = collapsed
    self.parentId = parentId
    self.tabIndexes = tabIndexes
  }

  public init(json: JSONObject) throws {
    let f = Fields(json, known: [])
    id = f.string("id")
    name = f.string("name")
    icon = f.optionalString("icon")
    color = f.optionalString("color")
    absent = f.absent(["icon", "color"])
    collapsed = f.bool("collapsed")
    parentId = f.string("parentId")
    tabIndexes = f.numbers("tabIndexes").map { Int($0) }
  }

  public var json: JSONObject {
    var e = Encoder()
    e.set("id", id)
    e.set("name", name)
    e.nullable("icon", icon, absent: absent)
    e.nullable("color", color, absent: absent)
    e.set("collapsed", collapsed)
    e.set("parentId", parentId)
    e.set("tabIndexes", tabIndexes.map(Double.init))
    return e.object
  }
}

public struct ClosedGroupHead: JSONConvertible {
  public var id: String
  public var name: String
  public var icon: String? { didSet { absent.remove("icon") } }
  public var color: String? { didSet { absent.remove("color") } }
  public var absent: Set<String> = []
  public var pinned: Bool
  public var parentId: String?
  public var extra: JSONObject = [:]
  public var keyOrder: [String]? = nil

  public init(id: String, name: String, icon: String?, color: String?, pinned: Bool, parentId: String?) {
    self.id = id
    self.name = name
    self.icon = icon
    self.color = color
    self.pinned = pinned
    self.parentId = parentId
  }

  public init(json: JSONObject) throws {
    let f = Fields(json, known: ["id", "name", "icon", "color", "pinned", "parentId"])
    id = f.string("id")
    name = f.string("name")
    icon = f.optionalString("icon")
    color = f.optionalString("color")
    absent = f.absent(["icon", "color"])
    pinned = f.bool("pinned")
    parentId = f.optionalString("parentId")
    extra = f.extra
    keyOrder = f.order
  }

  public var json: JSONObject {
    var e = Encoder(extra: extra, order: keyOrder)
    e.set("id", id)
    e.set("name", name)
    e.nullable("icon", icon, absent: absent)
    e.nullable("color", color, absent: absent)
    e.set("pinned", pinned)
    e.optional("parentId", parentId)
    return e.object
  }
}

public struct ClosedGroup: JSONConvertible {
  public var id: String
  public var group: ClosedGroupHead
  public var tabs: [TabSnapshot]
  public var tabIds: [String]?
  public var nested: [NestedGroupSnapshot]?
  public var windowId: String
  public var index: Int
  public var closedAt: Double
  public var extra: JSONObject = [:]
  public var keyOrder: [String]? = nil

  public init(id: String, group: ClosedGroupHead, tabs: [TabSnapshot], tabIds: [String]?, nested: [NestedGroupSnapshot]?, windowId: String,
    index: Int, closedAt: Double)
  {
    self.id = id
    self.group = group
    self.tabs = tabs
    self.tabIds = tabIds
    self.nested = nested
    self.windowId = windowId
    self.index = index
    self.closedAt = closedAt
  }

  public init(json: JSONObject) throws {
    let f = Fields(json, known: ["kind", "id", "group", "tabs", "tabIds", "nested", "windowId", "index", "closedAt"])
    id = f.string("id")
    group = try f.model("group") ?? ClosedGroupHead(json: [:])
    tabs = try f.models("tabs")
    tabIds = f.optionalStrings("tabIds")
    nested = try f.optionalModels("nested")
    windowId = f.string("windowId")
    index = Int(f.number("index"))
    closedAt = f.number("closedAt")
    extra = f.extra
    keyOrder = f.order
  }

  public var json: JSONObject {
    var e = Encoder(extra: extra, order: keyOrder)
    e.set("kind", "group")
    e.set("id", id)
    e.set("group", group)
    e.set("tabs", tabs)
    e.optional("tabIds", tabIds)
    e.optional("nested", nested)
    e.set("windowId", windowId)
    e.set("index", Double(index))
    e.set("closedAt", closedAt)
    return e.object
  }
}

extension ClosedWindow {
  public mutating func keepPresentation(of window: BrowserWindow) {
    tabLayout = window.tabLayout
    fullScreen = window.fullScreen
    sidebarWidth = window.sidebarWidth
    sidebarIconsOnly = window.sidebarIconsOnly
    sidePanelWidth = window.sidePanelWidth
  }
}
