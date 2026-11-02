import Foundation
import Testing
@testable import SolaraEngine

@Suite @MainActor struct PrivateNativeCacheTests {
  @Test func seenImagesAreEvictedOnlyForEndedPrivateAliases() {
    let cache = NativePrivateFaviconCache()
    let ended = "incognito:w@p"
    let surviving = "incognito:x@other"
    let image = NSObject()
    cache.noteImage(image, url: "https://private.test/icon", profile: ended)
    cache.noteImage(image, url: "https://private.test/icon", profile: surviving)
    let generation = cache.generation(ended)
    cache.forgetProfiles([ended, "p"])
    #expect(cache.image("https://private.test/icon", profile: ended) == nil)
    #expect(cache.image("https://private.test/icon", profile: surviving) === image)
    #expect(cache.generation(ended) != generation)
    #expect(!cache.isCurrent(ended, generation: generation))
    cache.noteImage(image, url: "https://private.test/icon", profile: ended)
    #expect(cache.image("https://private.test/icon", profile: ended) == nil)
    #expect(cache.isCurrent("p", generation: 0))
  }

  @Test func forwardedPrivateDownloadKeepsMainPayloadAndUsesNativeCommandRoute() {
    let routes = NativePrivateDownloadRoutes()
    routes.setGeneration("p", generation: "first")
    let download: NSDictionary = [
      "id": "private", "url": "https://private.test/file", "filename": "file", "path": "/tmp/file",
      "state": "downloading", "paused": false, "received": 1, "total": 20, "speed": 2,
      "mimeType": "application/octet-stream", "dangerous": false, "error": NSNull(),
      "offTheRecord": true, "startTime": 1234,
    ]
    let expected = download.mutableCopy() as! NSMutableDictionary
    expected["profile"] = "p"
    let forwarded = routes.forwardedDownload(download, profile: "p", epoch: routes.epoch("p"), privateDownloadsSupported: true)
    #expect(forwarded?.isEqual(expected) == true)
    #expect(forwarded?["privateSessionGeneration"] == nil)
    #expect(routes.profile("private") == "p")
  }

  @Test func heldListCannotRestorePrivateRoutesAfterEndOrReopenButKeepsOrdinaryDownloads() {
    let routes = NativePrivateDownloadRoutes()
    routes.setGeneration("p", generation: "first")
    let heldEpoch = routes.epoch("p")
    let privateDownload: NSDictionary = ["id": "private", "offTheRecord": true]
    let ordinaryDownload: NSDictionary = ["id": "ordinary", "offTheRecord": false]
    #expect(routes.forwardedDownload(privateDownload, profile: "p", epoch: heldEpoch, privateDownloadsSupported: true) != nil)
    #expect(routes.forwardedDownload(ordinaryDownload, profile: "p", epoch: heldEpoch, privateDownloadsSupported: true) != nil)
    routes.endSession("p")
    #expect(routes.profile("private") == nil)
    #expect(routes.profile("ordinary") == "p")
    #expect(routes.forwardedDownload(privateDownload, profile: "p", epoch: heldEpoch, privateDownloadsSupported: true) == nil)
    #expect(routes.forwardedDownload(privateDownload, profile: "p", epoch: routes.epoch("p"), privateDownloadsSupported: true) == nil)
    routes.setGeneration("p", generation: "replacement")
    #expect(routes.forwardedDownload(privateDownload, profile: "p", epoch: heldEpoch, privateDownloadsSupported: true) == nil)
    #expect(routes.forwardedDownload(ordinaryDownload, profile: "p", epoch: heldEpoch, privateDownloadsSupported: true) != nil)
    #expect(routes.profile("private") == nil)
    #expect(routes.forwardedDownload(["id": "replacement", "offTheRecord": true], profile: "p", epoch: routes.epoch("p"), privateDownloadsSupported: true) != nil)
    #expect(routes.profile("replacement") == "p")
    #expect(routes.profile("never-seen") == nil)
  }

