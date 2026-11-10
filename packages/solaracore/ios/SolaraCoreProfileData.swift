import Foundation
import Synchronization

enum SolaraCoreProfileData {
  typealias Done = ([String]) -> Void
  private typealias Step = (label: String, run: (@escaping (Bool) -> Void) -> Void)

  static func delete(_ profile: String, deletionAllowed: @escaping () -> Bool = { true }, _ done: @escaping Done) {
    ChromiumProfileData.delete(profile, profilesDirectory: URL(fileURLWithPath: SolaraCoreHost.dataDirectory, isDirectory: true), deleteDefault: { deleteDefault(deletionAllowed: deletionAllowed, $0) }, deleteNamed: { profile, complete in
      SolaraCoreHost.deleteProfileData(profile, deletionAllowed: deletionAllowed, completion: complete)
    }, completion: done)
  }

  static func deleteDefault(deletionAllowed: @escaping () -> Bool = { true }, _ done: @escaping Done) {
    guard !SolaraCoreHost.safeMode else { return done(["safe mode"]) }
    let steps: [Step] = [
      ("extensions", { ok in clearEach(deletionAllowed: deletionAllowed, list: runningExtensions, key: "extensions", done: ok) {
        item, next in SolaraCoreServices.setExtension(item["id"] as? String ?? "", enabled: false, profile: "") { _ in next() }
      } }),
      ("bookmarks", { deleteBookmarks(deletionAllowed: deletionAllowed, $0) }),
      ("history, cookies and cache", { ok in
        SolaraCoreServices.clearBrowsingData(profile: "", types: ["history", "siteData", "cache", "downloads"], since: 0) { ok(true) }
      }),
      ("autocomplete entries", { ok in
        SolaraCoreServices.call("ac_browsing_data_clear", profile: "", args: ["types": ["formData", "siteSettings"]]) { ok($0["ok"] as? Bool == true) }
      }),
      ("passwords", { deletePasswords(deletionAllowed: deletionAllowed, $0) }),
      ("addresses", { ok in clearEach(deletionAllowed: deletionAllowed, list: { SolaraCoreServices.addresses(profile: "", completion: $0) }, key: "addresses", done: ok) {
        item, next in SolaraCoreServices.deleteAutofillEntry(item["id"] as? String ?? "", profile: "") { _ in next() }
      } }),
      ("cards", { ok in clearEach(deletionAllowed: deletionAllowed, list: { SolaraCoreServices.cards(profile: "", completion: $0) }, key: "cards", done: ok) {
        item, next in SolaraCoreServices.deleteAutofillEntry(item["id"] as? String ?? "", profile: "") { _ in next() }
      } }),
      ("site settings", { resetSiteSettings(deletionAllowed: deletionAllowed, $0) }),
      ("zoom levels", { resetZoom(deletionAllowed: deletionAllowed, $0) }),
      ("bookmarks", { deleteBookmarks(deletionAllowed: deletionAllowed, $0) }),
    ]
    var remaining: [String] = []
    func run(_ i: Int) {
      guard i < steps.count else { return done(remaining) }
      guard deletionAllowed() else { return done(remaining + ["live profile filesystem identity"]) }
      steps[i].run { ok in
        if !ok { remaining.append(steps[i].label) }
        if !ok && steps[i].label == "extensions" { return done(remaining) }
        run(i + 1)
      }
    }
    run(0)
  }

  private static func deleteBookmarks(deletionAllowed: @escaping () -> Bool, _ ok: @escaping (Bool) -> Void) {
    guard deletionAllowed() else { return ok(false) }
    SolaraCoreServices.call("ac_bookmarks_clear", profile: "", args: nil) { result in
      ok(deletionAllowed() && result["ok"] as? Bool == true)
    }
  }

  private static func deletePasswords(deletionAllowed: @escaping () -> Bool, _ ok: @escaping (Bool) -> Void) {
    clearEach(deletionAllowed: deletionAllowed, list: { SolaraCoreServices.listPasswords(profile: "", completion: $0) }, key: "passwords", done: { deleted in
      SolaraCoreServices.neverSaveOrigins(profile: "") { result in
        let origins = result["origins"] as? [String] ?? []
        forEach(origins, { origin, next in
          guard deletionAllowed() else { return ok(false) }
          SolaraCoreServices.allowSaving(profile: "", origin: origin) { _ in next() }
        }) {
          SolaraCoreServices.neverSaveOrigins(profile: "") { again in ok(deleted && (again["origins"] as? [String])?.isEmpty == true) }
        }
      }
    }) { item, next in
      SolaraCoreServices.deletePassword(profile: "", origin: item["origin"] as? String ?? "", username: item["username"] as? String ?? "") { _ in next() }
    }
  }

