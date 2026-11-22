import Foundation

@MainActor public protocol PictureInPictureControlling: AnyObject {
  var tabID: String? { get }
  func enter(tabID: String) async -> Bool
  func minimize()
}

public enum PictureInPictureHolder {
  public static let didChange = Notification.Name("SolaraPictureInPictureChanged")
}

@MainActor public enum MediaStackPiP {
  public static var center: (any PictureInPictureControlling)?
}