  @Test func absentExportsRetirePrivateRoutesAndRejectLateEvents() throws {
    let routes = NativePrivateDownloadRoutes()
    routes.setGeneration("p", generation: "first")
    let heldEpoch = routes.epoch("p")
    let privateDownload: NSDictionary = ["id": "private", "offTheRecord": true]
    let ordinaryDownload: NSDictionary = ["id": "ordinary", "offTheRecord": false]
    #expect(routes.forwardedDownload(privateDownload, profile: "p", epoch: heldEpoch, privateDownloadsSupported: false) != nil)
    #expect(routes.forwardedDownload(ordinaryDownload, profile: "p", epoch: heldEpoch, privateDownloadsSupported: false) != nil)
    #expect(routes.forwardedDownload(["id": "surviving", "offTheRecord": true], profile: "q", epoch: 0, privateDownloadsSupported: false) != nil)
    routes.endSession("p", privateDownloadsSupported: false)
    #expect(routes.profile("private") == nil)
    #expect(routes.profile("ordinary") == "p")
    #expect(routes.profile("surviving") == "q")
    #expect(routes.forwardedDownload(privateDownload, profile: "p", epoch: heldEpoch, privateDownloadsSupported: false) == nil)
    let latePayload: NSDictionary = ["profile": "p", "download": privateDownload]
    let lateEpoch = try #require(routes.privateEventEpoch("downloads.changed", payload: latePayload))
    #expect(!routes.isCurrentPrivateEvent("p", epoch: lateEpoch.intValue, privateDownloadsSupported: false))
    #expect(routes.forwardedDownload(privateDownload, profile: "p", epoch: lateEpoch.intValue, privateDownloadsSupported: false) == nil)
    #expect(routes.forwardedDownload(ordinaryDownload, profile: "p", epoch: heldEpoch, privateDownloadsSupported: false) != nil)
    #expect(routes.profile("private") == nil)
    routes.setGeneration("p", generation: "replacement")
    #expect(routes.forwardedDownload(privateDownload, profile: "p", epoch: heldEpoch, privateDownloadsSupported: false) == nil)
    #expect(routes.forwardedDownload(privateDownload, profile: "p", epoch: lateEpoch.intValue, privateDownloadsSupported: false) == nil)
    #expect(routes.profile("private") == nil)
    #expect(routes.forwardedDownload(["id": "replacement", "offTheRecord": true], profile: "p", epoch: routes.epoch("p"), privateDownloadsSupported: false) != nil)
    #expect(routes.profile("replacement") == "p")
  }

  @Test func absentExportsKeepManagedPrivateDownloadsByteIdenticalBeforeNativeEnd() throws {
    let routes = NativePrivateDownloadRoutes()
    let capturedEpoch = routes.epoch("p")
    let download: NSDictionary = [
      "id": "private", "url": "https://private.test/file", "filename": "file", "path": "/tmp/file",
      "state": "downloading", "paused": false, "received": 1, "total": 20, "speed": 2,
      "mimeType": "application/octet-stream", "dangerous": false, "error": NSNull(),
      "offTheRecord": true, "startTime": 1234,
    ]
    let expected: NSDictionary = [
      "id": "private", "url": "https://private.test/file", "filename": "file", "path": "/tmp/file",
      "state": "downloading", "paused": false, "received": 1, "total": 20, "speed": 2,
      "mimeType": "application/octet-stream", "dangerous": false, "error": NSNull(),
      "offTheRecord": true, "startTime": 1234, "profile": "p",
    ]
    let expectedBytes = try JSONSerialization.data(withJSONObject: expected, options: [.sortedKeys])
    for phase in 0...2 {
      if phase == 1 { routes.setGeneration("p", generation: "first") }
      if phase == 2 { routes.setGeneration("p", generation: "replacement") }
      for epoch in [capturedEpoch, routes.epoch("p")] {
        let forwarded = try #require(routes.forwardedDownload(download, profile: "p", epoch: epoch, privateDownloadsSupported: false))
        #expect(try JSONSerialization.data(withJSONObject: forwarded, options: [.sortedKeys]) == expectedBytes)
      }
      #expect(routes.profile("private") == "p")
    }
    #expect(download["profile"] == nil)
    #expect(download["privateSessionGeneration"] == nil)
  }

  @Test func absentExportsKeepMainMissingAndEmptyDownloadIds() {
    let routes = NativePrivateDownloadRoutes()
    routes.setGeneration("p", generation: "first")
    #expect(routes.forwardedDownload(["offTheRecord": true], profile: "p", epoch: 0, privateDownloadsSupported: false)?.isEqual(["offTheRecord": true, "profile": "p"]) == true)
    #expect(routes.forwardedDownload(["id": "", "offTheRecord": true], profile: "p", epoch: 0, privateDownloadsSupported: false)?.isEqual(["id": "", "offTheRecord": true, "profile": "p"]) == true)
    #expect(routes.forwardedDownload(["id": 42, "offTheRecord": true], profile: "p", epoch: 0, privateDownloadsSupported: false)?.isEqual(["id": 42, "offTheRecord": true, "profile": "p"]) == true)
    #expect(routes.profile("") == "p")
    let epoch = routes.epoch("p")
    routes.endSession("p", privateDownloadsSupported: false)
    #expect(routes.profile("") == nil)
    #expect(routes.forwardedDownload(["id": "", "offTheRecord": true], profile: "p", epoch: routes.epoch("p"), privateDownloadsSupported: false) == nil)
    #expect(routes.generation("p") == nil)
    #expect(routes.epoch("p") != epoch)
    #expect(routes.forwardedDownload(["id": "", "offTheRecord": true], profile: "p", epoch: routes.epoch("p"), privateDownloadsSupported: true) == nil)
  }

