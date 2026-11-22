import AppKit
import ExpoModulesCore
import Foundation
import SolaraModel
import SolaraOmnibox
import SolaraStore
import SolaraUI

public class NewTabModule: Module {
  public func definition() -> ModuleDefinition {
    Name("SolaraNewTab")

    Events("onSourceStatus")

    OnCreate {
      DispatchQueue.main.async { MainActor.assumeIsolated { NativeOmniboxSources.shared.start() } }
    }

    OnDestroy {
      DispatchQueue.main.async {
        MainActor.assumeIsolated {
          NativeOmniboxSources.shared.onStatus = nil
          NativeOmniboxSources.shared.stop()
        }
      }
    }

    OnStartObserving {
      let sink = NewTabSourceEventSink(module: self)
      DispatchQueue.main.async {
        MainActor.assumeIsolated {
          NativeOmniboxSources.shared.observeStatus { status in
            sink.module?.sendEvent("onSourceStatus", status.dictionary)
          }
        }
      }
    }

    OnStopObserving {
      DispatchQueue.main.async { MainActor.assumeIsolated { NativeOmniboxSources.shared.onStatus = nil } }
    }

    AsyncFunction("sourceStatus") { () -> [String: Any] in
      nonisolated(unsafe) var status: [String: Any] = [:]
      MainActor.assumeIsolated {
        NativeOmniboxSources.shared.start()
        NativeOmniboxSources.shared.reconcile()
        status = NativeOmniboxSources.shared.status.dictionary
      }
      return status
    }.runOnQueue(.main)

    #if SOLARA_PROBES
    AsyncFunction("mainThreadTiming") { (reset: Bool) -> [String: Any] in
      nonisolated(unsafe) var result: [String: Any] = ["spans": [], "available": false]
      MainActor.assumeIsolated {
        guard ProcessInfo.processInfo.environment["SOLARA_BACKGROUND"] == "1",
          ProcessInfo.processInfo.environment["SOLARA_DATA_DIR"]?.isEmpty == false else { return }
        let dropped = NewTabMainThreadTiming.dropped
        let spans = NewTabMainThreadTiming.read(reset: reset).map { span -> [String: Any] in
          ["phase": span.phase, "windowId": span.windowId as Any? ?? NSNull(), "tabId": span.tabId as Any? ?? NSNull(),
            "startedMs": span.startedMs, "finishedMs": span.finishedMs, "durationMs": span.finishedMs - span.startedMs]
        }
        result = ["spans": spans, "dropped": dropped, "available": true]
      }
      return result
    }.runOnQueue(.main)
    #endif

    Function("available") { () -> Bool in
      NativeSettingsHandle.active
    }

    AsyncFunction("benchFixture") { (profileId: String, promise: Promise) in
      nonisolated(unsafe) let reply = promise
      MainActor.assumeIsolated {
        guard ProcessInfo.processInfo.environment["AC_BENCH_OMNIBOX"] == "1",
              ProcessInfo.processInfo.environment["SOLARA_BACKGROUND"] == "1",
              ProcessInfo.processInfo.environment["SOLARA_DATA_DIR"]?.isEmpty == false else { reply.resolve([:]); return }
        reply.resolve([
          "source": NewTabSources.shared.omniboxBenchSnapshot(profileId: profileId),
          "catalogs": Dictionary(uniqueKeysWithValues: ["", "work"].map { engine in
            (engine, ["history": NativeHistoryCatalog.snapshot(engineProfile: engine), "bookmarks": NativeHistoryCatalog.bookmarksSnapshot(engineProfile: engine)])
          }),
        ])
      }
    }.runOnQueue(.main)

    AsyncFunction("setIdleTabs") { (json: String, epoch: Int, revision: Int) in
      guard let rows = OmniboxIdleTabSources.decode(json) else { return }
      await MainActor.run { NativeOmniboxSources.shared.setIdleTabs(rows, epoch: epoch, revision: revision) }
    }

    AsyncFunction("setTabs") { (profileId: String, json: String, epoch: Int) in
      let rows = NewTabRows.tabs(json)
      await MainActor.run { NativeOmniboxSources.shared.setTabs(rows, profileId: profileId, epoch: epoch) }
    }

    AsyncFunction("setEngineProfile") { (profileId: String, engineProfile: String, bookmarkEngineProfile: String, epoch: Int) in
      await MainActor.run { NativeOmniboxSources.shared.setEngineProfile(engineProfile, bookmarkEngineProfile: bookmarkEngineProfile, profileId: profileId, epoch: epoch) }
    }

    AsyncFunction("setBookmarkIcons") { (profileId: String, engineProfile: String, json: String) in
      let icons = NewTabRows.bookmarkIcons(json)
      await MainActor.run { NewTabSources.shared.setBookmarkIcons(icons, engineProfile: engineProfile, profileId: profileId) }
    }

    AsyncFunction("setActions") { (windowId: String, json: String) in
      let rows = NewTabRows.actions(json)
      await MainActor.run { NewTabSources.shared.setActions(rows, windowId: windowId) }
    }

    AsyncFunction("setExtensions") { (windowId: String, json: String) in
      let rows = NewTabRows.extensions(json)
      await MainActor.run { NewTabSources.shared.setExtensions(rows, windowId: windowId) }
    }

    AsyncFunction("forgetWindow") { (windowId: String) in
      await MainActor.run { NativeOmniboxSources.shared.forget(windowId: windowId) }
    }

    View(NativeNewTabView.self) {
      Events(NativeNewTabView.events)

      Prop("windowId") { (view: NativeNewTabView, v: String) in MainActor.assumeIsolated { view.windowId = v } }
      Prop("tabId") { (view: NativeNewTabView, v: String) in MainActor.assumeIsolated { view.tabId = v } }
      Prop("profileId") { (view: NativeNewTabView, v: String) in MainActor.assumeIsolated { view.profileId = v } }
      Prop("incognito") { (view: NativeNewTabView, v: Bool?) in MainActor.assumeIsolated { view.hero.incognito = v ?? false } }
      Prop("onboarding") { (view: NativeNewTabView, v: Bool?) in MainActor.assumeIsolated { view.hero.onboarding = v ?? false } }
      Prop("playIntro") { (view: NativeNewTabView, v: Bool?) in MainActor.assumeIsolated { view.hero.playIntro = v ?? false } }
      Prop("panelOpen") { (view: NativeNewTabView, v: Bool?) in MainActor.assumeIsolated { view.hero.panelOpen = v ?? false } }
      Prop("under") { (view: NativeNewTabView, v: Double?) in MainActor.assumeIsolated { view.hero.under = v ?? 0 } }
      Prop("dark") { (view: NativeNewTabView, v: Bool?) in MainActor.assumeIsolated { view.dark = v ?? false } }
      Prop("theme") { (view: NativeNewTabView, v: [String: String]?) in MainActor.assumeIsolated { view.themeTokens = v ?? [:] } }
      Prop("offline") { (view: NativeNewTabView, v: Bool?) in MainActor.assumeIsolated { view.hero.fetcher = v == true ? nil : NewTabNetwork.fetcher } }
      Prop("driven") { (view: NativeNewTabView, v: Bool?) in MainActor.assumeIsolated { view.driven = v ?? false } }
      Prop("marks") { (view: NativeNewTabView, v: [String: String]?) in MainActor.assumeIsolated { view.marks = v ?? [:] } }

      OnViewDidUpdateProps { (view: NativeNewTabView) in MainActor.assumeIsolated { view.propsDidUpdate() } }

      AsyncFunction("focus") { (view: NativeNewTabView) in MainActor.assumeIsolated { view.hero.focusBar() } }.runOnQueue(.main)

      AsyncFunction("applyMenu") { (view: NativeNewTabView, choice: String) in
        MainActor.assumeIsolated { if let c = HeroMenuChoice(rawValue: choice) { view.hero.model?.apply(c) } }
      }.runOnQueue(.main)

      AsyncFunction("type") { (view: NativeNewTabView, text: String) in
        MainActor.assumeIsolated { view.hero.model?.driverType(text) }
      }.runOnQueue(.main)

      AsyncFunction("clear") { (view: NativeNewTabView) in MainActor.assumeIsolated { view.hero.model?.reset() } }.runOnQueue(.main)

      AsyncFunction("key") { (view: NativeNewTabView, key: String, mods: [String: Bool]?) in
        MainActor.assumeIsolated { _ = view.hero.model?.driverKey(key, mods ?? [:]) }
      }.runOnQueue(.main)

      AsyncFunction("select") { (view: NativeNewTabView, start: Int, end: Int) in
        MainActor.assumeIsolated { view.hero.model?.selectionChanged(TextSelection(start: start, end: end)) }
      }.runOnQueue(.main)

      AsyncFunction("submit") { (view: NativeNewTabView) in MainActor.assumeIsolated { view.hero.model?.submit() } }.runOnQueue(.main)

      AsyncFunction("driverState") { (view: NativeNewTabView) -> String in
        MainActor.assumeIsolated { view.driverStateJSON() }
      }.runOnQueue(.main)

      AsyncFunction("measure") { (view: NativeNewTabView) -> [String: Double] in MainActor.assumeIsolated { view.measure() } }.runOnQueue(.main)
    }
  }
}

