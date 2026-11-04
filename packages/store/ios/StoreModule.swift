import ExpoModulesCore
import Foundation
import SolaraCore
internal import SolaraBridgeCore
internal import SolaraModel
internal import SolaraStore
internal import SolaraUI
internal import SolaraSyncAdapter

public class StoreModule: Module {
  private var subscription: Int?
  private var pageRuntimeID: UUID?

  public func definition() -> ModuleDefinition {
    Name("SolaraStoreAdapter")

    Events("onStoreCommit")

    OnCreate {
      PairingServices.shared.registerStore(healthy: {
        NativeStore.shared != nil && NativeStore.ownsWorkspace && !NativeStore.safeMode && NativeStore.refusedSession == nil && NativeStore.unavailableReason == nil
      }, revision: { NativeStore.pairingRevision() }, projection: { operation, links in
        try NativeStore.pairingCheckpoint(operation: operation, links: links)
      })
      let sink = StoreModuleSink(self)
      pageMain {
        guard let module = sink.module, let context = module.appContext else { return }
        let id = PageIssuer.runtimeID(for: context)
        module.pageRuntimeID = id
        PageRuntimeLease.shared.begin(module, id) { RNPageReports.beginRuntime($0) }
      }
    }

    OnDestroy {
      let sink = StoreModuleSink(self)
      pageMain {
        guard let module = sink.module else { return }
        PageRuntimeLease.shared.end(module, module.pageRuntimeID) { RNPageReports.endRuntime($0) }
      }
    }

    AsyncFunction("devTabSleep") { (action: String) async -> String in
      await devTabSleep(action)
    }

    Function("pageFacts") { (tabId: String) -> String? in
      NativeStore.shared?.bridge.store.pageFacts(tabId).map { pageFactsJSON(tabId, $0).text() }
    }

    Function("livePages") { () -> String? in
      guard let pages = NativeStore.shared?.bridge.store.livePages() else { return nil }
      return JSONValue.object(JSONObject(pages.map { ($0.key, pageFactsJSON($0.key, $0.value)) })).text()
    }

    Function("isPageCurrent") { (tabId: String, sessionGeneration: String, registrationGeneration: Double) -> Bool in
      pageMain { RNPageReports.isPageCurrent(tabId: tabId, sessionGeneration: sessionGeneration, registrationGeneration: registrationGeneration) }
    }

    Function("updatePageContext") { (tabId: String, sessionGeneration: String, registrationGeneration: Double, contextJSON: String) -> Bool in
      pageMain { RNPageReports.updatePageContext(tabId: tabId, sessionGeneration: sessionGeneration, registrationGeneration: registrationGeneration, contextJSON: contextJSON) }
    }

    Function("updateRNPageContext") { (tabId: String, sessionGeneration: String, contextJSON: String) -> Bool in
      pageMain { RNPageReports.updateContext(tabId: tabId, sessionGeneration: sessionGeneration, contextJSON: contextJSON) }
    }

    Function("isRNPageCurrent") { (tabId: String, sessionGeneration: String) -> Bool in
      pageMain { RNPageReports.isCurrent(tabId: tabId, sessionGeneration: sessionGeneration) }
    }

    AsyncFunction("finishRNPageIssue") { (tabId: String, guardJSON: String, promise: Promise) in
      nonisolated(unsafe) let reply = promise
      MainActor.assumeIsolated {
        RNPageReports.finish(tabId: tabId, guardJSON: guardJSON,
          resolve: { reply.resolve($0) }, reject: { reply.reject($0, $1) })
      }
    }.runOnQueue(.main)

    Function("status") { () -> [String: Any] in
      let syncRedesign = LaunchSwitch(rawValue: "SOLARA_SYNC_REDESIGN").map { LaunchSwitches.shared.isOn($0, defaultOn: false) } ?? false
      var status: [String: Any]
      if NativeStore.shared != nil {
        status = ["active": true, "scope": NativeStore.ownsWorkspace ? "everything" : "settingsAndDownloads", "syncRedesign": syncRedesign]
      } else {
        status = ["active": false, "reason": NativeStore.unavailableReason ?? "not launched", "handedOff": NativeStore.handedOff, "syncRedesign": syncRedesign]
        if let refusedSession = NativeStore.refusedSession { status["refusedSession"] = refusedSession }
      }
      status["nativeTabSleep"] = pageMain { NativeStore.shared?.tabSleep.isRunning == true }
      if NativeStore.safeMode { status["safeMode"] = NativeStore.safeModeAfterFailedLaunches ? "failedLaunches" : "option" }
      return status
    }

    #if DEBUG
    AsyncFunction("devStripCommandProbe") { () -> String in
      MainActor.assumeIsolated {
        guard let data = try? JSONSerialization.data(withJSONObject: SolaraCoreStripEngine.commandProbe) else { return "null" }
        return String(data: data, encoding: .utf8) ?? "null"
      }
    }.runOnQueue(.main)
    #endif

    Function("snapshot") { () -> String? in
      NativeStore.shared?.bridge.snapshotJSON()
    }

    Function("dispatch") { (commandJSON: String, sinceRev: Int) -> String? in
      guard let bridge = NativeStore.shared?.bridge else { return nil }
      guard needsPagePreparation(commandJSON) else { return bridge.dispatch(commandJSON, sinceRev: sinceRev) }
      return pageMain {
        bridge.dispatch(json: commandJSON, sinceRev: sinceRev, prepare: { commands in
          try MainActor.assumeIsolated { try RNPageReports.normalize(commands) }
        }).text()
      }
    }

    Function("catchUp") { (sinceRev: Int) -> String? in
      guard let bridge = NativeStore.shared?.bridge else { return nil }
      return JSONValue.object(bridge.catchUp(sinceRev: sinceRev)).text()
    }

    Function("useSyncOrigins") { (on: Bool) -> Bool in
      guard let store = NativeStore.shared else { return false }
      store.bridge.store.useSyncOrigins(on)
      return true
    }

    Function("syncAnchor") { () -> String? in
      NativeStore.shared?.writer?.syncAnchor
    }

    Function("setSyncAnchor") { (anchor: String) -> Bool in
      guard let writer = NativeStore.shared?.writer else { return false }
      writer.setSyncAnchor(anchor)
      return true
    }

    Function("freeze") { () -> Bool in
      NativeStore.shared?.freeze()
      return NativeStore.shared != nil
    }

    Function("flush") { (timeout: Double) -> String in
      NativeStore.shared?.host.flush(timeout: timeout).description ?? "failed: the native store is unavailable"
    }

    OnStartObserving {
      guard self.subscription == nil, let bridge = NativeStore.shared?.bridge else { return }
      let sink = EventSink(module: self)
      self.subscription = bridge.observeForeignCommits { event in
        sink.module?.sendEvent("onStoreCommit", ["event": event])
      }
    }

    OnStopObserving {
      if let id = self.subscription { NativeStore.shared?.bridge.store.unsubscribe(id) }
      self.subscription = nil
    }
  }
}

