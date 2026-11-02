import Foundation

@MainActor
public final class NativePrivateFaviconCache: NSObject {
  @objc public static let shared = NativePrivateFaviconCache()
  private var images: [Data: NSCache<NSData, AnyObject>] = [:]
  private var generations: [Data: Int] = [:]
  private var retired: Set<Data> = []

  @objc public func generation(_ profile: String) -> Int { generations[Data(profile.utf8), default: 0] }

  @objc public func isCurrent(_ profile: String, generation: Int) -> Bool {
    !retired.contains(Data(profile.utf8)) && self.generation(profile) == generation
  }

  @objc public func image(_ url: String, profile: String) -> AnyObject? {
    images[Data(profile.utf8)]?.object(forKey: Data(url.utf8) as NSData)
  }

  @objc public func noteImage(_ image: AnyObject, url: String, profile: String) {
    let key = Data(profile.utf8)
    guard profile.hasPrefix("incognito:"), !retired.contains(key) else { return }
    if images[key] == nil {
      let cache = NSCache<NSData, AnyObject>()
      cache.countLimit = 512
      images[key] = cache
    }
    images[key]?.setObject(image, forKey: Data(url.utf8) as NSData)
  }

  @objc public func forgetProfiles(_ profiles: [String]) {
    for profile in profiles where profile.hasPrefix("incognito:") {
      let key = Data(profile.utf8)
      images[key] = nil
      generations[key, default: 0] += 1
      retired.insert(key)
    }
  }
}

@MainActor
public final class NativePrivateDownloadRoutes: NSObject {
  @objc public static let shared = NativePrivateDownloadRoutes()
  private struct Route {
    let profile: String
    let privateDownload: Bool
  }

  private var routes: [Data: Route] = [:]
  private var generations: [Data: String] = [:]
  private var epochs: [Data: Int] = [:]
  private var ended: Set<Data> = []

  @objc public func generation(_ profile: String) -> String? { generations[Data(profile.utf8)] }
  @objc public func epoch(_ profile: String) -> Int { epochs[Data(profile.utf8), default: 0] }
  @objc public func profile(_ id: String) -> String? { routes[Data(id.utf8)]?.profile }

  @objc public func privateEventEpoch(_ topic: String, payload: NSDictionary) -> NSNumber? {
    guard let profile = payload["profile"] as? String else { return nil }
    if topic == "downloads.changed", let download = payload["download"] as? NSDictionary,
      (download["offTheRecord"] as? NSNumber)?.boolValue == true { return NSNumber(value: epoch(profile)) }
    if topic == "downloads.removed", let id = payload["id"] as? String,
      routes[Data(id.utf8)]?.privateDownload == true { return NSNumber(value: epoch(profile)) }
    return nil
  }

  @objc public func isCurrentPrivateEvent(_ profile: String, epoch: Int, privateDownloadsSupported: Bool = true) -> Bool {
    if !privateDownloadsSupported, !ended.contains(Data(profile.utf8)) { return true }
    return self.epoch(profile) == epoch && (epoch == 0 || generation(profile) != nil)
  }

  @objc public func forwardedDownload(_ download: NSDictionary, profile: String, epoch: Int, privateDownloadsSupported: Bool) -> NSDictionary? {
    let privateDownload = (download["offTheRecord"] as? NSNumber)?.boolValue ?? false
    if privateDownloadsSupported {
      guard let id = download["id"] as? String, !id.isEmpty else { return nil }
    }
    if privateDownload, !isCurrentPrivateEvent(profile, epoch: epoch, privateDownloadsSupported: privateDownloadsSupported) { return nil }
    if let id = download["id"] as? String { record(id, profile: profile, privateDownload: privateDownload) }
    let forwarded = download.mutableCopy() as! NSMutableDictionary
    forwarded["profile"] = profile
    return forwarded
  }

  private func record(_ id: String, profile: String, privateDownload: Bool) {
    routes[Data(id.utf8)] = Route(profile: profile, privateDownload: privateDownload)
  }

  @objc public func setGeneration(_ profile: String, generation: String) {
    let key = Data(profile.utf8)
    guard generations[key] != generation else { return }
    generations[key] = generation
    epochs[key, default: 0] += 1
  }

  @objc public func endSession(_ profile: String, privateDownloadsSupported: Bool = true) {
    let key = Data(profile.utf8)
    generations[key] = nil
    epochs[key, default: 0] += 1
    ended.insert(key)
    routes = routes.filter { !$0.value.privateDownload || Data($0.value.profile.utf8) != key }
  }
}
