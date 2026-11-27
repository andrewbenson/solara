import Foundation

public struct PanePermissionRequest: Equatable, Sendable {
  public var id: String
  public var browserId: Int
  public var origin: String
  public var permissions: [String]

  public init?(_ payload: [String: Any]) {
    guard let id = payload["id"] as? String, let browserId = (payload["browserId"] as? NSNumber)?.intValue else { return nil }
    self.id = id
    self.browserId = browserId
    origin = payload["origin"] as? String ?? ""
    permissions = payload["permissions"] as? [String] ?? []
  }

  public var key: String { id }
}

public struct PaneDeviceChooser: Equatable, Sendable {
  public struct Option: Equatable, Sendable {
    public var name: String
    public var connected: Bool
    public var paired: Bool
    public var signal: Int
  }

  public var id: Int
  public var browserId: Int
  public var open: Bool
  public var title: String
  public var okLabel: String
  public var cancelLabel: String
  public var noOptionsText: String
  public var scanningText: String
  public var refreshing: Bool
  public var canRefresh: Bool
  public var adapterOff: Bool
  public var unauthorized: Bool
  public var bothButtonsEnabled: Bool
  public var showSignal: Bool
  public var options: [Option]

  public init?(_ payload: [String: Any]) {
    guard let id = (payload["id"] as? NSNumber)?.intValue, let browserId = (payload["browserId"] as? NSNumber)?.intValue else { return nil }
    func flag(_ name: String) -> Bool { (payload[name] as? NSNumber)?.boolValue ?? false }
    func text(_ name: String) -> String { payload[name] as? String ?? "" }
    self.id = id
    self.browserId = browserId
    open = flag("open")
    title = text("title")
    okLabel = text("okLabel")
    cancelLabel = text("cancelLabel")
    noOptionsText = text("noOptionsText")
    scanningText = text("scanningText")
    refreshing = flag("refreshing")
    canRefresh = flag("canRefresh")
    adapterOff = flag("adapterOff")
    unauthorized = flag("unauthorized")
    bothButtonsEnabled = flag("bothButtonsEnabled")
    showSignal = flag("showSignal")
    options = (payload["options"] as? [[String: Any]] ?? []).map {
      Option(name: $0["name"] as? String ?? "", connected: ($0["connected"] as? NSNumber)?.boolValue ?? false, paired: ($0["paired"] as? NSNumber)?.boolValue ?? false, signal: ($0["signal"] as? NSNumber)?.intValue ?? 0)
    }
  }

  public var scanning: Bool { bothButtonsEnabled }
  public var blocked: Bool { adapterOff || unauthorized }

  public func valid(_ selected: Int?) -> Bool { scanning || (selected.map { $0 < options.count } ?? false) }

  public func choice(_ index: Int?, selected: Int?) -> Int? {
    if scanning { return -1 }
    return index ?? selected
  }
}

public struct PaneBrowsers: Sendable {
  public static let orphanLimit = 32
  public static let parkedChooserLimit = 8

  public private(set) var tabs: [Int: String] = [:]
  private var orphans: [PanePermissionRequest] = []
  private var parkedChoosers: [PaneDeviceChooser] = []

  public init() {}

  public func tab(_ browserId: Int) -> String? { tabs[browserId] }

  public mutating func overflow() -> [PanePermissionRequest] {
    guard orphans.count > Self.orphanLimit else { return [] }
    let dropped = Array(orphans.prefix(orphans.count - Self.orphanLimit))
    orphans.removeFirst(dropped.count)
    return dropped
  }

  public mutating func park(_ chooser: PaneDeviceChooser) {
    parkedChoosers.removeAll { $0.browserId == chooser.browserId || $0.id == chooser.id }
    guard chooser.open else { return }
    parkedChoosers.append(chooser)
    if parkedChoosers.count > Self.parkedChooserLimit { parkedChoosers.removeFirst(parkedChoosers.count - Self.parkedChooserLimit) }
  }

