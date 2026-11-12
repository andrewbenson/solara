import AppKit
import Foundation
import SolaraModel

public enum TabUnreadStatus: Hashable, Sendable {
  case count(Int)
  case dot

  public var accessibilityLabel: String {
    switch self {
    case .count(let value): "\(value > 99 ? "99+" : String(value)) unread"
    case .dot: "Unread activity"
    }
  }
}

enum UnreadAPIValue: Equatable, Sendable {
  case unset
  case clear
  case count(Int)
  case dot

  static func decode(_ payload: [String: Any]) -> Self? {
    switch payload["kind"] as? String {
    case "unset": return .unset
    case "clear": return .clear
    case "dot": return .dot
    case "count":
      guard let text = payload["count"] as? String, !text.isEmpty, text.count <= 20,
        text.utf8.allSatisfy({ (48...57).contains($0) }), let value = UInt64(text) else { return nil }
      return value == 0 ? .clear : .count(Int(min(100, value)))
    default: return nil
    }
  }
}

enum UnreadSignal {
  static func resolve(api: UnreadAPIValue, title: Int?, favicon: Bool) -> TabUnreadStatus? {
    switch api {
    case .clear: return nil
    case .count(let count): return .count(count)
    case .dot: return .dot
    case .unset: return title.map(TabUnreadStatus.count) ?? (favicon ? .dot : nil)
    }
  }
}

@MainActor
final class UnreadBadgeFeed {
  private struct Entry {
    var document: String
    var api: UnreadAPIValue = .unset
    var favicon = false
    var ticket = UUID()
    var retired = false
  }

  private var entries: [String: Entry] = [:]
  private var titles: [String: (String, Int?)] = [:]

  func status(key: String, title: String) -> TabUnreadStatus? {
    if entries[key]?.retired == true { return nil }
    if titles[key]?.0 != title { titles[key] = (title, UnreadTitleParser.count(in: title)) }
    return UnreadSignal.resolve(api: entries[key]?.api ?? .unset, title: titles[key]?.1, favicon: entries[key]?.favicon ?? false)
  }

  func receive(key: String, document: String, kind: String, payload: [String: Any]) {
    if kind == "reset" {
      entries[key] = Entry(document: document)
      titles[key] = nil
      return
    }
    guard entries[key]?.document == document else { return }
    if kind == "closed" {
      entries[key] = Entry(document: document, retired: true)
      titles[key] = nil
    } else if kind == "badge", let value = UnreadAPIValue.decode(payload) {
      entries[key]?.api = value
    }
  }

  func accepts(key: String, document: String) -> Bool {
    entries[key]?.document == document && entries[key]?.retired == false
  }

  func reserveFavicon(key: String, document: String) -> UUID {
    let ticket = UUID()
    if entries[key]?.document == document, entries[key]?.retired == false { entries[key]?.ticket = ticket }
    return ticket
  }

  @discardableResult
  func finishFavicon(key: String, document: String, ticket: UUID, hasDot: Bool) -> Bool {
    guard entries[key]?.document == document, entries[key]?.ticket == ticket, entries[key]?.retired == false else { return false }
    let changed = entries[key]?.favicon != hasDot
    entries[key]?.favicon = hasDot
    return changed
  }

  func remove(_ tabIds: Set<String>) {
    for key in tabIds {
      entries[key] = nil
      titles[key] = nil
    }
  }

  func retain(_ tabIds: Set<String>) {
    entries = entries.filter { tabIds.contains($0.key) }
    titles = titles.filter { tabIds.contains($0.key) }
  }
}

@MainActor
public enum UnreadBadges {
  public static let changed = Notification.Name("SolaraUnreadBadgesChanged")
  private static let received = Notification.Name("SolaraTabUnreadSignal")
  private static var feed = UnreadBadgeFeed()
  private static var analyzer = UnreadFaviconAnalyzer()
  private static var observers: [NSObjectProtocol] = []
  private static var enabled = true
  private static var epoch = UUID()
  private static var publishQueued = false
  private static var retiredProfiles: Set<String> = []
  private static var profiles: [String: String] = [:]
  private static var tasks: [String: Task<Void, Never>] = [:]
  private static var images: [String: (document: String, source: String, image: UnreadFaviconImage)] = [:]

