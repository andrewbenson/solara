import AppKit

enum AppIcons {
  struct Variant {
    let id: String
    let name: String
    var artwork: String? = nil
  }

  static let defaultsKey = "ACAppIcon"
  static func changedNotification(bundleId: String) -> Notification.Name { .init("\(bundleId).AppIconChanged") }

  static let fallbackIconName = "AppIcon"

  static func bundleIconName(_ bundle: Bundle) -> String {
    (bundle.object(forInfoDictionaryKey: "CFBundleIconName") as? String).flatMap { $0.isEmpty ? nil : $0 } ?? fallbackIconName
  }

  static var iconName: String = bundleIconName(.main) {
    didSet { cache.removeAll() }
  }

  static let solaraIconName = "SolaraIcon"

  static var variants: [Variant] {
    iconName == solaraIconName ? solaraVariants : [Variant(id: "default", name: "Default")]
  }

  private static let solaraVariants: [Variant] = [
    Variant(id: "default", name: "Classic"),
    Variant(id: "calm", name: "Calm", artwork: "SolaraCalm"),
  ]

  private static var chosenThisSession: String?

  static var current: String {
    let id = chosenThisSession ?? UserDefaults.standard.string(forKey: defaultsKey) ?? "default"
    return variants.contains { $0.id == id } ? id : "default"
  }

  static func restore() {
    if current != "default" { apply(current) }
  }

  static func set(_ id: String, shared: Bool) {
    guard variants.contains(where: { $0.id == id }) else { return }
    chosenThisSession = id
    apply(id)
    guard shared else { return }
    UserDefaults.standard.set(id, forKey: defaultsKey)
    if let bundleId = Bundle.main.bundleIdentifier {
      DistributedNotificationCenter.default().postNotificationName(
        changedNotification(bundleId: bundleId), object: nil, userInfo: ["icon": id], deliverImmediately: true)
    }
  }

  private static func apply(_ id: String) {
    NSApp.applicationIconImage = id == "default" ? nil : image(id, size: 512)
  }

  private static var cache: [String: NSImage] = [:]

  static var base: NSImage = NSImage(named: iconName) ?? NSWorkspace.shared.icon(forFile: Bundle.main.bundlePath) {
    didSet { cache.removeAll() }
  }

  static var markNamed: (String) -> NSImage? = { NSImage(named: $0) } {
    didSet { cache.removeAll() }
  }

  static func image(_ id: String, size: CGFloat) -> NSImage? {
    let key = "\(id)@\(size)"
    if let hit = cache[key] { return hit }
    guard let variant = variants.first(where: { $0.id == id }) else { return nil }
    let artwork = variant.artwork.flatMap(markNamed) ?? base
    let image = NSImage(size: NSSize(width: size, height: size), flipped: false) { rect in
      artwork.draw(in: rect)
      return true
    }
    cache[key] = image
    return image
  }

  static func preview(_ id: String, size: CGFloat) -> String? {
    image(id, size: size * 2).flatMap(dataURL)
  }

  static func dataURL(_ image: NSImage) -> String? {
    guard let tiff = image.tiffRepresentation,
          let png = NSBitmapImageRep(data: tiff)?.representation(using: .png, properties: [:]) else { return nil }
    return "data:image/png;base64,\(png.base64EncodedString())"
  }
}

enum DockTile {
  private static let domain = "com.apple.dock" as CFString
  private static let key = "persistent-apps" as CFString
  private static var tiles: [[String: Any]] {
    CFPreferencesCopyAppValue(key, domain) as? [[String: Any]] ?? []
  }

  static var isInDock: Bool { tiles.contains(where: isOurs) }

  private static var label: String {
    Bundle.main.object(forInfoDictionaryKey: "CFBundleName") as? String ?? ProcessInfo.processInfo.processName
  }

  private static func isOurs(_ tile: [String: Any]) -> Bool {
    let data = tile["tile-data"] as? [String: Any]
    if let id = data?["bundle-identifier"] as? String, id == Bundle.main.bundleIdentifier { return true }
    let file = (data?["file-data"] as? [String: Any])?["_CFURLString"] as? String
    return file.flatMap(URL.init(string:))?.standardizedFileURL.path == Bundle.main.bundleURL.standardizedFileURL.path
  }

  private static func restartDock() {
    let restart = Process()
    restart.executableURL = URL(fileURLWithPath: "/usr/bin/killall")
    restart.arguments = ["Dock"]
    try? restart.run()
  }

  static func relabel() {
    let env = ProcessInfo.processInfo.environment
    guard env["SOLARA_BACKGROUND"] == nil, env["SOLARA_DATA_DIR"] == nil else { return }
    var changed = false
    let updated: [[String: Any]] = tiles.map { tile in
      guard isOurs(tile), var data = tile["tile-data"] as? [String: Any], data["file-label"] as? String != label else { return tile }
      data["file-label"] = label
      changed = true
      var copy = tile
      copy["tile-data"] = data
      return copy
    }
    guard changed else { return }
    CFPreferencesSetAppValue(key, updated as CFArray, domain)
    guard CFPreferencesAppSynchronize(domain) else { return }
    restartDock()
  }

  @discardableResult
  static func add(isolated: Bool) -> Bool {
    guard !isInDock else { return true }
    if isolated {
      NSLog("SolaraSystem: isolated instance, not adding to the Dock")
      return false
    }
    let tile: [String: Any] = [
      "tile-type": "file-tile",
      "tile-data": [
        "bundle-identifier": Bundle.main.bundleIdentifier ?? "",
        "file-label": label,
        "file-type": 41,
        "file-data": ["_CFURLString": Bundle.main.bundleURL.absoluteString, "_CFURLStringType": 15],
      ] as [String: Any],
    ]
    CFPreferencesSetAppValue(key, (tiles + [tile]) as CFArray, domain)
    guard CFPreferencesAppSynchronize(domain) else { return false }
    restartDock()
    return true
  }
}