  public mutating func drain() -> [PanePermissionRequest] {
    let pending = orphans
    self = PaneBrowsers()
    return pending
  }

  public mutating func parkedChooser(_ browserId: Int) -> PaneDeviceChooser? {
    guard let index = parkedChoosers.firstIndex(where: { $0.browserId == browserId }) else { return nil }
    return parkedChoosers.remove(at: index)
  }

  public mutating func ready(_ tabId: String, browserId: Int) -> [(tabId: String, request: PanePermissionRequest)] {
    tabs = tabs.filter { $0.value != tabId }
    tabs[browserId] = tabId
    let mapped = orphans.compactMap { request in tabs[request.browserId].map { (tabId: $0, request: request) } }
    orphans.removeAll { tabs[$0.browserId] != nil }
    return mapped
  }

  public mutating func route(_ request: PanePermissionRequest) -> String? {
    if let tabId = tabs[request.browserId] { return tabId }
    orphans.append(request)
    return nil
  }

  public mutating func dismissed(_ id: String) { orphans.removeAll { $0.id == id } }

  public mutating func gone(_ tabId: String) { tabs = tabs.filter { $0.value != tabId } }
}

extension PanePromptPage {
  public var permission: PanePermissionRequest? { permissions.first }

  public mutating func enqueue(_ request: PanePermissionRequest) {
    guard !permissions.contains(where: { $0.id == request.id }) else { return }
    permissions.append(request)
  }

  public mutating func dropPermission(_ id: String) -> Bool {
    let before = permissions.count
    permissions.removeAll { $0.id == id }
    return permissions.count != before
  }

  public mutating func chooserEvent(_ next: PaneDeviceChooser) -> Bool {
    let before = self
    if next.open {
      if chooser?.id != next.id {
        chooserSelected = nil
        chooserAnswered = false
      }
      chooser = next
    } else if chooser?.id == next.id {
      chooser = nil
      chooserSelected = nil
      chooserAnswered = false
    }
    return self != before
  }

  public mutating func answerChooser() -> Bool {
    guard chooser != nil, !chooserAnswered else { return false }
    chooserAnswered = true
    return true
  }
}

extension PanePromptSpecs {
  public static let permissionWidth: Double = 300
  public static let deviceChooserWidth: Double = 340

  public static func promptLeft(urlLeft: Double, paneWidth: Double, width: Double) -> Double {
    max(margin, min(urlLeft, paneWidth - width - margin))
  }

  public static func originForSecurityDisplay(_ origin: String) -> String {
    guard let url = URL(string: origin), let scheme = url.scheme, let host = url.host, !host.isEmpty else { return origin }
    let authority = url.port.map { "\(host):\($0)" } ?? host
    return scheme == "https" ? authority : "\(scheme)://\(authority)"
  }

  private struct PermissionKind: Sendable {
    let icon: String
    var noun: String?
    var question: (@Sendable (String) -> String)?
  }

