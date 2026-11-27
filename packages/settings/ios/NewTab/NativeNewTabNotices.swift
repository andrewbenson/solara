import Foundation
import SolaraModel
import SolaraShell
import SolaraStore
import SolaraUI

@MainActor
final class NativeNewTabNotices {
  static let shared = NativeNewTabNotices()
  static var productName: String { Bundle.main.productName }
  static let releaseDocument = "release-notes.json"

  private var started = false
  private var currentVersion = ""
  private var checkIn = NewTabCheckIn(nil)
  private(set) var checkInReceipt = UUID()
  private var receipts = NewTabNoticeReceipts()
  private var timer: Task<Void, Never>?
  private var listeners: [UUID: () -> Void] = [:]

  private init() {}

  private static var now: Double { floor(Date().timeIntervalSince1970 * 1000) }

  private var canWrite: Bool { NativeStoreHandle.ownsWorkspace && !NativeStoreHandle.frozen }

  var page: NewTabNoticeReceipts.Page? { receipts.page }
  var pending: NewTabNoticeReceipts.Pending? { receipts.pending.flatMap { $0.isCurrent(at: Self.now) ? $0 : nil } }
  var checkInDue: Bool { checkIn.isDue(at: Self.now) }

  func start(version: String, pending: JSONValue, refused: Bool) {
    guard !started else { return }
    started = true
    currentVersion = version
    if !refused {
      checkIn = NewTabCheckIn(readOnboarding())
      receipts.queue(NewTabNoticeReceipts.Pending(pending))
    }
    publish()
  }

  func onboardingChanged(_ json: String) {
    guard started else { return }
    let updated = NewTabCheckIn(try? JSONValue.parse(json))
    guard checkIn != updated else { return }
    checkIn = updated
    checkInReceipt = UUID()
    publish()
  }

  func subscribe(_ change: @escaping () -> Void) -> UUID {
    let id = UUID()
    listeners[id] = change
    return id
  }

  func unsubscribe(_ id: UUID) { listeners[id] = nil }

  func finishCheckIn(_ receipt: UUID, action: String, windowId: String, beforeUpdate: () -> Void) {
    guard canWrite, receipt == checkInReceipt, action == "feedback" || action == "dismiss",
      checkIn.complete(at: Self.now), let doneAt = checkIn.doneAt else { return }
    beforeUpdate()
    save(OnboardingAdapter.document, AppStartupPolicy.onboardingDocument(saved: readOnboarding(),
      patch: ["defaultBrowserCheckInDoneAt": .number(doneAt)]))
    publish()
    if action == "feedback" { NativeAppIntegration.shared.sendFeedback(windowId) }
  }

  func open(_ version: String, windowId: String, matching receipt: UUID? = nil, beforeUpdate: () -> Void = {}) {
    guard canWrite, receipt == nil || pending?.id == receipt else { return }
    let retiring = receipts.pending
    guard receipts.open(version: version, windowId: windowId, matching: receipt) else { return }
    beforeUpdate()
    if let retiring { saveReleaseState(lastVersion: retiring.version) }
    publish()
  }

  func retire(_ receipt: UUID, beforeUpdate: () -> Void) {
    guard canWrite, let pending, receipts.retire(receipt) else { return }
    beforeUpdate()
    saveReleaseState(lastVersion: pending.version)
    publish()
  }

  func closePage(_ receipt: UUID? = nil, beforeUpdate: () -> Void = {}) {
    guard let current = receipts.page, receipts.close(receipt ?? current.id) else { return }
    beforeUpdate()
    publish()
  }

  private func saveReleaseState(lastVersion: String) {
    save(Self.releaseDocument, NewTabNoticeReceipts.document(lastVersion: lastVersion, pending: receipts.pending))
  }

  private func readOnboarding() -> JSONValue? {
    DocumentStore.read(OnboardingAdapter.document).flatMap { try? JSONValue.parse($0) }
  }

  private func save(_ name: String, _ document: JSONObject) {
    guard canWrite else { return }
    do { try DocumentStore.write(name, JSONValue.object(document).text()) }
    catch { NSLog("[new-tab] couldn't save %@: %@", name, String(describing: error)) }
  }

  private func publish() {
    timer?.cancel()
    timer = nil
    let now = Self.now
    let next = [checkIn.eligibleAt, receipts.pending.map { $0.expiry + 1 }].compactMap { $0 }.filter { $0 > now }.min()
    if let next {
      let delay = min((next - now) / 1000, 86_400)
      timer = Task { [weak self] in
        do { try await Task.sleep(for: .seconds(delay)) } catch { return }
        self?.timeChanged()
      }
    }
    for change in Array(listeners.values) { change() }
  }

  private func timeChanged() {
    if let pending = receipts.pending, !pending.isCurrent(at: Self.now), receipts.retire(pending.id),
      !DocumentStore.safeMode {
      saveReleaseState(lastVersion: currentVersion)
    }
    publish()
  }

  #if DEBUG
    func drive(_ action: String, _ json: String?) -> JSONValue {
      let input = json.flatMap { try? JSONValue.parse($0) }
      switch action {
      case "fixture":
        closePage()
        checkIn = NewTabCheckIn(["defaultBrowserTrialStartedAt": .number(Self.now - 691_200_000)])
        checkInReceipt = UUID()
        queue("1.0")
      case "queue": queue(input?["version"]?.string ?? currentVersion)
      case "open":
        if let windowId = input?["windowId"]?.string,
          let store = NativeStoreHandle.store,
          store.state.windows[windowId] != nil, !store.memory.closingWindows.contains(windowId) {
          open(input?["version"]?.string ?? pending?.version ?? currentVersion, windowId: windowId)
        }
      case "close": closePage()
      default: break
      }
      return [
        "doneAt": checkIn.doneAt.map(JSONValue.number) ?? .null,
        "pending": pending?.document ?? .null,
        "page": page.map { ["windowId": .string($0.windowId), "version": .string($0.version)] } ?? .null,
      ]
    }

    private func queue(_ version: String) {
      receipts.queue(NewTabNoticeReceipts.Pending(["version": .string(version), "since": .number(Self.now)]))
      saveReleaseState(lastVersion: currentVersion)
      publish()
    }
  #endif
}
