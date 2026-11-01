import SolaraCore
import SolaraShell
import ExpoModulesCore

public class TabPoolModule: Module {
  public func definition() -> ModuleDefinition {
    Name("SolaraTabPool")
    Events("onPageEvent", "onPlaced")

    OnCreate {
      let sink = TabPoolSink(self)
      DispatchQueue.main.async {
        MainActor.assumeIsolated {
          TabPoolHost.shared.emit = { name, body in sink.module?.sendEvent(name, body) }
          TabPoolHost.shared.onPageGone = { tabId in PendingPageCalls.shared.rejectAll(tabId) }
          TabPoolHost.shared.start()
        }
      }
    }

    Function("available") { () -> Bool in TabPoolHost.available }

    AsyncFunction("pageCall") { (tabId: String, method: String, args: [Any], promise: Promise) in
      nonisolated(unsafe) let reply = promise
      nonisolated(unsafe) let values = args
      MainActor.assumeIsolated {
        guard let page = TabPoolHost.shared.pageView(tabId) else {
          return reply.reject("ERR_NO_PAGE", "no pooled page for tab \(tabId)")
        }
        let pending = PendingPageCalls.shared
        let id = pending.add(tabId, reply)
        PageCalls.run(page, method, values, resolve: { pending.take(tabId, id)?.resolve($0) }, reject: { pending.take(tabId, id)?.reject($0, $1) })
      }
    }.runOnQueue(.main)

    AsyncFunction("claimFocusPage") { (generation: Int, tabId: String) -> Bool in
      MainActor.assumeIsolated {
        guard let page = TabPoolHost.shared.pageView(tabId) else { return false }
        FocusMoves.claim(generation, destination: page)
        return true
      }
    }.runOnQueue(.main)

    AsyncFunction("setPageProps") { (tabId: String, props: [String: Any]) in
      nonisolated(unsafe) let changed = props
      MainActor.assumeIsolated { TabPoolHost.shared.setPageProps(tabId, changed) }
    }.runOnQueue(.main)

    AsyncFunction("livePages") { (promise: Promise) in
      nonisolated(unsafe) let reply = promise
      MainActor.assumeIsolated { reply.resolve(TabPoolHost.shared.livePages()) }
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

@MainActor
final class PendingPageCalls {
  static let shared = PendingPageCalls()
  private var next = 0
  private var calls: [String: [Int: Promise]] = [:]

  func add(_ tabId: String, _ promise: Promise) -> Int {
    next += 1
    calls[tabId, default: [:]][next] = promise
    return next
  }

  func take(_ tabId: String, _ id: Int) -> Promise? {
    let promise = calls[tabId]?.removeValue(forKey: id)
    if calls[tabId]?.isEmpty == true { calls[tabId] = nil }
    return promise
  }

  func rejectAll(_ tabId: String) {
    guard let gone = calls.removeValue(forKey: tabId) else { return }
    for promise in gone.values { promise.reject("ERR_NO_PAGE", "the pooled page for tab \(tabId) went away") }
  }
}

private final class TabPoolSink: @unchecked Sendable {
  weak var module: TabPoolModule?
  init(_ module: TabPoolModule) { self.module = module }
}