  @Test func absentExportsFenceCapturedRawChangedAndRemovedWithoutChangingPayloadBytes() throws {
    let routes = NativePrivateDownloadRoutes()
    routes.setGeneration("p", generation: "first")
    let download: NSDictionary = ["id": "private", "offTheRecord": true, "url": "https://private.test/file"]
    let changed: NSDictionary = ["profile": "p", "download": download]
    _ = routes.forwardedDownload(download, profile: "p", epoch: routes.epoch("p"), privateDownloadsSupported: false)
    let removed: NSDictionary = ["profile": "p", "id": "private"]
    let changedEpoch = try #require(routes.privateEventEpoch("downloads.changed", payload: changed))
    let removedEpoch = try #require(routes.privateEventEpoch("downloads.removed", payload: removed))
    let changedBytes = try JSONSerialization.data(withJSONObject: changed, options: [.sortedKeys])
    let removedBytes = try JSONSerialization.data(withJSONObject: removed, options: [.sortedKeys])
    routes.setGeneration("p", generation: "updated")
    #expect(routes.isCurrentPrivateEvent("p", epoch: changedEpoch.intValue, privateDownloadsSupported: false))
    #expect(routes.isCurrentPrivateEvent("p", epoch: removedEpoch.intValue, privateDownloadsSupported: false))
    for phase in 0...1 {
      if phase == 0 { routes.endSession("p", privateDownloadsSupported: false) }
      if phase == 1 { routes.setGeneration("p", generation: "replacement") }
      #expect(!routes.isCurrentPrivateEvent("p", epoch: changedEpoch.intValue, privateDownloadsSupported: false))
      #expect(!routes.isCurrentPrivateEvent("p", epoch: removedEpoch.intValue, privateDownloadsSupported: false))
      #expect(try JSONSerialization.data(withJSONObject: changed, options: [.sortedKeys]) == changedBytes)
      #expect(try JSONSerialization.data(withJSONObject: removed, options: [.sortedKeys]) == removedBytes)
    }
  }

  @Test func queuedRawEngineForwardsKeepNativeEpochWithoutChangingSerializedPayload() throws {
    let routes = NativePrivateDownloadRoutes()
    routes.setGeneration("p", generation: "first")
    let download: NSDictionary = ["id": "private", "offTheRecord": true, "url": "https://private.test/file"]
    let changed: NSDictionary = ["profile": "p", "download": download]
    _ = routes.forwardedDownload(download, profile: "p", epoch: routes.epoch("p"), privateDownloadsSupported: true)
    let removed: NSDictionary = ["profile": "p", "id": "private"]
    let changedEpoch = try #require(routes.privateEventEpoch("downloads.changed", payload: changed))
    let removedEpoch = try #require(routes.privateEventEpoch("downloads.removed", payload: removed))
    #expect(routes.isCurrentPrivateEvent("p", epoch: changedEpoch.intValue))
    #expect(routes.isCurrentPrivateEvent("p", epoch: removedEpoch.intValue))
    #expect(changed.count == 2)
    #expect(download.count == 3)
    routes.endSession("p")
    routes.setGeneration("p", generation: "replacement")
    #expect(!routes.isCurrentPrivateEvent("p", epoch: changedEpoch.intValue))
    #expect(!routes.isCurrentPrivateEvent("p", epoch: removedEpoch.intValue))
    #expect(routes.privateEventEpoch("history.changed", payload: changed) == nil)
    #expect(routes.privateEventEpoch("downloads.changed", payload: ["profile": "p", "download": ["offTheRecord": false]]) == nil)
    #expect(routes.privateEventEpoch("downloads.removed", payload: ["profile": "p", "id": "ordinary"]) == nil)
  }

  @Test func routingAndFaviconAliasesUseExactIds() {
    let first = "incognito:w@caf\u{e9}"
    let second = "incognito:w@cafe\u{301}"
    let image = NSObject()
    let cache = NativePrivateFaviconCache()
    cache.noteImage(image, url: "icon", profile: first)
    cache.noteImage(image, url: "icon", profile: second)
    cache.forgetProfiles([first])
    #expect(cache.image("icon", profile: second) === image)
    let routes = NativePrivateDownloadRoutes()
    _ = routes.forwardedDownload(["id": "private\u{e9}", "offTheRecord": true], profile: first, epoch: 0, privateDownloadsSupported: false)
    _ = routes.forwardedDownload(["id": "privatee\u{301}", "offTheRecord": true], profile: second, epoch: 0, privateDownloadsSupported: false)
    routes.endSession(first)
    #expect(routes.profile("private\u{e9}") == nil)
    #expect(routes.profile("privatee\u{301}") == second)
  }
}
