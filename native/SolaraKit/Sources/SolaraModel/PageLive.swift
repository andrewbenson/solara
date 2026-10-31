public struct PageLiveFacts: JSONConvertible {
  public var discarded: Bool
  public var isLoading: Bool
  public var canGoBack: Bool
  public var canGoForward: Bool
  public var playingAudio: Bool
  public var themeColor: String?

  public init(isLoading: Bool = false, canGoBack: Bool = false, canGoForward: Bool = false, playingAudio: Bool = false, themeColor: String? = nil, discarded: Bool = false) {
    self.discarded = discarded
    self.isLoading = isLoading
    self.canGoBack = canGoBack
    self.canGoForward = canGoForward
    self.playingAudio = playingAudio
    self.themeColor = themeColor
  }
}

public struct PageLivePatch: Equatable, Sendable {
  public var isLoading: Bool?
  public var canGoBack: Bool?
  public var canGoForward: Bool?
  public var playingAudio: Bool?
  public var themeColor: String??

  public init(isLoading: Bool? = nil, canGoBack: Bool? = nil, canGoForward: Bool? = nil, playingAudio: Bool? = nil, themeColor: String?? = nil) {
    self.isLoading = isLoading
    self.canGoBack = canGoBack
    self.canGoForward = canGoForward
    self.playingAudio = playingAudio
    self.themeColor = themeColor
  }
}

public struct PageLiveRestoredTheme: Equatable, Sendable {
  public var page: String
  public var color: String

  public init(page: String, color: String) {
    self.page = page
    self.color = color
  }
}

public struct PageLive: Equatable, Sendable {
  public private(set) var facts: PageLiveFacts?
  public private(set) var discarded: Bool
  public private(set) var settleAt: Double?
  private var restored: PageLiveRestoredTheme?

  public init(facts: PageLiveFacts? = PageLiveFacts(), discarded: Bool = false) {
    self.facts = facts
    self.discarded = discarded || facts?.discarded == true
    self.facts?.discarded = self.discarded
  }

  @discardableResult
  public mutating func apply(_ patch: PageLivePatch) -> Bool {
    guard var next = facts else { return false }
    if let value = patch.isLoading { next.isLoading = value }
    if let value = patch.canGoBack { next.canGoBack = value }
    if let value = patch.canGoForward { next.canGoForward = value }
    if let value = patch.playingAudio { next.playingAudio = value }
    if let value = patch.themeColor { next.themeColor = value }
    guard next != facts else { return false }
    facts = next
    return true
  }

  public mutating func navigation(url: String, isLoading: Bool, canGoBack: Bool = false, canGoForward: Bool = false, themeColor: String? = nil, now: Double, tabExists: Bool = true) -> PageLivePatch {
    let shownTheme = restoredThemeColor(url: url, reported: themeColor, isLoading: isLoading, now: now)
    let patch = PageLivePatch(isLoading: isLoading, canGoBack: canGoBack, canGoForward: canGoForward, themeColor: .some(shownTheme))
    if tabExists { apply(patch) }
    return patch
  }

  public mutating func markLoading() -> PageLivePatch {
    let patch = PageLivePatch(isLoading: true)
    apply(patch)
    return patch
  }

  public mutating func media(playing: Bool) -> PageLivePatch {
    let patch = PageLivePatch(playingAudio: playing)
    apply(patch)
    return patch
  }

  public mutating func download() -> PageLivePatch {
    let patch = PageLivePatch(isLoading: false)
    apply(patch)
    return patch
  }

  public mutating func discard() -> PageLivePatch {
    let patch = PageLivePatch(isLoading: false, canGoBack: false, canGoForward: false, playingAudio: false)
    apply(patch)
    discarded = true
    facts?.discarded = true
    return patch
  }

  public mutating func ready() {
    discarded = false
    facts?.discarded = false
  }

  public mutating func restore(tabURL: String?, page: String, color: String) -> PageLivePatch? {
    restore(tabURL: tabURL, themes: [PageLiveRestoredTheme(page: page, color: color)])
  }

  public mutating func restore(tabURL: String?, themes: [PageLiveRestoredTheme]) -> PageLivePatch? {
    guard let tabURL, let facts, facts.themeColor?.isEmpty != false else { return nil }
    let page = TabPageModel.pageKey(tabURL)
    guard let theme = themes.last(where: { $0.color.utf16.count <= 64 && $0.page == page }) else { return nil }
    restored = theme
    let patch = PageLivePatch(themeColor: .some(theme.color))
    apply(patch)
    return patch
  }

  public mutating func advance(to now: Double) -> PageLivePatch? {
    guard let deadline = settleAt, now >= deadline else { return nil }
    settleAt = nil
    guard restored != nil else { return nil }
    restored = nil
    let patch = PageLivePatch(themeColor: .some(nil))
    apply(patch)
    return patch
  }

  private mutating func restoredThemeColor(url: String, reported: String?, isLoading: Bool, now: Double) -> String? {
    guard let held = restored else { return reported }
    let blank = url.isEmpty || url == "about:blank"
    if reported?.isEmpty == false || (!blank && TabPageModel.pageKey(url) != held.page) {
      restored = nil
      settleAt = nil
      return reported
    }
    if !isLoading && !blank && settleAt == nil { settleAt = now + 1500 }
    return held.color
  }
}

public extension PageLiveFacts {
  init(json: JSONObject) throws {
    self.init(isLoading: json["isLoading"]?.bool ?? false, canGoBack: json["canGoBack"]?.bool ?? false,
      canGoForward: json["canGoForward"]?.bool ?? false, playingAudio: json["playingAudio"]?.bool ?? false,
      themeColor: json["themeColor"]?.string, discarded: json["discarded"]?.bool ?? false)
  }

  var json: JSONObject {
    ["discarded": .bool(discarded), "isLoading": .bool(isLoading), "canGoBack": .bool(canGoBack), "canGoForward": .bool(canGoForward),
      "playingAudio": .bool(playingAudio), "themeColor": JSONValue(themeColor)]
  }
}
