@MainActor
public enum CaptureSleepProtection {
  public static var reason: ((String) -> String?)?
}

public struct DisplayCaptureLifetime {
  public struct Page: Hashable, Sendable {
    public let tabID: String
    public let browserID: Int32
    public let profile: String

    public init(tabID: String, browserID: Int32, profile: String) {
      self.tabID = tabID
      self.browserID = browserID
      self.profile = profile
    }
  }

  public struct Receipt: Hashable, Sendable {
    public let id: String
    public let page: Page
  }

  public struct Share: Equatable, Sendable {
    public let receipt: Receipt
    public fileprivate(set) var target: Page?
    public fileprivate(set) var dismissed: Set<String> = []
  }

  public private(set) var pending: [String: Receipt] = [:]
  public private(set) var shares: [String: Share] = [:]
  private var order: [String] = []

  public init() {}

  public mutating func offer(_ id: String, on page: Page) -> (receipt: Receipt, replaced: Receipt?) {
    let receipt = Receipt(id: id, page: page)
    let old = pending.updateValue(receipt, forKey: page.tabID)
    return (receipt, old == receipt ? nil : old)
  }

  public mutating func answer(_ receipt: Receipt, source: String?, target: Page?) -> Bool {
    let id = receipt.page.tabID
    guard pending[id] == receipt, target == nil || target?.profile == receipt.page.profile else { return false }
    pending[id] = nil
    if source != nil {
      if shares[id] == nil { order.append(id) }
      shares[id] = Share(receipt: receipt, target: target)
    }
    return true
  }

  @discardableResult
  public mutating func close(_ page: Page) -> Receipt? {
    guard pending[page.tabID]?.page == page else { return nil }
    return pending.removeValue(forKey: page.tabID)
  }

  public mutating func stop(_ page: Page) {
    close(page)
    ended(page)
  }

  public mutating func ended(_ page: Page) {
    guard shares[page.tabID]?.receipt.page == page else { return }
    shares[page.tabID] = nil
    order.removeAll { $0 == page.tabID }
  }

  public func share(for page: Page) -> Share? {
    let candidates = order.compactMap { shares[$0] }.filter {
      $0.receipt.page.profile == page.profile && !$0.dismissed.contains(page.tabID)
    }
    return candidates.first { $0.receipt.page == page || $0.target == page }
      ?? candidates.first { $0.target != nil }
  }

  public mutating func dismiss(_ receipt: Receipt, from page: Page) {
    guard shares[receipt.page.tabID]?.receipt == receipt, receipt.page.profile == page.profile else { return }
    shares[receipt.page.tabID]?.dismissed.insert(page.tabID)
  }

  public mutating func retarget(_ receipt: Receipt, to page: Page) -> Bool {
    guard let share = shares[receipt.page.tabID], share.receipt == receipt,
      share.target != nil, receipt.page.profile == page.profile else { return false }
    shares[receipt.page.tabID] = Share(receipt: receipt, target: page)
    return true
  }
}