final class EventSink: @unchecked Sendable {
  weak var module: StoreModule?

  init(module: StoreModule) {
    self.module = module
  }
}

private func needsPagePreparation(_ commandJSON: String) -> Bool {
  guard let parsed = try? JSONValue.parse(commandJSON), parsed["fromSync"]?.truthy != true else { return false }
  let commands = parsed["commands"].map { $0.array ?? [$0] } ?? parsed.array ?? [parsed]
  return commands.contains { $0["name"]?.string == "pageReport" && $0["args"]?.array?.dropFirst().first?["type"]?.string == "issued" }
}

@MainActor private func devTabSleep(_ action: String) async -> String {
  guard SolaraCoreTestHooksAllowed(), devTabSleepScratchData() else {
    return JSONValue.object(["error": .string("test instances only")]).text()
  }
  guard let tabSleep = NativeStore.shared?.tabSleep else { return JSONValue.object(["error": .string("no native store")]).text() }
  if action == "status" { return JSONValue.object(["running": .bool(tabSleep.isRunning)]).text() }
  if action == "sweep" {
    let slept = await tabSleep.sweepNow()
    return JSONValue.object(["running": .bool(tabSleep.isRunning), "slept": .array(slept.map { .string($0) })]).text()
  }
  if action.hasPrefix("pressure:"), let pressure = TabSleepPolicy.Pressure(rawValue: String(action.dropFirst("pressure:".count))) {
    tabSleep.setPressure(pressure)
    return JSONValue.object(["pressure": .string(pressure.rawValue)]).text()
  }
  return JSONValue.object(["error": .string("unknown action \(action)")]).text()
}

private func devTabSleepScratchData() -> Bool {
  guard let path = ProcessInfo.processInfo.environment["SOLARA_DATA_DIR"], path.hasPrefix("/"), path != "/" else { return false }
  let marker = URL(fileURLWithPath: path, isDirectory: true).resolvingSymlinksInPath().appendingPathComponent(".solara-probe-scratch")
  guard let values = try? marker.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey]) else { return false }
  return values.isRegularFile == true && values.isSymbolicLink != true
}

private final class StoreModuleSink: @unchecked Sendable {
  weak var module: StoreModule?
  init(_ module: StoreModule) { self.module = module }
}

private func pageMain<T: Sendable>(_ work: @MainActor () -> T) -> T {
  if Thread.isMainThread { return MainActor.assumeIsolated { work() } }
  return DispatchQueue.main.sync { MainActor.assumeIsolated { work() } }
}

private func pageFactsJSON(_ tabId: String, _ facts: PageFacts) -> JSONValue {
  var value: JSONObject = ["generation": .string(facts.generation), "ready": .null,
    "protectionKnown": .bool(pageMain { RNPageReports.protectionKnown(tabId: tabId, sessionGeneration: facts.generation) }),
    "keepAlive": .null, "latchedThrough": JSONValue(facts.latchedThrough), "newestEventSeq": JSONValue(facts.newestEventSeq)]
  if let ready = facts.ready {
    var readyJSON: JSONObject = ["browserId": JSONValue(ready.browserId)]
    if let tabId = ready.tabId { readyJSON["tabId"] = JSONValue(tabId) }
    value["ready"] = .object(readyJSON)
  }
  if let feed = facts.keepAlive {
    value["keepAlive"] = ["epoch": JSONValue(feed.epoch), "seq": JSONValue(feed.seq), "handled": JSONValue(feed.handled),
      "keep": ["capturing": .bool(feed.keep.capturing), "newTabShown": .bool(feed.keep.newTabShown),
        "pip": .bool(feed.keep.pip), "displayRequest": .bool(feed.keep.displayRequest), "media": .string(feed.keep.media.rawValue)],
      "reveal": ["fullscreen": .bool(feed.reveal.fullscreen), "crashed": .bool(feed.reveal.crashed),
        "unresponsive": .bool(feed.reveal.unresponsive), "scrolledDown": .bool(feed.reveal.scrolledDown), "sharing": .bool(feed.reveal.sharing)]]
  }
  return .object(value)
}