enum NewTabRows {
  private static func objects(_ json: String) -> [[String: Any]] {
    guard let data = json.data(using: .utf8), let list = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]] else { return [] }
    return list
  }

  private static func string(_ o: [String: Any], _ key: String) -> String { o[key] as? String ?? "" }

  private static func optional(_ o: [String: Any], _ key: String) -> String? { o[key] as? String }

  static func tabs(_ json: String) -> [TabRow] {
    objects(json).map { TabRow(id: string($0, "id"), url: string($0, "url"), title: string($0, "title"), favicon: optional($0, "favicon")) }
  }

  static func bookmarkIcons(_ json: String) -> [String: String] {
    guard let data = json.data(using: .utf8), let icons = try? JSONSerialization.jsonObject(with: data) as? [String: String] else { return [:] }
    return icons
  }

  static func actions(_ json: String) -> [CommandAction] {
    objects(json).map {
      CommandAction(id: string($0, "id"), title: string($0, "title"), keywords: $0["keywords"] as? [String], icon: optional($0, "icon"), hint: optional($0, "hint"))
    }
  }

  static func extensions(_ json: String) -> [ExtensionCandidate] {
    objects(json).map {
      ExtensionCandidate(id: string($0, "id"), title: string($0, "title"), icon: optional($0, "icon"), action: ($0["action"] as? Bool) ?? false, options: ($0["options"] as? Bool) ?? false)
    }
  }
}

#if SOLARA_PROBES
public enum NewTabRead {
  public static var available: Bool { NativeSettingsHandle.active }
}
#endif

private final class NewTabSourceEventSink: @unchecked Sendable {
  weak var module: NewTabModule?

  init(module: NewTabModule) { self.module = module }
}
