import Foundation

@MainActor
final class AdoptionProbe {
  var failures: [String] = []
  let json = #"[{"id":"chrome","name":"Chrome","family":"chromium","profiles":[]}]"#

  func expect(_ condition: Bool, _ message: String) {
    if !condition { failures.append(message) }
    print((condition ? "ok   " : "FAIL ") + message)
  }

  func bridge(_ reply: ((SettingsJS, Int) -> Void)?) -> (SettingsJS, () -> [String]) {
    let js = SettingsJS()
    var names: [String] = []
    js.send = { id, name, _ in
      names.append(name)
      guard let reply else { return }
      DispatchQueue.main.async { MainActor.assumeIsolated { reply(js, id) } }
    }
    return (js, { names })
  }

  func run() async {
    let (accepting, acceptingNames) = bridge { js, id in js.reply(id, resultJSON: "true", error: nil) }
    let accepted = await accepting.adoptBrowsers(json, deadline: 2)
    expect(acceptingNames() == ["import.adoptBrowsers"], "adopt calls import.adoptBrowsers once")
    expect(accepted?.first?["id"] as? String == "chrome", "a true reply returns the adopted list")

    let (refusing, _) = bridge { js, id in js.reply(id, resultJSON: "false", error: nil) }
    let refused = await refusing.adoptBrowsers(json, deadline: 2)
    expect(refused == nil, "a false reply returns nil")

    let (failing, _) = bridge { js, id in js.reply(id, resultJSON: nil, error: "boom") }
    let failed = await failing.adoptBrowsers(json, deadline: 2)
    expect(failed == nil, "an error reply returns nil")

    let (stalled, _) = bridge(nil)
    let started = Date()
    let timedOut = await stalled.adoptBrowsers(json, deadline: 0.3)
    let elapsed = Date().timeIntervalSince(started)
    expect(timedOut == nil, "a JS that never replies returns nil")
    expect(elapsed >= 0.25 && elapsed < 2, "the stalled adopt returns at its deadline (\(String(format: "%.2f", elapsed)) s)")

    let unconnected = SettingsJS()
    let unheard = await unconnected.adoptBrowsers(json, deadline: 2)
    expect(unheard == nil, "JS not listening returns nil")
  }
}

@main
@MainActor
struct ImportAdoptTests {
  static func main() async {
    let probe = AdoptionProbe()
    await probe.run()
    let failures = probe.failures
    exit(failures.isEmpty ? 0 : 1)
  }
}
