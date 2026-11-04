import SolaraCore
import SolaraShell
import SolaraUI
import ExpoModulesCore

public class TabPoolModule: Module {
  public func definition() -> ModuleDefinition {
    Name("SolaraTabPool")
    Events("onPageEvent", "onPlaced")

    OnCreate {
      let sink = TabPoolSink(self)
      DispatchQueue.main.async {
        MainActor.assumeIsolated {
          guard let context = sink.module?.appContext else { return }
          let runtimeID = PageIssuer.runtimeID(for: context)
          TabPoolHost.shared.emit = { name, body in
            guard let module = sink.module, module.appContext?._runtime != nil else { return nil }
            module.sendEvent(name, body)
            return runtimeID
          }
          TabPoolHost.shared.start()
        }
      }
    }

    Function("available") { () -> Bool in TabPoolHost.available }

    AsyncFunction("pageCall") { (tabId: String, method: String, args: [Any], registrationGeneration: Double?, promise: Promise) in
      nonisolated(unsafe) let reply = promise
      nonisolated(unsafe) let values = args
      MainActor.assumeIsolated {
        TabPoolHost.shared.pageCall(tabId, method, values, registrationGeneration: registrationGeneration, resolve: { reply.resolve($0) }, reject: { reply.reject($0, $1) })
      }
    }.runOnQueue(.main)

    AsyncFunction("claimFocusPage") { (generation: Int, tabId: String) -> Bool in
      MainActor.assumeIsolated {
        TabPoolHost.shared.claimFocusPage(generation, tabId: tabId)
      }
    }.runOnQueue(.main)

    AsyncFunction("setPageProps") { (tabId: String, props: [String: Any]) in
      nonisolated(unsafe) let changed = props
      MainActor.assumeIsolated { TabPoolHost.shared.setPageProps(tabId, changed) }
    }.runOnQueue(.main)

    AsyncFunction("livePages") { (promise: Promise) in
      nonisolated(unsafe) let reply = promise
      let sink = TabPoolSink(self)
      MainActor.assumeIsolated {
        let runtimeID = sink.module?.appContext.map { PageIssuer.runtimeID(for: $0) }
        reply.resolve(TabPoolHost.shared.livePages(runtimeID: runtimeID))
      }
    }.runOnQueue(.main)

    AsyncFunction("devPageIds") { () -> [String] in
      MainActor.assumeIsolated { TabPoolHost.shared.devPageIds() }
    }.runOnQueue(.main)

    AsyncFunction("devClosingWindows") { () -> [String: Int] in
      MainActor.assumeIsolated { TabPoolHost.shared.devClosingWindows() }
    }.runOnQueue(.main)

    AsyncFunction("devPageEvent") { (tabId: String, name: String, payload: [String: Any]) -> Bool in
      nonisolated(unsafe) let body = payload
      return MainActor.assumeIsolated { TabPoolHost.shared.devPageEvent(tabId, name, body) }
    }.runOnQueue(.main)
  }
}

private final class TabPoolSink: @unchecked Sendable {
  weak var module: TabPoolModule?
  init(_ module: TabPoolModule) { self.module = module }
}
