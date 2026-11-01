import SolaraModel

public typealias PageSessionGeneration = String

public struct PageReadyFacts: Sendable, Equatable {
  public let browserId: Int
  public let tabId: Int?

  public init(browserId: Int, tabId: Int? = nil) {
    self.browserId = browserId
    self.tabId = tabId
  }
}

public enum KeepAliveMedia: String, Sendable, Equatable {
  case none
  case present
  case playing
}

public struct KeepAliveKeep: Sendable, Equatable {
  public let capturing: Bool
  public let newTabShown: Bool
  public let pip: Bool
  public let displayRequest: Bool
  public let media: KeepAliveMedia

  public init(capturing: Bool, newTabShown: Bool, pip: Bool, displayRequest: Bool, media: KeepAliveMedia) {
    self.capturing = capturing
    self.newTabShown = newTabShown
    self.pip = pip
    self.displayRequest = displayRequest
    self.media = media
  }
}

public struct KeepAliveReveal: Sendable, Equatable {
  public let fullscreen: Bool
  public let crashed: Bool
  public let unresponsive: Bool
  public let scrolledDown: Bool
  public let sharing: Bool

  public init(fullscreen: Bool, crashed: Bool, unresponsive: Bool, scrolledDown: Bool, sharing: Bool) {
    self.fullscreen = fullscreen
    self.crashed = crashed
    self.unresponsive = unresponsive
    self.scrolledDown = scrolledDown
    self.sharing = sharing
  }
}

public struct KeepAliveFacts: Sendable, Equatable {
  public let epoch: Int
  public let seq: Int
  public let handled: Int
  public let keep: KeepAliveKeep
  public let reveal: KeepAliveReveal

  public init(epoch: Int, seq: Int, handled: Int, keep: KeepAliveKeep, reveal: KeepAliveReveal) {
    self.epoch = epoch
    self.seq = seq
    self.handled = handled
    self.keep = keep
    self.reveal = reveal
  }
}

public struct PageFacts: Sendable, Equatable {
  public let generation: String
  public let ready: PageReadyFacts?
  public let keepAlive: KeepAliveFacts?
  public let latchedThrough: Int
  public let newestEventSeq: Int
}

struct FeedWatermark: Sendable, Equatable {
  var epoch: Int
  var generation: String
  var seq: Int
}

struct PageProducerFence: Sendable, Equatable {
  var generation: String
  var retired: Bool
}

struct PageReportMemory: Sendable, Equatable {
  var model: TabPageModel
  var live: PageLive
  var generation: String?
  var modelSerial: Int
  var ready: PageReadyFacts? = nil
  var wasNewTab: Bool
  var newTabShownUrl: String?
  var contextRevision: Int
  var keepAlive: KeepAliveFacts? = nil
  var latchedThrough = 0
  var newestEventSeq = 0

  var facts: PageFacts? {
    guard let generation else { return nil }
    return PageFacts(generation: generation, ready: ready, keepAlive: keepAlive,
      latchedThrough: latchedThrough, newestEventSeq: newestEventSeq)
  }
}

struct HeldPageSeed: Sendable, Equatable {
  var tab: Tab
  var page: PageReportMemory
  var generation: String
  var restorable = true
  var adoptNavigationURL: String? = nil
}

public struct PageIssueGuard: Sendable, Equatable {
  public let sessionGeneration: String
  public let navigation: TabNavigationRequest?
  public let contextRevision: Int
  public let modelSerial: Int
  public let startedEarly: Bool
  public let sameProfileMove: Bool

  public init(sessionGeneration: String, navigation: TabNavigationRequest?, contextRevision: Int, modelSerial: Int, startedEarly: Bool, sameProfileMove: Bool) {
    self.sessionGeneration = sessionGeneration
    self.navigation = navigation
    self.contextRevision = contextRevision
    self.modelSerial = modelSerial
    self.startedEarly = startedEarly
    self.sameProfileMove = sameProfileMove
  }

  public init(json: JSONValue) throws {
    guard let generation = json["sessionGeneration"]?.string, !generation.isEmpty,
      let revision = pageSafeInteger(json["contextRevision"]),
      let serial = pageSafeInteger(json["modelSerial"], minimum: 1),
      let started = json["startedEarly"]?.bool, let moved = json["sameProfileMove"]?.bool,
      let rawNavigation = json["navigation"] else { throw CommandError("malformed page issue guard") }
    let navigation: TabNavigationRequest?
    if rawNavigation.isNull { navigation = nil }
    else {
      guard let seq = pageSafeInteger(rawNavigation["seq"]), let url = rawNavigation["url"]?.string,
        let userInitiated = rawNavigation["userInitiated"]?.bool else { throw CommandError("malformed page issue navigation") }
      navigation = TabNavigationRequest(seq: seq, url: url, userInitiated: userInitiated)
    }
    self.init(sessionGeneration: generation, navigation: navigation, contextRevision: revision,
      modelSerial: serial, startedEarly: started, sameProfileMove: moved)
  }

  public var json: JSONValue {
    ["sessionGeneration": .string(sessionGeneration), "navigation": pageNavigationJSON(navigation),
      "contextRevision": JSONValue(contextRevision), "modelSerial": JSONValue(modelSerial),
      "startedEarly": .bool(startedEarly), "sameProfileMove": .bool(sameProfileMove)]
  }
}

public struct PreparedPageIssue: Sendable, Equatable {
  public let actions: JSONValue
  public let guardValue: PageIssueGuard
  let profileId: String
  let engineProfile: String
  let engine: String
  let windowId: String
  let context: PageIssueContext
  let model: TabPageModel
}

struct PageIssueContext: Sendable, Equatable {
  var navigationSeq: Int?
  var revision: Int
  var wasNewTab: Bool
  var newTabShownUrl: String?
}

let pageMaximumSafeInteger = 9_007_199_254_740_991

func pageSafeInteger(_ value: JSONValue?, minimum: Int = 0) -> Int? {
  guard let number = value?.number, number.isFinite, number.rounded() == number,
    number >= Double(minimum), number <= Double(pageMaximumSafeInteger) else { return nil }
  return Int(number)
}

func pageNavigation(_ tab: Tab) -> TabNavigationRequest? {
  guard let navigation = tab.navigation, let sequence = pageSafeInteger(JSONValue(navigation.seq)) else { return nil }
  return TabNavigationRequest(seq: sequence, url: navigation.url, userInitiated: navigation.userInitiated ?? false)
}

func pageNavigationJSON(_ navigation: TabNavigationRequest?) -> JSONValue {
  guard let navigation else { return .null }
  return ["seq": JSONValue(navigation.seq), "url": .string(navigation.url), "userInitiated": .bool(navigation.userInitiated)]
}
