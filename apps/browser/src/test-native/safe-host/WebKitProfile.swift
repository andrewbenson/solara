import Foundation
import CryptoKit

enum SolaraCoreHost {
  static var safeMode = false
}

final class WKWebsiteDataStore {
  static var stores: [UUID: WKWebsiteDataStore] = [:]
  static var unknownLayout = false
  let identifier: UUID?
  var cleared = false

  init(forIdentifier identifier: UUID) {
    self.identifier = identifier
    Self.stores[identifier] = self
    if !Self.unknownLayout { try! FileManager.default.createDirectory(at: WebKitHub.directory(identifier), withIntermediateDirectories: true) }
  }

  private init() { identifier = nil }

  static func nonPersistent() -> WKWebsiteDataStore { WKWebsiteDataStore() }
  static func allWebsiteDataTypes() -> Set<String> { ["cookies", "history"] }

  func removeData(ofTypes: Set<String>, modifiedSince: Date, completionHandler: () -> Void) {
    cleared = true
    completionHandler()
  }
}

struct Configuration {
  let websiteDataStore: WKWebsiteDataStore
}

struct Frame { static let zero = Frame() }

final class WKWebView {
  let configuration: Configuration
  var closed = false
  init(frame: Frame, configuration: Configuration) { self.configuration = configuration }
}

enum WebKitStoreRemovals {
  static var removalCalls = 0
  static func exists(_ identifier: UUID, done: (Bool) -> Void) { done(WKWebsiteDataStore.stores[identifier] != nil) }
  static func remove(_ identifier: UUID, tries: Int, deletionAllowed: () -> Bool, done: (Bool) -> Void) {
    guard deletionAllowed() else { return done(false) }
    removalCalls += 1
    WKWebsiteDataStore.stores.removeValue(forKey: identifier)
    if FileManager.default.fileExists(atPath: WebKitHub.directory(identifier).path) { try! FileManager.default.removeItem(at: WebKitHub.directory(identifier)) }
    done(true)
  }
}

func alwaysAllowDeletion() -> Bool { true }

__PRODUCTION__

extension WebKitHub {
  static func directory(_ identifier: UUID) -> URL { URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent(identifier.uuidString) }
  static func profileDirectories(_ profile: String) -> [URL] { [directory(storeIdentifier(profile))] }
  struct PrivateSession { let store: WKWebsiteDataStore }
  func session(_ name: String) -> PrivateSession { PrivateSession(store: .nonPersistent()) }
  func configuration(profile: String) -> Configuration { Configuration(websiteDataStore: dataStore(for: profile)) }
  func storeKey(_ profile: String) -> String { profile }
  static func close(_ host: WKWebView) { host.closed = true }
  func closeViews(using store: WKWebsiteDataStore) {
    for host in resumeHosts.values where host.configuration.websiteDataStore === store { Self.close(host) }
  }
  func seedMetadata(_ live: String, _ deleting: String) {
    rememberedPermissions[live + "|live"] = true
    rememberedPermissions[deleting + "|deleting"] = true
    zoomByHost[live + "|live"] = 2
    zoomByHost[deleting + "|deleting"] = 2
    externalAllowances[live + "|live"] = true
    externalAllowances[deleting + "|deleting"] = true
  }
  func metadataKept(_ live: String, _ deleting: String) -> Bool {
    rememberedPermissions[live + "|live"] == true && zoomByHost[live + "|live"] == 2 && externalAllowances[live + "|live"] == true
      && rememberedPermissions[deleting + "|deleting"] == nil && zoomByHost[deleting + "|deleting"] == nil && externalAllowances[deleting + "|deleting"] == nil
  }
}

extension WebKitDownloads {
  enum Phase { case running, done }
  struct Item { let id: String; let profile: String; var phase: Phase = .running }
  func command(_ action: String, id: String) { items[id]?.phase = .done }
  func seed(_ live: String, _ deleting: String) { items = ["live": Item(id: "live", profile: live), "deleting": Item(id: "deleting", profile: deleting)] }
  var matchingOnlyCancelled: Bool { items["live"]?.phase == .running && items["deleting"]?.phase == .done }
}

var results: [[String: Any]] = []
for cached in [false, true] {
for (liveID, deletingID) in [("café", "cafe\u{301}"), ("FOO", "foo"), ("kept", "named"), ("kept", "")] {
  WKWebsiteDataStore.stores = [:]
  let hub = WebKitHub()
  let live = hub.dataStore(for: liveID)
  let liveHost = hub.resumeHost(for: liveID)
  let deleting = cached ? hub.dataStore(for: deletingID) : WKWebsiteDataStore(forIdentifier: WebKitHub.storeIdentifier(deletingID))
  let deletingHost = cached ? hub.resumeHost(for: deletingID) : nil
  hub.seedMetadata(liveID, deletingID)
  hub.downloads.seed(liveID, deletingID)
  var completion: Bool?
  hub.deleteProfileData(deletingID) { completion = $0 }
  let deadline = Date(timeIntervalSinceNow: 2)
  while completion == nil && Date() < deadline { RunLoop.current.run(until: Date(timeIntervalSinceNow: 0.005)) }
  let liveStillBound = hub.dataStore(for: liveID) === live
  results.append([
    "live": liveID, "deleting": deletingID, "cached": cached, "completed": completion == true,
    "liveKept": !live.cleared && !liveHost.closed && liveStillBound && WKWebsiteDataStore.stores[live.identifier!] === live,
    "deleted": WKWebsiteDataStore.stores[deleting.identifier!] == nil && (!cached || (deleting.cleared && deletingHost?.closed == true)),
    "downloadsExact": hub.downloads.matchingOnlyCancelled,
    "metadataExact": hub.metadataKept(liveID, deletingID),
  ])
}
}
for deferred in [false, true] {
  WKWebsiteDataStore.stores = [:]
  let hub = WebKitHub()
  let deleting = hub.dataStore(for: "guarded")
  var allowed = deferred
  var completion: Bool?
  hub.deleteProfileData("guarded", deletionAllowed: { allowed }) { completion = $0 }
  allowed = false
  let deadline = Date(timeIntervalSinceNow: 2)
  while completion == nil && Date() < deadline { RunLoop.current.run(until: Date(timeIntervalSinceNow: 0.005)) }
  results.append(["refused": completion == false, "storeKept": WKWebsiteDataStore.stores[deleting.identifier!] === deleting, "initialClearRefused": deferred || !deleting.cleared])
}
for cached in [false, true] {
  WKWebsiteDataStore.stores = [:]
  WKWebsiteDataStore.unknownLayout = true
  WebKitStoreRemovals.removalCalls = 0
  let hub = WebKitHub()
  let profile = "unknown-\(cached)"
  let store = cached ? hub.dataStore(for: profile) : WKWebsiteDataStore(forIdentifier: WebKitHub.storeIdentifier(profile))
  var completion: Bool?
  hub.deleteProfileData(profile) { completion = $0 }
  let deadline = Date(timeIntervalSinceNow: 2)
  while completion == nil && Date() < deadline { RunLoop.current.run(until: Date(timeIntervalSinceNow: 0.005)) }
  results.append([
    "unknownLayoutRefused": completion == false,
    "storeKept": WKWebsiteDataStore.stores[store.identifier!] === store,
    "dataKept": !store.cleared,
    "removalNotCalled": WebKitStoreRemovals.removalCalls == 0,
  ])
}
let output = try JSONSerialization.data(withJSONObject: results)
print(String(data: output, encoding: .utf8)!)
