import SwiftUI

public struct OnboardingRecoveryPhraseView: View {
  @State private var model: SyncPaneModel
  private let folder: String?
  private let onCancel: () -> Void
  private let onConnected: () -> Void

  public init(services: SyncServices, folder: String?, onCancel: @escaping () -> Void, onConnected: @escaping () -> Void) {
    _model = State(initialValue: SyncPaneModel(services: services))
    self.folder = folder
    self.onCancel = onCancel
    self.onConnected = onConnected
  }

  public var body: some View {
    SyncPhraseSheet(model: model, canChangeFolder: true, onConnected: onConnected, onCancel: onCancel)
      .task { await model.reloadInfo(path: folder) }
  }
}
