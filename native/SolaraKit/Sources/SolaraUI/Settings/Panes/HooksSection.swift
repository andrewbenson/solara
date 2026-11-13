import AppKit
import Observation
import SolaraModel
import SwiftUI

@MainActor
public protocol HooksServices: AnyObject {
  var hooksStatus: HooksStatus { get }
  func approvalSnapshot(_ digest: String) -> String?
  func approveHook(_ digest: String, snapshotHash: String) -> String?
  func revokeHook(_ digest: String)
  func forgetAppTeam(_ identifier: String)
  func revealHooksFile()
}

@MainActor
@Observable
public final class HooksSectionModel {
  public struct Confirmation: Equatable, Identifiable {
    public var id: String { digest }
    public let digest: String
    public let rule: HookRuleStatus
    public let snapshot: String
  }

  @ObservationIgnored public let services: HooksServices
  public var status: HooksStatus
  var confirming: Confirmation?
  var refusal: String?

  public init(services: HooksServices) {
    self.services = services
    status = services.hooksStatus
  }

  public func refresh() {
    status = services.hooksStatus
    if let confirming {
      let current = status.rules.first { $0.digest == confirming.digest }
      if current == nil || services.approvalSnapshot(confirming.digest) != confirming.snapshot { self.confirming = nil }
    }
  }

  func askToApprove(_ rule: HookRuleStatus) {
    refusal = nil
    guard let snapshot = services.approvalSnapshot(rule.digest) else { return }
    confirming = Confirmation(digest: rule.digest, rule: rule, snapshot: snapshot)
  }

  func confirm() {
    guard let confirming else { return }
    self.confirming = nil
    guard status.rules.contains(where: { $0.digest == confirming.digest }) else { return }
    refusal = services.approveHook(confirming.digest, snapshotHash: HookApprovals.snapshotHash(confirming.snapshot))
    refresh()
  }

  func revoke(_ rule: HookRuleStatus) {
    services.revokeHook(rule.digest)
    refresh()
  }

  public static func stateText(_ rule: HookRuleStatus) -> String { state(rule).0 }

  static func state(_ rule: HookRuleStatus) -> (String, Color) {
    if let problem = rule.problem { return ("Off: \(problem)", .red) }
    switch rule.approval {
    case .notNeeded: return (rule.dropped > 0 ? "On (\(rule.dropped) runs skipped)" : "On", .secondary)
    case .needed: return ("Waiting for approval", .orange)
    case .changed: return ("Changed since it was approved: waiting for approval", .orange)
    case .filesChanged(let why): return ("Off: \(why)", .red)
    case .approved: return (rule.dropped > 0 ? "Approved (\(rule.dropped) runs skipped)" : "Approved", .secondary)
    }
  }

  static func fileNote(_ status: HooksStatus) -> String {
    if !status.present { return "Add rules to \(display(status.path)) to block or rewrite pages, send links from an app to a profile, save downloads in a folder, deny camera or microphone, or run a program." }
    if let error = status.error {
      return status.rules.isEmpty ? "\(display(status.path)): \(error). No hooks are on." : "\(display(status.path)) has an error, so the last rules that loaded stay in use: \(error)"
    }
    let count = status.rules.count == 1 ? "1 hook from \(display(status.path))." : "\(status.rules.count) hooks from \(display(status.path))."
    let late = status.lateLoads > 0 ? " \(status.lateLoads == 1 ? "1 page" : "\(status.lateLoads) pages") opened before your rules loaded at launch, so hooks didn't check \(status.lateLoads == 1 ? "it" : "them")." : ""
    return (status.engine ? count : count + " Page rules need a newer engine; until then only links from other apps are covered.") + late
  }

  static func display(_ path: String) -> String {
    let home = NSHomeDirectory()
    return path.hasPrefix(home + "/") ? "~" + path.dropFirst(home.count) : path
  }
}

struct HooksSection: View {
  @Bindable var model: HooksSectionModel

