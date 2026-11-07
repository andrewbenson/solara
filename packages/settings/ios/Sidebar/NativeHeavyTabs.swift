import Foundation
import SolaraCore
import SolaraStore
import SolaraUI

@MainActor
enum NativeHeavyTabs {
  private static var monitor: HeavyTabMonitor?

  static var available: Bool {
    SolaraCoreEngineBridge.exports("ac_tabs_cpu") && SolaraCoreEngineBridge.exports("ac_tabs_memory")
  }

  static func start() {
    guard monitor == nil, NativeStoreHandle.ownsWorkspace, available else { return }
    let made = HeavyTabMonitor(sample: sample, candidates: candidates)
    monitor = made
    made.start()
  }

  private static func candidates() -> [String] {
    guard let store = NativeStoreHandle.store else { return [] }
    let state = store.state
    return state.live.compactMap { $0.value.discarded ? nil : $0.key }
      .compactMap { id in state.tabs[id].map { (id, $0.lastActiveAt) } }
      .sorted { $0.1 > $1.1 }
      .map(\.0)
  }

  private static func sessionIds(_ tabIds: [String]) -> [String: Int] {
    guard SolaraCoreHost.responds(to: #selector(SolaraCoreHost.chromeTabId(browserId:))) else { return [:] }
    var out: [String: Int] = [:]
    for tabId in tabIds {
      guard let browserId = NativeStoreHandle.store?.pageFacts(tabId)?.ready?.browserId, let bridgeId = Int32(exactly: browserId) else { continue }
      let sessionId = Int(SolaraCoreHost.chromeTabId(browserId: bridgeId))
      if sessionId >= 0 { out[tabId] = sessionId }
    }
    return out
  }

  @MainActor
  private final class Gathering {
    var cpu: [Int: TabCPUSample]?
    var memory: [Int: TabMemoryReading]?
    var answers = 0
  }

  private static func sample(_ tabIds: [String], _ withMemory: Bool, _ reply: @escaping @MainActor (HeavyTabSamples?) -> Void) {
    let asked = sessionIds(tabIds)
    let documents = Dictionary(uniqueKeysWithValues: asked.keys.map { ($0, NativeTabMemory.document($0)) })
    let ids = Set(asked.values).sorted()
    guard !ids.isEmpty else { return reply(HeavyTabSamples(cpu: [:], memoryBytes: withMemory ? [:] : nil)) }
    let gathering = Gathering()
    let expected = withMemory ? 2 : 1
    let finish: @MainActor () -> Void = {
      gathering.answers += 1
      guard gathering.answers == expected else { return }
      guard gathering.cpu != nil || gathering.memory != nil else { return reply(nil) }
      var samples = HeavyTabSamples(cpu: [:], memoryBytes: withMemory ? [:] : nil)
      for (tabId, sessionId) in asked where NativeTabMemory.document(tabId) == documents[tabId] {
        samples.cpu[tabId] = gathering.cpu?[sessionId]
        if withMemory { samples.memoryBytes?[tabId] = gathering.memory?[sessionId]?.bytes }
      }
      reply(samples)
    }
    SolaraCoreServices.call("ac_tabs_cpu", profile: "", args: ["tabIds": ids]) { @Sendable json in
      let decoded = TabCPUReply.decode(json)
      Task { @MainActor in
        gathering.cpu = decoded
        finish()
      }
    }
    guard withMemory else { return }
    SolaraCoreServices.call("ac_tabs_memory", profile: "", args: ["tabIds": ids]) { @Sendable json in
      let decoded = TabMemoryReply.decode(json)
      Task { @MainActor in
        if case .rows(let rows) = decoded { gathering.memory = rows }
        finish()
      }
    }
  }
}
