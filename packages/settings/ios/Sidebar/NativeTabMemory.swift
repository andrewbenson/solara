import Foundation
import SolaraCore
import SolaraStore
import SolaraUI

@MainActor
enum NativeTabMemory {
  static let cache = TabMemoryCache()
  static var enabled: Bool { NativeStoreHandle.store?.state.settings["hoverCardMemoryUsage"]?.bool != false }
  private static var installed = false
  private static var queryVersion = UUID()

  static func installEngineQuery() {
    guard !installed else { return }
    installed = true
    #if DEBUG
    guard !devOverride else { return }
    #endif
    restoreEngineQuery()
  }

  private static func restoreEngineQuery() {
    queryVersion = UUID()
    guard SolaraCoreEngineBridge.exports("ac_tabs_memory") else {
      cache.query = nil
      return
    }
    let version = queryVersion
    cache.query = { tabIds, reply in
      var asked: [String: (sessionId: Int, document: String)] = [:]
      if SolaraCoreHost.responds(to: #selector(SolaraCoreHost.chromeTabId(browserId:))) {
        for key in tabIds {
          let tabId = TabMemoryKey.parts(key).tabId
          guard let facts = NativeStoreHandle.store?.pageFacts(tabId), let browserId = facts.ready?.browserId,
            let bridgeId = Int32(exactly: browserId)
          else { continue }
          let sessionId = Int(SolaraCoreHost.chromeTabId(browserId: bridgeId))
          guard sessionId >= 0 else { continue }
          asked[key] = (sessionId, TabMemoryKey.parts(key).document)
        }
      }
      let request = TabMemoryRequest(asked: asked)
      guard !request.sessionIds.isEmpty else {
        reply([:])
        return
      }
      SolaraCoreServices.call("ac_tabs_memory", profile: "", args: ["tabIds": request.sessionIds]) { @Sendable json in
        let decoded = TabMemoryReply.decode(json)
        Task { @MainActor in
          guard version == queryVersion else { return }
          switch decoded {
          case .unavailable:
            if !SolaraCoreEngineBridge.exports("ac_tabs_memory") { cache.query = nil }
            reply([:])
          case .rows(let rows):
            reply(request.readings(rows) { key in document(TabMemoryKey.parts(key).tabId) })
          }
        }
      }
    }
  }

  static func document(_ tabId: String) -> String? { NativeStoreHandle.store?.state.tabs[tabId]?.url }

  #if DEBUG
  private static var devOverride = false

  static func devSet(_ spec: String?) {
    cache.clear()
    queryVersion = UUID()
    guard let spec, spec != "off" else {
      devOverride = false
      restoreEngineQuery()
      return
    }
    devOverride = true
    if spec == "none" {
      cache.query = { _, reply in reply([:]) }
      return
    }
    guard let bytes = Double(spec) else {
      cache.query = nil
      return
    }
    cache.query = { tabIds, reply in
      let reading = TabMemoryReading(bytes: bytes, source: "dev", at: Date())
      reply(tabIds.reduce(into: [:]) { $0[$1] = reading })
    }
  }
  #endif
}