  private static let permissionKinds: [String: PermissionKind] = [
    "camera": PermissionKind(icon: "video", noun: "camera"),
    "microphone": PermissionKind(icon: "mic", noun: "microphone"),
    "cameraPanTiltZoom": PermissionKind(icon: "video", noun: "camera's pan, tilt and zoom"),
    "screen": PermissionKind(icon: "rectangle.on.rectangle", question: { "Allow \($0) to share your screen?" }),
    "location": PermissionKind(icon: "location", noun: "location"),
    "notifications": PermissionKind(icon: "bell", question: { "Allow \($0) to send you notifications?" }),
    "clipboard": PermissionKind(icon: "doc.on.clipboard", noun: "clipboard"),
    "midi": PermissionKind(icon: "pianokeys", noun: "MIDI devices"),
    "multipleDownloads": PermissionKind(icon: "arrow.down.circle", question: { "Allow \($0) to download multiple files?" }),
    "localFonts": PermissionKind(icon: "textformat", noun: "fonts"),
    "idleDetection": PermissionKind(icon: "person.crop.circle.badge.clock", question: { "Allow \($0) to know when you're actively using this device?" }),
    "storageAccess": PermissionKind(icon: "externaldrive", question: { "Allow \($0) to use cookies and site data while embedded?" }),
    "diskQuota": PermissionKind(icon: "internaldrive", question: { "Allow \($0) to store files on your device?" }),
    "windowManagement": PermissionKind(icon: "macwindow.on.rectangle", noun: "displays to open and place windows"),
    "fileSystem": PermissionKind(icon: "folder", noun: "files"),
    "keyboardLock": PermissionKind(icon: "keyboard", noun: "keyboard"),
    "pointerLock": PermissionKind(icon: "cursorarrow", noun: "mouse pointer"),
    "protectedMedia": PermissionKind(icon: "lock.shield", question: { "Allow \($0) to play protected content?" }),
    "protocolHandler": PermissionKind(icon: "envelope", question: { "Make \($0) your default mail app?" }),
    "sensors": PermissionKind(icon: "gyroscope", noun: "motion sensors"),
    "localNetwork": PermissionKind(icon: "network", noun: "devices on your local network"),
    "vr": PermissionKind(icon: "visionpro", noun: "virtual reality devices"),
    "ar": PermissionKind(icon: "visionpro", noun: "augmented reality data"),
    "handTracking": PermissionKind(icon: "hand.raised", noun: "hand tracking"),
    "identityProvider": PermissionKind(icon: "person.badge.key", question: { "Allow \($0) to sign you in with an identity provider?" }),
    "webAppInstallation": PermissionKind(icon: "app.badge", question: { "Allow \($0) to install web apps?" }),
    "capturedSurfaceControl": PermissionKind(icon: "rectangle.on.rectangle", question: { "Allow \($0) to scroll and zoom the tab you share?" }),
  ]

  private static func list(_ words: [String]) -> String {
    words.count < 2 ? (words.first ?? "") : "\(words.dropLast().joined(separator: ", ")) and \(words.last!)"
  }

  public static func describePermission(_ request: PanePermissionRequest) -> (icons: [String], question: String) {
    let site = originForSecurityDisplay(request.origin)
    let kinds = request.permissions.map { permissionKinds[$0] ?? PermissionKind(icon: "questionmark.circle", noun: $0) }
    var icons: [String] = []
    for kind in kinds where !icons.contains(kind.icon) { icons.append(kind.icon) }
    if kinds.count == 1, let question = kinds[0].question { return (icons, question(site)) }
    let nouns = kinds.compactMap(\.noun)
    if nouns.count == kinds.count { return (icons, "Allow \(site) to access your \(list(nouns))?") }
    return (icons, "Allow \(site) to use \(list(request.permissions.map { permissionKinds[$0]?.noun ?? $0 }))?")
  }

  public static func permission(_ request: PanePermissionRequest, left: Double) -> [String: Any] {
    let described = describePermission(request)
    return [
      "popover": ["width": permissionWidth, "top": margin, "left": left, "modal": false],
      "icons": described.icons,
      "title": described.question,
      "inputProtectionKey": request.id,
      "message": "Click the lock to change this any time",
      "details": [] as [Any],
      "buttons": [["id": "deny", "title": "Don't Allow"], ["id": "accept", "title": "Allow", "primary": true]],
      "close": true,
    ]
  }

