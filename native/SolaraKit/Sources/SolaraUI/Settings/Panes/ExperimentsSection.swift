import AppKit
import Observation
import SolaraModel
import SwiftUI

@MainActor
@Observable
public final class ExperimentsModel {
  @ObservationIgnored let running: LaunchSwitches
  @ObservationIgnored let stored: StoredLaunchSwitches
  var revision = 0
  var revealed = false

  public init(running: LaunchSwitches = .shared, stored: StoredLaunchSwitches? = nil) {
    self.running = running
    self.stored = stored ?? StoredLaunchSwitches(running)
  }

  static let titles: [LaunchSwitch: (title: String, detail: String)] = [
    .nativeShell: ("Native window", "The window's frame, page card and overlays, drawn by Solara's Swift interface."),
    .shellPanes: ("Native page overlays", "Each tab's overlays get their own place in the native window."),
    .nativeTopStrip: ("Native tab strip", "The tab strip at the top of the window."),
    .nativeSidePanel: ("Native side panel", "An extension's side panel, beside the page."),
  ]

  struct Row: Identifiable, Equatable {
    var id: LaunchSwitch { name }
    let name: LaunchSwitch
    let title: String
    let detail: String
    let needs: String?
    let waiting: String?
    let on: Bool
    let enabled: Bool
    let fromEnvironment: Bool
  }

  func reveal(optionHeld: Bool) {
    revealed = revealed || optionHeld || stored.any || running.safeMode
      || LaunchSwitch.experiments.contains(where: running.fromEnvironment)
  }

  func requested(_ name: LaunchSwitch) -> Bool {
    _ = revision
    let byDefault = LaunchSwitch.onByDefault.contains(name)
    if running.fromEnvironment(name) { return running.requested(name, defaultOn: byDefault) }
    return running.distribution ? byDefault : stored.value(name) ?? byDefault
  }

  func next(_ name: LaunchSwitch) -> Bool {
    requested(name) && name.needs.allSatisfy(next)
  }

  var rows: [Row] {
    LaunchSwitch.experiments.map { name in
      let text = Self.titles[name] ?? (name.rawValue, "")
      let needs = name.needs.compactMap { Self.titles[$0]?.title }
      let unmet = name.needs.filter { !next($0) }.compactMap { Self.titles[$0]?.title }
      let fromEnvironment = running.fromEnvironment(name)
      return Row(
        name: name, title: text.title, detail: text.detail,
        needs: needs.isEmpty ? nil : "Needs \(needs.joined(separator: " and ")).",
        waiting: requested(name) && !unmet.isEmpty ? "Off until \(unmet.joined(separator: " and ")) is on." : nil,
        on: next(name),
        enabled: !fromEnvironment && stored.writable && name.storable(distribution: running.distribution) && name.needs.allSatisfy(next),
        fromEnvironment: fromEnvironment)
    }
  }

  var pendingRelaunch: Bool {
    LaunchSwitch.experiments.contains { next($0) != running.isOn($0) }
  }

  func set(_ name: LaunchSwitch, _ on: Bool) {
    stored.set(name, on == LaunchSwitch.onByDefault.contains(name) ? nil : on)
    revision += 1
  }

  func turnAllOff() {
    stored.clear()
    revision += 1
  }

  var note: String {
    if running.safeMode { return "This launch is in safe mode. The saved session will return on the next normal launch; extensions are off for this launch." }
    if !stored.writable { return "This instance has its own data folder, so only its environment sets these." }
    return "These turn on parts of Solara that are still being built. Changes apply the next time Solara opens."
  }

}

struct ExperimentsSection: View {
  let model: ExperimentsModel

  var body: some View {
    Section {
      ForEach(model.rows) { row in
        LabeledContent {
          Toggle("", isOn: Binding(get: { row.on }, set: { model.set(row.name, $0) }))
            .labelsHidden()
            .toggleStyle(.settingsSwitch)
            .disabled(!row.enabled)
        } label: {
          Text(row.title)
          Text([row.detail, row.waiting ?? row.needs, row.fromEnvironment ? "Set by the environment." : nil].compactMap { $0 }.joined(separator: " "))
            .foregroundStyle(.secondary)
        }
        .opacity(row.enabled || row.fromEnvironment ? 1 : 0.5)
      }
      if model.pendingRelaunch {
        Text("Relaunch Solara to apply.")
          .foregroundStyle(.secondary)
      }
    } header: {
      SettingsSectionHeader("Experimental", description: model.note) {
        if model.stored.writable && model.stored.any {
          Button("Turn All Off") { model.turnAllOff() }
        }
      }
    }
  }
}
