import AppKit
import Foundation
import SolaraModel
import SolaraShell

@MainActor
enum NativeConfigNotifier {
  static let notificationId = "solara.config-problems"
  private static var token: NSObjectProtocol?
  private(set) static var posted: [String] = []

  static func install() {
    guard token == nil else { return }
    token = NotificationCenter.default.addObserver(forName: ConfigProblems.changed, object: ConfigProblems.shared, queue: nil) { note in
      let added = note.userInfo?[ConfigProblems.addedKey] as? [ConfigProblem] ?? []
      DispatchQueue.main.async { MainActor.assumeIsolated { announce(added) } }
    }
    announce(ConfigProblems.shared.all)
  }

  static func announce(_ added: [ConfigProblem]) {
    guard let first = added.first else {
      if ConfigProblems.shared.all.isEmpty { ShellLiveNotifications.remove(ids: [notificationId]) }
      return
    }
    let location = ConfigDirectory.shared?.location
    let file = location?.display(first.file) ?? first.file
    let more = added.count > 1 ? " (and \(added.count - 1) more)" : ""
    let body = first.summary(in: location) + more + ". Solara keeps the last config that worked; details are in Settings."
    let title = "Solara couldn't use \(file)"
    posted.append(title + " — " + body)
    if posted.count > 32 { posted.removeFirst(posted.count - 32) }
    Task { _ = await ShellLiveNotifications.post(id: notificationId, title: title, body: body, data: ["kind": "configProblems"]) }
  }
}
