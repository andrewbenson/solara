@MainActor
public enum TabSleepPermissionFeed {
  public static var pending: (@MainActor (String) -> Bool?)?
}