  var body: some View {
    let status = model.status
    SettingsSection("Hooks") {
      SettingRow("advanced.hooks", description: .text(HooksSectionModel.fileNote(status))) {
        Button("Show in Finder") { model.services.revealHooksFile() }
      }
      if let refusal = model.refusal {
        Text(refusal).foregroundStyle(.red).textSelection(.enabled)
      }
      ForEach(status.appProblems, id: \.self) { problem in
        Text(problem).foregroundStyle(.red).textSelection(.enabled)
      }
      ForEach(status.appTeams) { app in
        HStack {
          Text("\(app.identifier): links count only when signed by \(app.team == HookSender.appleTeam ? "Apple" : "team " + app.team), like the installed app")
            .foregroundStyle(.secondary).textSelection(.enabled)
          Spacer()
          Button("Forget") {
            model.services.forgetAppTeam(app.identifier)
            model.refresh()
          }
          .accessibilityIdentifier("hook-forget-team-\(app.identifier)")
        }
      }
      ForEach(status.rules) { rule in
        HookRow(rule: rule, model: model)
      }
    }
    .onAppear { model.refresh() }
    .onReceive(NotificationCenter.default.publisher(for: HooksSectionModel.changed)) { _ in model.refresh() }
    .sheet(item: $model.confirming) { confirmation in
      HookApprovalSheet(confirmation: confirmation, model: model)
    }
  }
}

struct HookApprovalSheet: View {
  let confirmation: HooksSectionModel.Confirmation
  let model: HooksSectionModel

  var body: some View {
    let rule = confirmation.rule
    VStack(alignment: .leading, spacing: 12) {
      Text("Approve “\(HookText.escaped(rule.name))”?").font(.headline)
      Text("It reaches outside Solara. Read every line: this is exactly what will be allowed. Any edit to the hook, or to a file it runs, turns it off until you approve it again.")
        .fixedSize(horizontal: false, vertical: true)
      ForEach(rule.flags, id: \.self) { flag in
        Label(flag, systemImage: "exclamationmark.triangle.fill").foregroundStyle(.orange).fixedSize(horizontal: false, vertical: true)
      }
      if rule.argv != nil {
        Text("Only the files listed below are checked before each run. Anything else the command reads or runs can change without asking you again.")
          .foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
      }
      if case .changed(let previous) = rule.approval {
        Text("What changed since you approved it (- before, + now):").font(.subheadline)
        ScrollView {
          VStack(alignment: .leading, spacing: 0) {
            ForEach(Array(HookText.lineDiff(HookText.pretty(previous), HookText.pretty(rule.text)).enumerated()), id: \.offset) { _, line in
              Text(HookText.escaped(line)).font(.system(.body, design: .monospaced))
                .foregroundStyle(line.hasPrefix("+ ") ? Color.green : line.hasPrefix("- ") ? Color.red : Color.secondary)
            }
          }
          .textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading)
        }
        .frame(maxHeight: 160)
        Text("Now:").font(.subheadline)
      }
      ScrollView {
        Text(confirmation.snapshot).font(.system(.body, design: .monospaced)).textSelection(.enabled)
          .frame(maxWidth: .infinity, alignment: .leading).fixedSize(horizontal: false, vertical: true)
      }
      .frame(minHeight: 120, maxHeight: 320)
      HStack {
        Spacer()
        Button("Cancel", role: .cancel) { model.confirming = nil }.keyboardShortcut(.cancelAction)
        Button("Approve") { model.confirm() }
      }
    }
    .padding(20)
    .frame(width: 560)
    .accessibilityIdentifier("hook-approval-\(rule.name)")
  }
}

extension HooksSectionModel {
  public static let changed = Notification.Name("SolaraHooksChanged")
}

struct HookRow: View {
  let rule: HookRuleStatus
  let model: HooksSectionModel

  var body: some View {
    let (state, color) = HooksSectionModel.state(rule)
    LabeledContent {
      if rule.needsApproval && rule.problem == nil {
        if rule.approval == .approved {
          Button("Revoke") { model.revoke(rule) }
        } else {
          Button("Approve…") { model.askToApprove(rule) }
        }
      }
    } label: {
      Text(HookText.escaped(rule.name))
      Text(rule.summary).foregroundStyle(.secondary).textSelection(.enabled)
      Text(rule.detail).foregroundStyle(.secondary).textSelection(.enabled)
      Text(state).foregroundStyle(color)
    }
    .accessibilityIdentifier("hook-\(rule.name)")
  }
}
