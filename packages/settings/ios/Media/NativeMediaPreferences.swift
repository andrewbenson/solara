import SolaraCore
import SolaraStore
import SolaraUI

@MainActor
enum NativeMediaPreferences {
  private static var lifecycle: Int?
  private static var observed: Store?
  private static var subscription: Int?
  private static let preferences = MediaPreferences(
    autoPictureInPicture: { SolaraCoreWebView.setAutoPictureInPictureEnabled($0) },
    videoUpscaling: { SolaraCoreWebView.setVideoUpscalingEnabled($0) })

  static func start() {
    guard lifecycle == nil else { return }
    lifecycle = NativeStoreHandle.subscribeLifecycle { reconcile() }
  }

  private static func reconcile() {
    let store = NativeStoreHandle.ownsWorkspace ? NativeStoreHandle.store : nil
    if observed !== store {
      if let observed, let subscription { observed.unsubscribe(subscription) }
      observed = store
      subscription = nil
      preferences.invalidate()
      if let store {
        SolaraCoreWebView.setDisplayMediaPicker(true)
        subscription = store.subscribe { _ in
          Task { @MainActor in sync() }
        }
      }
    }
    sync()
  }

  private static func sync() {
    guard SolaraCoreHost.isStarted, NativeStoreHandle.ownsWorkspace, let store = observed, NativeStoreHandle.store === store else { return }
    let settings = store.state.settings
    preferences.update(autoPictureInPicture: settings["autoPictureInPicture"]?.bool,
      videoUpscaling: settings["videoUpscaling"]?.bool)
  }
}
