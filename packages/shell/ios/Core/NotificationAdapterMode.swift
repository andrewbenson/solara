public enum NotificationAdapterMode: Equatable {
  case memory
  case system

  public static func choose(environment: [String: String], debug: Bool) -> NotificationAdapterMode {
    #if DEBUG
    if debug && environment["SOLARA_NOTIFICATIONS_SYSTEM"] == "1" { return .system }
    #endif
    return environment["SOLARA_BACKGROUND"] == "1" ? .memory : .system
  }
}