  private static func runningExtensions(_ completion: @escaping ([String: Any]) -> Void) {
    SolaraCoreServices.listExtensions(profile: "") { result in
      guard let all = result["extensions"] as? [[String: Any]] else { return completion(result) }
      completion(["extensions": all.filter { $0["mayModify"] as? Bool != false && $0["enabled"] as? Bool == true }])
    }
  }

  private static func resetSiteSettings(deletionAllowed: @escaping () -> Bool, _ ok: @escaping (Bool) -> Void) {
    SolaraCoreServices.siteSettingsOrigins(profile: "") { origins in
      forEach(origins, { origin, next in
        guard deletionAllowed() else { return ok(false) }
        SolaraCoreServices.call("ac_site_settings_reset", profile: "", args: ["origin": origin]) { _ in next() }
      }) {
        SolaraCoreServices.siteSettingsOrigins(profile: "") { left in ok(left.isEmpty) }
      }
    }
  }

  private static func resetZoom(deletionAllowed: @escaping () -> Bool, _ ok: @escaping (Bool) -> Void) {
    SolaraCoreServices.zoomLevels(profile: "") { levels in
      for host in levels.keys {
        guard deletionAllowed() else { return ok(false) }
        SolaraCoreServices.setZoom(1, profile: "", host: host)
      }
      func check(_ attempt: Int) {
        SolaraCoreServices.zoomLevels(profile: "") { left in
          if left.isEmpty || attempt >= 20 { return ok(left.isEmpty) }
          DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { check(attempt + 1) }
        }
      }
      check(0)
    }
  }

  private static func clearEach(
    deletionAllowed: @escaping () -> Bool, list: @escaping (@escaping ([String: Any]) -> Void) -> Void, key: String, done: @escaping (Bool) -> Void,
    clear: @escaping ([String: Any], @escaping () -> Void) -> Void
  ) {
    list { result in
      guard let items = result[key] as? [[String: Any]] else { return done(false) }
      forEach(items, { item, next in
        guard deletionAllowed() else { return done(false) }
        clear(item, next)
      }) {
        list { again in done((again[key] as? [Any])?.isEmpty == true) }
      }
    }
  }

  private static func forEach<T>(_ items: [T], _ body: @escaping (T, @escaping () -> Void) -> Void, then: @escaping () -> Void) {
    guard let first = items.first else { return then() }
    body(first) { forEach(Array(items.dropFirst()), body, then: then) }
  }
}

private final class ProfileDataDeletionResult: Sendable {
  let remaining = Mutex<[String]>([])
}

@MainActor
public enum SolaraProfileData {
  public static func delete(_ engine: String, liveProfiles: @escaping @MainActor () -> [String], completion: @escaping @Sendable ([String]) -> Void) {
    let pending = DispatchGroup()
    let result = ProfileDataDeletionResult()
    let allowed: () -> Bool = {
      MainActor.assumeIsolated {
        let root = URL(fileURLWithPath: SolaraCoreHost.dataDirectory, isDirectory: true)
        guard let target = ChromiumProfileData.target(engine, profilesDirectory: root) else {
          NSLog("[solaracore] REFUSING profile data deletion for invalid path: %@", engine)
          result.remaining.withLock { $0.append("refused profile path") }
          return false
        }
        let targets = [target] + WebKitHub.profileDirectories(engine)
        let live = liveProfiles().flatMap { profile in
          [root.appendingPathComponent(profile.isEmpty ? "Default" : "Profile \(profile)", isDirectory: true)] + WebKitHub.profileDirectories(profile)
        }
        let allowed = ChromiumProfileData.deletionAllowed(targets: targets, liveDirectories: live)
        if !allowed { result.remaining.withLock { $0.append("live profile filesystem identity") } }
        return allowed
      }
    }
    guard allowed() else { return completion(result.remaining.withLock { $0 }) }
    pending.enter()
    SolaraCoreProfileData.delete(engine, deletionAllowed: allowed) { remaining in
      result.remaining.withLock { $0.append(contentsOf: remaining) }
      pending.leave()
    }
    pending.enter()
    WebKitHub.shared.deleteProfileData(engine, deletionAllowed: allowed) { removed in
      if !removed { result.remaining.withLock { $0.append("WebKit data") } }
      pending.leave()
    }
    pending.notify(queue: .main) { completion(result.remaining.withLock { $0 }) }
  }
}