  public static func deviceChooser(_ chooser: PaneDeviceChooser, selected: Int?, product: String, left: Double) -> [String: Any] {
    let scanning = chooser.scanning
    return [
      "popover": ["width": deviceChooserWidth, "top": margin, "left": left, "modal": false],
      "id": chooser.id,
      "title": chooser.title,
      "icon": chooser.showSignal || scanning ? "dot.radiowaves.left.and.right" : "cable.connector",
      "options": chooser.options.map { option -> [String: Any] in
        ["name": option.name, "detail": option.connected ? "Connected" : option.paired ? "Paired" : NSNull() as Any, "signal": chooser.showSignal ? option.signal : -1]
      },
      "selected": selected ?? NSNull(),
      "scanning": scanning,
      "refreshing": chooser.refreshing,
      "canRefresh": chooser.canRefresh,
      "scanningText": chooser.scanningText,
      "noOptionsText": chooser.noOptionsText,
      "unauthorized": chooser.unauthorized,
      "adapterOff": chooser.adapterOff,
      "notice": chooser.unauthorized ? "\(product) needs access to Bluetooth to find devices." : chooser.adapterOff ? "Bluetooth is turned off. Turn it on to find devices." : NSNull() as Any,
      "noticeIcon": chooser.unauthorized ? "lock" : chooser.adapterOff ? "antenna.radiowaves.left.and.right.slash" : NSNull() as Any,
      "noticeLink": chooser.unauthorized ? "Open Bluetooth Settings" : NSNull() as Any,
      "cancelLabel": chooser.cancelLabel.isEmpty ? "Cancel" : chooser.cancelLabel,
      "okLabel": chooser.okLabel.isEmpty ? "Connect" : chooser.okLabel,
      "valid": chooser.valid(selected),
    ]
  }
}

public struct PaneSelection: Equatable, Sendable {
  public var text: String
  public var x: Double
  public var y: Double
  public var width: Double
  public var height: Double

  public init?(_ data: Any?) {
    guard let data = data as? [String: Any], let text = data["text"] as? String, let rect = data["rect"] as? [String: Any] else { return nil }
    func number(_ key: String) -> Double { (rect[key] as? NSNumber)?.doubleValue ?? 0 }
    self.text = text
    x = number("x")
    y = number("y")
    width = number("width")
    height = number("height")
  }
}

extension PanePromptSpecs {
  public static let selectionDelay: TimeInterval = 0.15

  public static func searchTooltip(engine: String, text: String) -> String {
    let units = Array(text.utf16)
    let cut = units.count > 40 ? (String(utf16CodeUnits: Array(units.prefix(40)), count: 40).replacingOccurrences(of: "\\s+$", with: "", options: .regularExpression) + "\u{2026}") : text
    return "Search \(engine) for \u{201C}\(cut.replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression))\u{201D}"
  }

  public static func selectionBar(_ selection: PaneSelection, zoom: Double, engine: String, dark: Bool, icon: String, textPrimary: String) -> SelectionBarState {
    SelectionBarState(
      key: "\(Self.number(selection.x)),\(Self.number(selection.y))",
      top: selection.y * zoom,
      bottom: (selection.y + selection.height) * zoom,
      center: (selection.x + selection.width / 2) * zoom,
      dark: dark,
      icon: icon,
      textPrimary: textPrimary,
      tooltip: searchTooltip(engine: engine, text: selection.text),
      label: "Search \(engine)"
    )
  }

  static func number(_ value: Double) -> String {
    value == value.rounded() && abs(value) < 1e15 ? String(Int(value)) : String(value)
  }
}

extension PanePromptSpecs {
  public static let engineOfferWidth: Double = 320

  public static func engineOffer(host: String, canRemember: Bool, remember: Bool, product: String, left: Double) -> [String: Any] {
    [
      "popover": ["width": engineOfferWidth, "top": margin, "left": left, "modal": false],
      "icons": ["play.circle.fill", "safari"],
      "title": "Play \(host) in WebKit?",
      "message": "This site plays protected video, which Chromium in \(product) can't. The page reloads in WebKit, which keeps its own sign-ins.",
      "details": canRemember ? [["kind": "checkbox", "label": "Don't ask again for this site", "value": remember] as [String: Any]] : [],
      "buttons": [["id": "stay", "title": "Stay on Page"], ["id": "webkit", "title": "Open in WebKit", "primary": true]],
      "close": true,
    ]
  }
}