  public static func start() {
    guard observers.isEmpty else { return }
    observers.append(NotificationCenter.default.addObserver(forName: received, object: nil, queue: .main) { notification in
      nonisolated(unsafe) let userInfo = notification.userInfo
      MainActor.assumeIsolated {
        guard let info = userInfo, let key = info["key"] as? String,
          let document = info["document"] as? String, let kind = info["event"] as? String else { return }
        receive(key: key, document: document, kind: kind, info: info)
      }
    })
    observers.append(NotificationCenter.default.addObserver(forName: Notification.Name("SolaraPrivateSessionEnded"), object: nil, queue: .main) { notification in
      let aliases = Set(notification.userInfo?["aliases"] as? [String] ?? [])
      MainActor.assumeIsolated {
        retiredProfiles.formUnion(aliases)
        let keys = Set(profiles.compactMap { aliases.contains($0.value) ? $0.key : nil })
        epoch = UUID()
        for task in tasks.values { task.cancel() }
        tasks.removeAll()
        feed.remove(keys)
        for key in keys { images[key] = nil; profiles[key] = nil }
        analyzer = UnreadFaviconAnalyzer()
        if enabled {
          for (key, image) in images { analyze(key: key, document: image.document, source: image.source, image: image.image) }
        }
        publish()
      }
    })
  }

  public static func status(tab: Tab) -> TabUnreadStatus? {
    guard enabled, tab.unloaded != true else { return nil }
    return feed.status(key: tab.id, title: tab.title)
  }

#if DEBUG || SOLARA_PROBES
  public static func diagnostics() async -> [String: Int] {
    await analyzer.diagnostics()
  }
#endif

  public static func retain(tabIds: Set<String>) {
    feed.retain(tabIds)
    images = images.filter { tabIds.contains($0.key) }
    profiles = profiles.filter { tabIds.contains($0.key) }
    for key in tasks.keys where !tabIds.contains(key) { tasks.removeValue(forKey: key)?.cancel() }
  }

  public static func setEnabled(_ on: Bool) {
    guard enabled != on else { return }
    enabled = on
    epoch = UUID()
    for task in tasks.values { task.cancel() }
    tasks.removeAll()
    if on {
      for (key, image) in images { analyze(key: key, document: image.document, source: image.source, image: image.image) }
    }
    publish()
  }

  private static func receive(key: String, document: String, kind: String, info: [AnyHashable: Any]) {
    if let profile = info["profile"] as? String {
      guard !retiredProfiles.contains(profile) else { return }
      profiles[key] = profile
    }
    guard kind == "reset" || feed.accepts(key: key, document: document) else { return }
    if kind == "reset" || kind == "closed" {
      images[key] = nil
      tasks.removeValue(forKey: key)?.cancel()
    }
    feed.receive(key: key, document: document, kind: kind, payload: info["badge"] as? [String: Any] ?? [:])
    if kind == "favicon", let raw = info["image"], CFGetTypeID(raw as CFTypeRef) == CGImage.typeID {
      let snapshot = UnreadFaviconImage(image: raw as! CGImage)
      let source = info["source"] as? String ?? ""
      images[key] = (document, source, snapshot)
      if enabled { analyze(key: key, document: document, source: source, image: snapshot) }
    } else {
      publish()
    }
  }

  private static func analyze(key: String, document: String, source: String, image: UnreadFaviconImage) {
    let ticket = feed.reserveFavicon(key: key, document: document)
    let generation = epoch
    let analyzer = analyzer
    tasks[key]?.cancel()
    tasks[key] = Task {
      let found = await analyzer.hasDot(source: source, image: image)
      guard !Task.isCancelled, enabled, generation == epoch else { return }
      if feed.finishFavicon(key: key, document: document, ticket: ticket, hasDot: found) { publish() }
    }
  }

  private static func publish() {
    guard !publishQueued else { return }
    publishQueued = true
    Task { @MainActor in
      publishQueued = false
      NotificationCenter.default.post(name: changed, object: nil)
    }
  }
}
