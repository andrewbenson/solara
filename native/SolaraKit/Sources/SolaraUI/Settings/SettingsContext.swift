import Foundation
import Observation
import SwiftUI

@MainActor
public protocol SettingsPaneProvider: AnyObject {
  func isLoaded(_ place: SettingsPlace) -> Bool
  func prepare(_ place: SettingsPlace) async
  func view(_ place: SettingsPlace) -> AnyView
}

@MainActor
@Observable
public final class SettingsContext {
  public static let holdCap: Duration = .milliseconds(250)

  public let appName: String
  public let liquidGlass: Bool
  public let index: SettingsIndex
  public let navigation: SettingsNavigation
  public let search: SettingsSearchModel
  @ObservationIgnored public let store: SettingsStoreSource
  @ObservationIgnored public var panes: [SettingsPane: SettingsPaneProvider] = [:]
  @ObservationIgnored public var profileForPane: (SettingsPane, SettingsPlace) -> String? = { _, _ in nil }
  @ObservationIgnored public var onPaneChange: (SettingsPane) -> Void = { _ in }
  @ObservationIgnored public var onPaneAppear: (SettingsPlace) -> Void = { _ in }
  @ObservationIgnored public var favicons: SettingsFavicons?
  @ObservationIgnored public var anchorFrames: [String: CGRect] = [:]
  @ObservationIgnored public var viewport: CGRect = .zero
  public private(set) var shown: SettingsPlace?
  @ObservationIgnored private var showing: Task<Void, Never>?
  @ObservationIgnored private var prefetched = false

  public init(appName: String, liquidGlass: Bool, store: SettingsStoreSource, navigation: SettingsNavigation = SettingsNavigation()) {
    self.appName = appName
    self.liquidGlass = liquidGlass
    self.store = store
    self.navigation = navigation
    index = SettingsIndex(appName: appName)
    search = SettingsSearchModel(index: index, liquidGlass: liquidGlass)
    navigation.willNavigate = { [weak self] old, next in
      if old.pane == .sync && old != next { (self?.panes[.sync] as? SyncPaneModel)?.pairingSurfaceRemoved() }
      if next.pane == .sync && old != next { (self?.panes[.sync] as? SyncPaneModel)?.pairing?.resumeObservation() }
    }
  }

  public func title(for place: SettingsPlace) -> String {
    if place.pane == .profiles, let id = place.profileId, let profile = store.profiles.first(where: { $0.id == id }) {
      return profile.name
    }
    return place.pane.title
  }

  public func goToPane(_ pane: SettingsPane) {
    navigation.go(pane, profileId: profileForPane(pane, navigation.place))
  }

  public func reveal(_ id: String) {
    search.revealSetting(id, navigation: navigation, profileFor: profileForPane)
  }

  public func submitSearch() {
    search.submit(navigation: navigation, profileFor: profileForPane)
  }

  public func syncShown() {
    let target = navigation.place
    if shown == target { return }
    showing?.cancel()
    guard let provider = panes[target.pane] else {
      show(target)
      return
    }
    if provider.isLoaded(target) {
      show(target)
      return
    }
    Task { [weak self] in
      await provider.prepare(target)
      self?.showIfCurrent(target)
    }
    showing = Task { [weak self] in
      try? await Task.sleep(for: SettingsContext.holdCap)
      guard !Task.isCancelled else { return }
      self?.showIfCurrent(target)
    }
  }

  private func showIfCurrent(_ target: SettingsPlace) {
    guard navigation.place == target, shown != target else { return }
    show(target)
  }

  private func show(_ place: SettingsPlace) {
    shown = place
    prefetchAll()
  }

  private func prefetchAll() {
    guard !prefetched else { return }
    prefetched = true
    for pane in SettingsPane.allCases {
      guard let provider = panes[pane] else { continue }
      let place = SettingsPlace(pane: pane)
      Task { await provider.prepare(place) }
    }
  }
}

private struct SettingsContextKey: EnvironmentKey {
  static let defaultValue: SettingsContext? = nil
}

public extension EnvironmentValues {
  var settingsContext: SettingsContext? {
    get { self[SettingsContextKey.self] }
    set { self[SettingsContextKey.self] = newValue }
  }
}
