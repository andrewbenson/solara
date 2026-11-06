import Foundation

@MainActor
public enum TabSleepPermissionFeed {
  public static let changed = Notification.Name("SolaraTabSleepPermissionFeedChanged")
  public static var pending: (@MainActor (String) -> Bool?)? { didSet { NotificationCenter.default.post(name: changed, object: nil) } }
  public static var coversPages: (@MainActor () -> Bool)? { didSet { NotificationCenter.default.post(name: changed, object: nil) } }
  public static var servesPages: Bool { pending != nil && coversPages?() == true }
}
