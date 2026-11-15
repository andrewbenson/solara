#if SOLARA_PROBES
import AppKit

@MainActor
public enum NativeWorkCounters {
  private struct Scope: Hashable {
    let windowId: String
    let profileId: String
    let kind: String
  }

  private struct Counts {
    var created = 0
    var bound = 0
    var reused = 0
    var live = 0

    var value: [String: Int] { ["created": created, "bound": bound, "reused": reused, "live": live] }
  }

  private final class Row {
    weak var view: NSView?
    var scope: Scope
    init(_ view: NSView, _ scope: Scope) { self.view = view; self.scope = scope }
  }

  @MainActor
  private final class Host {
    weak var owner: AnyObject?
    let windowId: String
    let kind: String
    let read: @MainActor () -> (active: Bool, subscriptions: Int)

    init<Owner: AnyObject>(_ owner: Owner, windowId: String, kind: String, read: @escaping @MainActor (Owner) -> (Bool, Int)) {
      self.owner = owner
      self.windowId = windowId
      self.kind = kind
      self.read = { [weak owner] in
        guard let owner else { return (false, 0) }
        return read(owner)
      }
    }
  }

  private final class Link {
    weak var value: CADisplayLink?
    init(_ value: CADisplayLink) { self.value = value }
  }

  private static var rows: [ObjectIdentifier: Row] = [:]
  private static var counts: [Scope: Counts] = [:]
  private static var hosts: [ObjectIdentifier: Host] = [:]
  private static var links: [ObjectIdentifier: Link] = [:]
  public static var layoutApplications = 0
  public static var slotPublishes = 0
  public static var deferredJobs = 0
  public static var shellStoreSubscriptions = 0
  public static var launchWorkRead: (() -> [String: Any])?

  public static func bind(_ view: NSView, windowId: String, profileId: String, kind: String) {
    let scope = Scope(windowId: windowId, profileId: profileId, kind: kind)
    let id = ObjectIdentifier(view)
    let reused = rows[id]?.view === view
    counts[scope, default: Counts()].bound += 1
    if reused { counts[scope, default: Counts()].reused += 1 } else { counts[scope, default: Counts()].created += 1 }
    if reused { rows[id]?.scope = scope } else { rows[id] = Row(view, scope) }
  }

  static func bindSidebar(_ view: NSView, _ item: SidebarItem, _ context: SidebarContext) {
    let name: String = switch item.kind {
    case .tab: "tab"
    case .tile: "tile"
    case .folder: "folder"
    case .split: "split"
    case .groupHeader: "groupHeader"
    case .groupBox: "groupBox"
    case .newTab: "newTab"
    case .divider: "divider"
    case .incognito: "incognito"
    case .upsell: "upsell"
    case .live: String(describing: type(of: view))
    }
    let mode = String(describing: type(of: view)).hasPrefix("Rail") ? "rail" : "full"
    bind(view, windowId: context.windowId, profileId: context.host.profileId, kind: "sidebar.\(name).\(mode)")
  }

  public static func host<Owner: AnyObject>(_ owner: Owner, windowId: String, kind: String, read: @escaping @MainActor (Owner) -> (Bool, Int)) {
    hosts[ObjectIdentifier(owner)] = Host(owner, windowId: windowId, kind: kind, read: read)
  }

  public static func link(_ value: CADisplayLink) { links[ObjectIdentifier(value)] = Link(value) }

  public static func unlink(_ value: CADisplayLink?) {
    if let value { links[ObjectIdentifier(value)] = nil }
  }

  public static func reset() {
    counts = [:]
    rows = rows.filter { $0.value.view != nil }
    hosts = hosts.filter { $0.value.owner != nil }
    links = links.filter { $0.value.value != nil }
    layoutApplications = 0
    slotPublishes = 0
    deferredJobs = 0
  }

  public static func snapshot() -> [String: Any] {
    rows = rows.filter { $0.value.view != nil }
    hosts = hosts.filter { $0.value.owner != nil }
    links = links.filter { $0.value.value != nil }
    var grouped = counts
    for row in rows.values { grouped[row.scope, default: Counts()].live += 1 }
    let total = grouped.values.reduce(into: Counts()) { total, next in
      total.created += next.created; total.bound += next.bound; total.reused += next.reused; total.live += next.live
    }
    let groups = grouped.map { scope, count -> [String: Any] in
      var value: [String: Any] = count.value
      value["windowId"] = scope.windowId; value["profileId"] = scope.profileId; value["kind"] = scope.kind
      return value
    }.sorted { "\($0["windowId"]!)|\($0["profileId"]!)|\($0["kind"]!)" < "\($1["windowId"]!)|\($1["profileId"]!)|\($1["kind"]!)" }
    var subscriptions = shellStoreSubscriptions
    var hostCounts: [Scope: Int] = [:]
    for host in hosts.values {
      let read = host.read()
      subscriptions += read.subscriptions
      if read.active { hostCounts[Scope(windowId: host.windowId, profileId: "", kind: host.kind), default: 0] += 1 }
    }
    let liveHosts = hostCounts.map { ["windowId": $0.key.windowId, "kind": $0.key.kind, "count": $0.value] as [String: Any] }
      .sorted { "\($0["windowId"]!)|\($0["kind"]!)" < "\($1["windowId"]!)|\($1["kind"]!)" }
    return ["version": 1, "rows": total.value, "groups": groups, "hosts": liveHosts,
      "launchWork": launchWorkRead?() ?? [:],
      "layoutApplications": layoutApplications, "slotPublishes": slotPublishes,
      "activeAnimationLinks": links.values.filter { $0.value?.isPaused == false }.count, "liveSubscriptions": subscriptions,
      "deferredJobs": deferredJobs, "pendingDeferredJobs": FrameUpdates.probePendingJobs,
      "scope": ["rows": "sidebar rows including folder guests; strip top-level items", "links": "SolaraUI display links", "subscriptions": "shell/sidebar/strip host notifications and store listeners; tab memory store listener", "deferred": "FrameUpdates closures"]]
  }
}
#endif
