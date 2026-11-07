import ExpoModulesCore
import Foundation
import SolaraEngine
import SolaraLive
import SolaraSyncAdapter

public class SettingsModule: Module {
  public func definition() -> ModuleDefinition {
    Name("SolaraSettings")

    Events("onAppIntegrationPresentation", "onSettingsCall", "onLiveReplica", "onLiveAuthRequest", "onLiveCloseGroup")

    OnCreate {
      _ = NativeLiveEngine.shared
      DispatchQueue.main.async { MainActor.assumeIsolated {
        PairingAdapter.install()
        NativeSettingsWindow.install()
      } }
    }

    Function("available") { () -> Bool in
      NativeSettingsWindow.enabled
    }

    Function("servicesActive") { () -> Bool in
      NativeCliControl.active
    }

    AsyncFunction("startAppStartup") { (optionsJSON: String, promise: Promise) in
      nonisolated(unsafe) let reply = promise
      let sink = SettingsEventSink(module: self)
      MainActor.assumeIsolated {
        guard let data = optionsJSON.data(using: .utf8),
          let options = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
        else { return reply.reject("ERR_APP_STARTUP", "invalid startup options") }
        reply.resolve(NativeAppStartup.shared.start(options) { event in
          sink.module?.sendEvent("onAppIntegrationPresentation", event)
        })
      }
    }.runOnQueue(.main)

    AsyncFunction("completeAppStartup") {
      MainActor.assumeIsolated { NativeAppStartup.shared.complete() }
    }.runOnQueue(.main)

    AsyncFunction("cancelOnboardingReplay") { (requestId: String) in
      MainActor.assumeIsolated { NativeAppStartup.shared.cancelOnboardingReplay(requestId) }
    }.runOnQueue(.main)

    AsyncFunction("appIntegrationFirstWindow") { (onboardingActive: Bool, promise: Promise) in
      nonisolated(unsafe) let reply = promise
      MainActor.assumeIsolated {
        Task { @MainActor in
          do {
            try await NativeAppStartup.shared.firstWindow(onboardingActive: onboardingActive)
            reply.resolve(nil)
          } catch {
            reply.reject("ERR_DEFAULT_BROWSER_OFFER", String(describing: error))
          }
        }
      }
    }.runOnQueue(.main)

    AsyncFunction("appIntegrationNotification") { (action: String, tabId: String?, windowId: String?) in
      MainActor.assumeIsolated { NativeAppStartup.shared.notification(action: action, tabId: tabId, windowId: windowId) }
    }.runOnQueue(.main)

    AsyncFunction("appIntegrationCommand") { (command: String, windowId: String?, promise: Promise) in
      nonisolated(unsafe) let reply = promise
      MainActor.assumeIsolated {
        NativeAppIntegration.shared.startWhenReady()
        guard NativeAppIntegration.shared.perform(command, windowId: windowId) || NativeAppStartup.shared.perform(command, windowId: windowId) else {
          return reply.reject("ERR_APP_INTEGRATION", "unknown native app integration command: \(command)")
        }
        reply.resolve(nil)
      }
    }.runOnQueue(.main)

    AsyncFunction("installCli") { (reason: String, promise: Promise) in
      nonisolated(unsafe) let reply = promise
      MainActor.assumeIsolated {
        guard NativeCliControl.active else { return reply.reject("ERR_SERVICES_OFF", "native services are off") }
        NativeCliControl.shared.install(reason: reason) { result in
          nonisolated(unsafe) let result = result
          reply.resolve(result)
        }
      }
    }.runOnQueue(.main)

    AsyncFunction("startHistoryCatalog") { (profiles: [String], promise: Promise) in
      nonisolated(unsafe) let reply = promise
      MainActor.assumeIsolated {
        Task { @MainActor in
          await NativeHistoryCatalog.start(engineProfiles: profiles)
          reply.resolve(nil)
        }
      }
    }.runOnQueue(.main)

    AsyncFunction("libraryCommand") { (kind: String, engineProfile: String, payload: [String: Any], promise: Promise) in
      nonisolated(unsafe) let reply = promise
      nonisolated(unsafe) let body = payload
      MainActor.assumeIsolated {
        Task { @MainActor in
          do {
            reply.resolve(try await NativeHistoryCatalog.command(kind: kind, engineProfile: engineProfile, payload: body))
          } catch {
            reply.reject("ERR_LIBRARY_COMMAND", String(describing: error))
          }
        }
      }
    }.runOnQueue(.main)

    #if DEBUG
    AsyncFunction("devFaviconLookup") { (page: String, engineProfile: String, promise: Promise) in
      nonisolated(unsafe) let reply = promise
      MainActor.assumeIsolated {
        Task { @MainActor in reply.resolve(await NativeHistoryCatalog.devFaviconLookup(page: page, engineProfile: engineProfile)) }
      }
    }.runOnQueue(.main)
    #endif

    #if DEBUG
    AsyncFunction("devBookmarksSnapshot") { (profile: String, promise: Promise) in
      nonisolated(unsafe) let reply = promise
      MainActor.assumeIsolated { reply.resolve(NativeHistoryCatalog.bookmarksSnapshot(engineProfile: profile)) }
    }.runOnQueue(.main)
    #endif

    #if DEBUG
    AsyncFunction("devHistorySnapshot") { (profile: String, promise: Promise) in
      nonisolated(unsafe) let reply = promise
      MainActor.assumeIsolated { reply.resolve(NativeHistoryCatalog.snapshot(engineProfile: profile)) }
    }.runOnQueue(.main)
    #endif

    AsyncFunction("navigate") { (pane: String?, profileId: String?, detail: String?) in
      MainActor.assumeIsolated { NativeSettingsWindow.navigate(pane: pane, profileId: profileId, detail: detail) }
    }.runOnQueue(.main)

    AsyncFunction("devImport") { (action: String, argument: String?, promise: Promise) in
      nonisolated(unsafe) let reply = promise
      MainActor.assumeIsolated {
        Task { @MainActor in
          let result = await NativeImportWindow.drive(action, argument)
          nonisolated(unsafe) let sendable = result
          reply.resolve(sendable)
        }
      }
    }.runOnQueue(.main)

    AsyncFunction("devOnboarding") { (action: String, argument: String?) -> String in
      MainActor.assumeIsolated { NativeOnboarding.drive(action, argument) }
    }.runOnQueue(.main)

    AsyncFunction("devSettings") { (action: String, argument: String?) -> String in
      MainActor.assumeIsolated { SettingsDev.drive(action, argument) }
    }.runOnQueue(.main)

    AsyncFunction("devSettingsSwitch") { (pane: String, promise: Promise) in
      nonisolated(unsafe) let reply = promise
      MainActor.assumeIsolated { SettingsDev.switchPane(pane) { reply.resolve($0) } }
    }.runOnQueue(.main)

    AsyncFunction("devTimings") { () -> String in
      MainActor.assumeIsolated { SettingsTimings.takeJSON() }
    }.runOnQueue(.main)

    AsyncFunction("focusSearch") {
      MainActor.assumeIsolated { NativeSettingsWindow.focusSearch() }
    }.runOnQueue(.main)

    AsyncFunction("reply") { (id: Int, resultJSON: String?, error: String?) in
      MainActor.assumeIsolated { SettingsJS.shared.reply(id, resultJSON: resultJSON, error: error) }
    }.runOnQueue(.main)

    Function("liveInitialReplica") { () -> [String: Any] in NativeLiveEngine.shared.initialReplica() }

    Function("bookmarkWriterState") { () -> [String: Any] in NativeBookmarkWriter.state() }

    Function("bookmarkWriterSnapshot") { (profileId: String) throws -> [String: Any] in
      try NativeBookmarkWriter.bridge { try NativeBookmarkWriter.snapshot(profile: profileId) }
    }

    AsyncFunction("submitBookmarkMutations") { (profileId: String, mutationsJSON: String, engine: String, generation: String, requestId: String?) throws -> [String: Any] in
      try NativeBookmarkWriter.bridge { try NativeBookmarkWriter.submit(profile: profileId, mutationsJSON: mutationsJSON, engine: engine, generation: generation, requestID: requestId) }
    }

    Function("replaceBookmarkDocument") { (profileId: String, documentJSON: String, expectedRevision: String, engine: String, generation: String, requestId: String?) throws -> [String: Any] in
      try NativeBookmarkWriter.bridge { try NativeBookmarkWriter.replace(profile: profileId, documentJSON: documentJSON, expectedRevision: expectedRevision, engine: engine, generation: generation, requestID: requestId) }
    }

    AsyncFunction("liveCommand") { (name: String, payloadJSON: String, promise: Promise) in
      nonisolated(unsafe) let reply = promise
      MainActor.assumeIsolated {
        Task { @MainActor in
          do { reply.resolve(try await NativeLiveEngine.shared.command(name: name, payloadJSON: payloadJSON)) }
          catch { reply.reject("ERR_LIVE_COMMAND", String(describing: error)) }
        }
      }
    }.runOnQueue(.main)

    AsyncFunction("liveMeetingBrowser") { (snapshotJSON: String, promise: Promise) in
      do {
        try NativeLiveEngine.shared.meetingBrowser(snapshotJSON)
        promise.resolve(nil)
      } catch {
        promise.reject("ERR_LIVE_MEETING_BROWSER", String(describing: error))
      }
    }.runOnQueue(.main)

    AsyncFunction("liveStart") { (promise: Promise) in
      nonisolated(unsafe) let reply = promise
      MainActor.assumeIsolated {
        Task { @MainActor in
          await NativeLiveEngine.shared.start()
          reply.resolve(nil)
        }
      }
    }.runOnQueue(.main)

    AsyncFunction("resolveLiveAuth") { (requestId: String, redirectURL: String?, error: String?) in
      NativeLiveAuth.shared.resolve(requestId: requestId, redirectURL: redirectURL, error: error)
    }.runOnQueue(.main)

    #if DEBUG
    AsyncFunction("devLiveSnapshot") { (promise: Promise) in
      nonisolated(unsafe) let reply = promise
      MainActor.assumeIsolated {
        Task { @MainActor in reply.resolve(await NativeLiveEngine.shared.devSnapshot()) }
      }
    }.runOnQueue(.main)
    #endif

    AsyncFunction("publish") { (topic: String, json: String) in
      MainActor.assumeIsolated { SettingsJS.shared.publish(topic, json: json) }
    }.runOnQueue(.main)

    OnStartObserving {
      let sink = SettingsEventSink(module: self)
      NativeLiveEngine.shared.setEvent { revision, replicaJSON, calendarJSON, meetingAlertJSON in
        DispatchQueue.main.async { sink.module?.sendEvent("onLiveReplica", ["revision": revision, "replicaJSON": replicaJSON, "calendarJSON": calendarJSON, "meetingAlertJSON": meetingAlertJSON]) }
      }
      NativeLiveEngine.shared.setCloseGroupEvent { groupId in
        DispatchQueue.main.async { sink.module?.sendEvent("onLiveCloseGroup", ["groupId": groupId]) }
      }
      NativeLiveAuth.shared.setEvent { value in
        DispatchQueue.main.async { sink.module?.sendEvent("onLiveAuthRequest", value) }
      }
      DispatchQueue.main.async {
        MainActor.assumeIsolated {
          SettingsJS.shared.send = { id, name, args in
            sink.module?.sendEvent("onSettingsCall", ["id": id, "name": name, "args": args])
          }
        }
      }
    }

    OnStopObserving {
      DispatchQueue.main.async {
        MainActor.assumeIsolated {
          NativeLiveEngine.shared.setEvent(nil)
          NativeLiveEngine.shared.setCloseGroupEvent(nil)
          NativeLiveAuth.shared.setEvent(nil)
          NativeAppStartup.shared.disconnect()
          SettingsJS.shared.send = nil
          SettingsJS.shared.failAll("JS stopped listening for Settings calls")
        }
      }
    }
  }
}

extension NativeBookmarkWriter {
  static func bridge<T>(_ body: () throws -> T) throws -> T {
    do { return try body() }
    catch let error as BookmarkWriterError {
      throw Exception(name: "BookmarkWriterError", description: error.description, code: error.code)
    }
  }
}

final class SettingsEventSink: @unchecked Sendable {
  weak var module: SettingsModule?

  init(module: SettingsModule) {
    self.module = module
  }
}
