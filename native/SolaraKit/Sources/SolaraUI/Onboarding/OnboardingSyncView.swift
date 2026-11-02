import SwiftUI

struct OnboardingSyncView: View {
  let model: OnboardingModel
  @State private var folderTask: Task<Void, Never>?

  var body: some View {
    ScrollView {
      VStack(alignment: .leading, spacing: 20) {
        Text(model.syncTitle)
          .font(OnboardingFont.system(28, 500))
        if !model.syncMessage.isEmpty {
          Text(model.syncMessage)
            .font(OnboardingFont.system(14, 400))
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
        }
        content
      }
      .frame(maxWidth: 560, alignment: .leading)
      .padding(44)
      .frame(maxWidth: .infinity, alignment: .center)
    }
    .onDisappear { folderTask?.cancel() }
  }

  @ViewBuilder
  private var content: some View {
    switch model.syncRoute {
    case .discovering:
      ProgressView().controlSize(.small)
      Button("Cancel") { model.leaveSetup() }
    case .found:
      found
    case .discoveryIssue(let result):
      if result == .unavailable || result == .permissionDenied {
        Button("Open iCloud Settings…") { model.services.openOnboardingICloudSettings() }
      }
      Button("Try Again") { model.discoverSync() }
      chooseFolder
      Button("Enter Recovery Phrase…") { model.useRecoveryPhrase() }
      Button("Continue Setup") { model.continueSetup() }
    case .setupIssue:
      Button("Try Again") { model.retrySetupTransition() }
      Button("Continue Setup") { model.continueSetup() }
    case .joining(let state):
      joining(state)
    case .downloading:
      VStack(alignment: .leading, spacing: 14) {
        ProgressView().controlSize(.small)
        Button("Keep Waiting") { model.keepWaitingForSync() }
        Button("Continue to Browser") { model.finishJoined() }
          .buttonStyle(.borderedProminent)
      }
    case .joined:
      Image(systemName: "checkmark.circle.fill").font(.system(size: 36)).foregroundStyle(.green)
      Button("Continue to Browser") { model.finishJoined() }
        .buttonStyle(.borderedProminent)
    case .savingFailed:
      Button("Try Again") { model.finishJoined() }
    case .setup:
      EmptyView()
    }
  }

  private var found: some View {
    VStack(alignment: .leading, spacing: 14) {
      if model.candidates.count > 1 {
        Text("We can't identify these until you connect.")
          .foregroundStyle(.secondary)
      }
      ForEach(Array(model.candidates.enumerated()), id: \.element.cid) { index, candidate in
        Button { model.selectSync(cid: candidate.cid) } label: {
          HStack(spacing: 12) {
            Image(systemName: model.selectedCID == candidate.cid ? "largecircle.fill.circle" : "circle")
            VStack(alignment: .leading, spacing: 4) {
              Text("Sync \(index + 1)")
              if let activity = candidate.lastActivity {
                Text("Last activity seen \(activity.formatted(date: .abbreviated, time: .shortened))")
                  .font(.caption).foregroundStyle(.secondary)
              } else {
                Text("Activity time unavailable").font(.caption).foregroundStyle(.secondary)
              }
              Text("Unverified").font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
          }
          .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
      }
      Button("Pair With Another Mac") { model.pairWithAnotherMac() }
        .buttonStyle(.borderedProminent)
        .disabled(model.selectedCID == nil)
      Button("Enter Recovery Phrase…") { model.useRecoveryPhrase() }
      DisclosureGroup("Other Options") {
        Button("Set Up This Mac Separately…") { model.continueSetup() }
          .padding(.top, 8)
      }
    }
  }

  @ViewBuilder
  private func joining(_ state: PairingJoinState) -> some View {
    if let folder = model.services.onboardingSyncFolder {
      Label(folder, systemImage: "folder")
        .font(.caption).foregroundStyle(.secondary)
        .textSelection(.disabled)
    }
    Text("New Mac").font(.caption).foregroundStyle(.secondary)
    if case .comparing = state, let code = model.syncCode {
      Text(code)
        .font(.system(size: 44, weight: .semibold, design: .monospaced))
        .textSelection(.disabled)
      Text("Name the other Mac claims")
        .font(.caption).foregroundStyle(.secondary)
      Text(model.claimedSyncName)
        .fixedSize(horizontal: false, vertical: true)
      Text("Unverified until the codes match")
        .font(.caption).foregroundStyle(.secondary)
    } else {
      Text("Trusted Mac").foregroundStyle(.secondary)
    }
    TimelineView(.periodic(from: .now, by: 1)) { _ in
      if let seconds = model.pairingRemainingSeconds {
        Text("\(seconds / 60):\(String(format: "%02d", seconds % 60)) remaining")
          .monospacedDigit().foregroundStyle(.secondary)
      }
    }
    switch state {
    case .failed(let failure):
      if failure == .folderUnavailable { chooseFolder }
      Button("Start Again") { model.startPairingAgain() }
        .buttonStyle(.borderedProminent)
      Button("Use Recovery Phrase Instead…") { model.useRecoveryPhrase() }
      Button("Cancel") { model.cancelPairing() }
    case .approved:
      ProgressView().controlSize(.small)
    case .installed:
      Button("Continue to Browser") { model.finishJoined() }
    default:
      ProgressView().controlSize(.small)
      Button("Cancel") { model.cancelPairing() }
      Button("Use Recovery Phrase Instead…") { model.useRecoveryPhrase() }
    }
  }

  private var chooseFolder: some View {
    Button("Choose Folder…") {
      folderTask?.cancel()
      folderTask = Task { await model.chooseSyncFolder() }
    }
  }
}

public extension OnboardingModel {
  func chooseSyncFolder() async {
    guard isActive, canLeavePairing else { return }
    let activeSession = session
    if await services.chooseOnboardingFolder(beforeChange: {
      guard !Task.isCancelled, isActive, session == activeSession, canLeavePairing else { return false }
      cancelPairing()
      return canLeavePairing
    }), !Task.isCancelled, isActive, session == activeSession {
      discoverSync()
    }
  }
}
