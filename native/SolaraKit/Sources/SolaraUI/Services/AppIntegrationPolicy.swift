import SolaraStore

public enum AppIntegrationReadiness: Equatable, Sendable {
  case waiting
  case unavailable
  case ready
}

public enum AppIntegrationStoreStatus: Equatable, Sendable {
  case opening
  case failed(String)
  case notOwned
  case ready

  public var unavailableReason: String? {
    switch self {
    case .opening: "still opening"
    case .failed(let reason): "failed to open: \(reason)"
    case .notOwned: "not owned because settingsAndDownloads is scoped off"
    case .ready: nil
    }
  }
}

public enum AppIntegrationMenuAction: String, CaseIterable, Sendable {
  case sendFeedback
  case copyDiagnostics
  case recordPerformanceIssue
  case taskManager
  case reportBug
}

public enum AppIntegrationPolicy {
  public static func performMenuCommand(
    _ command: String, storeStatus: AppIntegrationStoreStatus, handler: (AppIntegrationMenuAction, AppIntegrationStoreStatus) -> Void
  ) -> Bool {
    guard let action = AppIntegrationMenuAction(rawValue: command) else { return false }
    handler(action, storeStatus)
    return true
  }

  public static func storeStatus(opened: Bool, ownsWorkspace: Bool, storeAvailable: Bool, failureReason: String?) -> AppIntegrationStoreStatus {
    if let failureReason { return .failed(failureReason) }
    guard opened else { return .opening }
    guard ownsWorkspace else { return .notOwned }
    return storeAvailable ? .ready : .opening
  }

  public static func readiness(opened: Bool, ownsWorkspace: Bool, storeAvailable: Bool) -> AppIntegrationReadiness {
    readiness(storeStatus: storeStatus(opened: opened, ownsWorkspace: ownsWorkspace, storeAvailable: storeAvailable, failureReason: nil))
  }

  public static func readiness(storeStatus: AppIntegrationStoreStatus) -> AppIntegrationReadiness {
    switch storeStatus {
    case .opening: .waiting
    case .failed, .notOwned: .unavailable
    case .ready: .ready
    }
  }

  public static func scriptError(storeStatus: AppIntegrationStoreStatus, handlerAvailable: Bool, productName: String) -> String? {
    if let reason = storeStatus.unavailableReason { return "\(productName) isn't ready yet: store: not open; \(reason)." }
    return handlerAvailable ? nil : "\(productName) isn't ready yet."
  }

  public static func handoffNeedsUpdate(_ changes: ChangeSet) -> Bool {
    !changes.tabs.isEmpty || !changes.windows.isEmpty
  }
}
