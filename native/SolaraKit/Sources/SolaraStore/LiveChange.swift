import SolaraModel

public struct LiveChange: Sendable {
  public let tabId: String
  public let rev: Int
  public let previous: PageLiveFacts?
  public let current: PageLiveFacts?
  public let url: String?
  public let profileId: String?
  public let previousGeneration: String?
  public let currentGeneration: String?

  public init(tabId: String, rev: Int, previous: PageLiveFacts?, current: PageLiveFacts?, url: String?, profileId: String?, previousGeneration: String? = nil, currentGeneration: String? = nil) {
    self.tabId = tabId
    self.rev = rev
    self.previous = previous
    self.current = current
    self.url = url
    self.profileId = profileId
    self.previousGeneration = previousGeneration
    self.currentGeneration = currentGeneration
  }
}
