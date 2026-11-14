import AppKit
import Observation
import SolaraModel
import SolaraOmnibox
import SwiftUI

public struct OmniboxBarIdentity: Equatable, Sendable {
  public var windowId: String
  public var tabId: String
  public var profileId: String
  public var variant: BarVariant
  public var opensTab: Bool
  public var initialText: String

  public init(windowId: String, tabId: String, profileId: String, variant: BarVariant, opensTab: Bool, initialText: String) {
    self.windowId = windowId
    self.tabId = tabId
    self.profileId = profileId
    self.variant = variant
    self.opensTab = opensTab
    self.initialText = initialText
  }
}

@MainActor
public final class OmniboxBarView: NSView {
  public var events = HeroBarEvents() { didSet { model?.events = events } }
  public var onHeight: (CGFloat) -> Void = { _ in }
  public var settings: () -> SolaraModel.Settings = { SolaraModel.Settings(values: [:]) }
  public var fetcher: SuggestFetcher? { didSet { if fetcher !== oldValue { model?.setFetcher(fetcher) } } }
  public var bangStore: BangStore?
  public var favicons: NewTabFavicons? { didSet { rebuild() } }
  public var theme = NewTabTheme.fallbackLight { didSet { if theme != oldValue { rebuild() } } }
  public var incognito = false { didSet { model?.incognito = incognito } }
  public var floating = false { didSet { if floating != oldValue { rebuild() } } }
  public var currentUrl = "" { didSet { if let model, !model.opensTab { model.currentUrl = currentUrl } } }

  public private(set) var model: HeroBarModel?
  private var identity: OmniboxBarIdentity?
  private var content: NSHostingView<AnyView>?
  private var height: CGFloat = 0
  private var watching = false
  private var focusedOnce = false

  public override var isFlipped: Bool { true }

  public override init(frame: NSRect) {
    super.init(frame: frame)
  }

  required init?(coder: NSCoder) { fatalError() }

  public var activatesOnWindow = true

  public func configure(_ next: OmniboxBarIdentity, fresh: Bool = false) {
    guard identity != next || fresh else { return }
    model?.invalidateQueryProbe()
    identity = next
    let made = HeroBarModel(
      windowId: next.windowId, tabId: next.tabId, profileId: next.profileId, incognito: incognito,
      settings: { [weak self] in self?.settings() ?? SolaraModel.Settings(values: [:]) }, fetcher: fetcher, bangStore: bangStore, variant: next.variant,
      opensTab: next.opensTab, initialText: next.initialText, currentUrl: currentUrl)
    made.events = events
    model = made
    focusedOnce = false
    rebuild()
    watchSources()
    if window != nil && activatesOnWindow { focusSoon() }
  }

  public func activate() {
    model?.mounted()
    focusSoon()
  }

  public func focusBar() {
    model?.focusSelectingAll()
  }

  public override func viewWillMove(toWindow newWindow: NSWindow?) {
    if newWindow == nil { model?.invalidateQueryProbe() }
    if newWindow == nil, let window, model?.field?.hasFocus == true {
      NotificationCenter.default.post(name: Notification.Name("SolaraBarRemovedWithFocus"), object: window)
    }
    super.viewWillMove(toWindow: newWindow)
  }

  public override func viewDidMoveToWindow() {
    super.viewDidMoveToWindow()
    guard window != nil, activatesOnWindow else { return }
    model?.mounted()
    focusSoon()
  }

  private func focusSoon() {
    DispatchQueue.main.async { [weak self] in
      guard let self, self.window != nil, !self.focusedOnce else { return }
      self.focusedOnce = true
      self.layoutSubtreeIfNeeded()
      self.model?.focusOnce()
    }
  }

  public override func layout() {
    super.layout()
    content?.frame = bounds
  }

  private func rebuild() {
    guard let model else { return }
    let env = NewTabEnvironment(theme: theme, favicons: favicons, profileId: identity?.profileId ?? "")
    let view = AnyView(OmniboxBarContent(model: model, floating: floating) { [weak self] h in self?.setHeight(h) }.environment(\.newTab, env))
    if let content {
      content.rootView = view
    } else {
      let hosting = NSHostingView(rootView: view)
      hosting.sizingOptions = []
      hosting.safeAreaRegions = []
      addSubview(hosting)
      content = hosting
    }
    needsLayout = true
  }

  private func setHeight(_ h: CGFloat) {
    guard h > 0, h != height else { return }
    height = h
    onHeight(h)
  }

  private func watchSources() {
    watching = true
    observeSources()
  }

  private func observeSources() {
    guard let watchedModel = model else { return }
    withObservationTracking {
      _ = watchedModel.sourcesRevision
    } onChange: { [weak self, weak watchedModel] in
      Task { @MainActor in
        guard let self, let watchedModel, self.watching, self.model === watchedModel else { return }
        watchedModel.sourcesChanged()
        self.observeSources()
      }
    }
  }

  isolated deinit {
    watching = false
  }
}
