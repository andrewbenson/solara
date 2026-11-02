import AppKit
import CryptoKit
import UserNotifications

private typealias NotificationReply = @convention(block) (NSDictionary) -> Void
private typealias NotificationAuthorizationQuery = @convention(block) (NSDictionary) -> Bool

@MainActor private final class NotificationLifetime {
  var retired = false
}

@MainActor private final class NotificationEffects {
  var values = Dictionary(uniqueKeysWithValues: ["centerAcquire", "delegate", "categories", "authorization", "settings", "attachmentLoad", "add", "query", "removeDelivered", "removePending"].map { ($0, 0) })
  func record(_ name: String) { values[name, default: 0] += 1 }
}

@MainActor private final class NotificationAddCleanup {
  let center: UNUserNotificationCenter
  let effects: NotificationEffects
  let lifetime: NotificationLifetime
  let nativeID: String
  var completion: (@MainActor @Sendable (Bool) -> Void)?

  init(center: UNUserNotificationCenter, effects: NotificationEffects, lifetime: NotificationLifetime, nativeID: String) {
    self.center = center
    self.effects = effects
    self.lifetime = lifetime
    self.nativeID = nativeID
  }

  func finish(_ success: Bool) {
    if lifetime.retired {
      completion = nil
      if success {
        effects.record("removeDelivered")
        center.removeDeliveredNotifications(withIdentifiers: [nativeID])
        effects.record("removePending")
        center.removePendingNotificationRequests(withIdentifiers: [nativeID])
      }
      return
    }
    let callback = completion
    completion = nil
    callback?(success)
  }
}

@MainActor private final class NotificationPostCompletion {
  private var completion: (@MainActor @Sendable (String?) -> Void)?
  init(_ completion: @escaping @MainActor @Sendable (String?) -> Void) { self.completion = completion }
  func finish(_ value: String?) {
    let callback = completion
    completion = nil
    callback?(value)
  }
}

private final class NotificationDelegateCompletion<Value>: @unchecked Sendable {
  private let lock = NSLock()
  private var completion: ((Value) -> Void)?
  init(_ completion: @escaping (Value) -> Void) { self.completion = completion }
  func finish(_ value: Value) {
    lock.lock()
    let callback = completion
    completion = nil
    lock.unlock()
    callback?(value)
  }
}

@MainActor @objc(SolaraNotificationHub) final class NotificationHub: NSObject, UNUserNotificationCenterDelegate {
  static let shared = NotificationHub()
  private let simulated: Bool = {
    #if DEBUG
    let debug = true
    #else
    let debug = false
    #endif
    return NotificationAdapterMode.choose(environment: ProcessInfo.processInfo.environment, debug: debug) == .memory
  }()
  private var observer: NSObjectProtocol?
  private var installed = false
  private let lifetime = NotificationLifetime()
  private var retired: Bool { lifetime.retired }
  private var addOwners: [String: NotificationAddCleanup] = [:]
  private var postCompletions: [String: NotificationPostCompletion] = [:]
  private var submitted: [String: [String: Any]] = [:]
  private var draining = false
  private var centerValue: UNUserNotificationCenter?
  private let effectLedger = NotificationEffects()
  private var effects: [String: Int] { effectLedger.values }
  private var permissionWaiters: [(eligible: @MainActor @Sendable () -> Bool, completion: @MainActor @Sendable (Bool) -> Void)] = []
  private var authorizationStatus = "unknown"
  #if DEBUG
  private var debugAuthorizationEnabled = false
  private var debugHoldSettings = false
  private var debugSettingsCompletions: [@MainActor @Sendable (String) -> Void] = []
  private var debugHoldConsumption = false
  private var debugConsumedEvents: [[String: Any]] = []
  private var debugAuthorizationPending = false
  private var debugSettingsCalls = 0
  private var debugAuthorizationCalls = 0
  #endif
  private var owned: [String: [String: Any]] = [:]
  private var authorizationEligible = Set<String>()
  private var authorizationQuery: NotificationAuthorizationQuery?
  private var revoked = Set<String>()
  private var revokedSessions = Set<String>()
  private var pending: [String: [String: Any]] = [:]
  private var delivered: [String: [String: Any]] = [:]
  private var liveIDs = Set<String>()
  private var removalIDs = Set<String>()
  var onResponse: ((String, String, [String: Any]) -> Void)?
  private var liveResponses: [(String, String, [String: Any])] = []
  private var earlyResponses: [(String, String, [String: Any], @MainActor @Sendable ([String: Any]) -> Void)] = []
  private var inFlight = Set<String>()
  private var revision: UInt64 = 1
  private var proofs: [String: [String: Any]] = [:]
  private var nativeReceipts: [String: [String: Any]] = [:]
  private var presented: [String: [String: Any]] = [:]
  private var actions: [String: [String: Any]] = [:]
  private var queuedActions = Set<String>()
  private var receipts: [[String: Any]] = []
  private var diagnosticDrops = 0
  private var liveBindings: [String: String] = [:]
  private var bridge = ""
  private var watch = ""
  private var maximumWatch: UInt64 = 0
  private var state = "NoConsumer"
  private var applied: UInt64 = 0
  private var acknowledged: UInt64 = 0
  private var replay: [String: Any]?
  private var entries: [[String: Any]] = []
  private var entryJSON: [String] = []
  private var events: [[String: Any]] = []
  private var busy = false
  private var rootPrefix = ""
  private static let category = "solara.dismissible"
  private static let routeKeys = ["B", "W", "scope", "lifetime", "root", "profile", "incarnation", "session", "token", "creation", "generation", "nativeID"]

  @objc(installTransportWithAuthorizationQuery:) nonisolated static func installTransport(authorizationQuery: @escaping @convention(block) (NSDictionary) -> Bool) {
    precondition(Thread.isMainThread)
    MainActor.assumeIsolated {
      shared.authorizationQuery = authorizationQuery
      shared.installObserver()
    }
  }

  private func installObserver() {
    guard observer == nil, !retired else { return }
    observer = NotificationCenter.default.addObserver(forName: Notification.Name("SolaraNotificationControl"), object: nil, queue: nil) { [self] note in
      precondition(Thread.isMainThread)
      MainActor.assumeIsolated {
        guard let blockClass = NSClassFromString("NSBlock"), let block = note.userInfo?["completion"] as AnyObject?,
              block.isKind(of: blockClass) else { return }
        let reply = unsafeBitCast(block, to: NotificationReply.self)
        guard let payload = note.userInfo?["payload"] as? [String: Any] else {
          reply(["ok": false, "error": "invalidControl"] as NSDictionary)
          return
        }
        let callback = NotificationDelegateCompletion<NSDictionary> { reply($0) }
        self.control(payload) { callback.finish($0 as NSDictionary) }
      }
    }
  }

  func install() {
    installObserver()
    guard !installed, !retired else { return }
    installed = true
    if simulated { return }
    effect("delegate")
    center.delegate = self
    effect("categories")
    center.setNotificationCategories([UNNotificationCategory(identifier: Self.category, actions: [], intentIdentifiers: [], options: [.customDismissAction])])
  }

  private var center: UNUserNotificationCenter {
    if let centerValue { return centerValue }
    effect("centerAcquire")
    let value = UNUserNotificationCenter.current()
    centerValue = value
    return value
  }

  private func effect(_ name: String) { effectLedger.record(name) }
  private func changed() { revision += 1 }
  private func number(_ value: Any?) -> UInt64 { UInt64(value as? String ?? "") ?? (value as? NSNumber)?.uint64Value ?? 0 }
  private func text(_ row: [String: Any], _ key: String) -> String { row[key] as? String ?? "" }
  private func route(_ row: [String: Any]) -> [String: Any] {
    var result: [String: Any] = [:]
    for key in Self.routeKeys { if let value = row[key] { result[key] = value } }
    return result
  }
  private func current(_ row: [String: Any]) -> [String: Any] {
    var value = route(row)
    value["B"] = bridge
    value["W"] = watch
    return value
  }
  private func same(_ a: [String: Any], _ b: [String: Any]) -> Bool {
    Self.routeKeys.filter { $0 != "W" }.allSatisfy { text(a, $0) == text(b, $0) }
  }
  private func allowed(_ row: [String: Any]) -> Bool {
    let id = text(row, "nativeID")
    return !draining && !retired && !revoked.contains(id) && !revokedSessions.contains(text(row, "session")) && owned[id].map { same($0, row) } == true
  }
  private func hashBytes(_ data: Data) -> String {
    Insecure.SHA1.hash(data: data).map { String(format: "%02X", $0) }.joined()
  }
  private func hash(_ object: Any) -> String {
    guard let data = try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys, .withoutEscapingSlashes]) else { return "" }
    return hashBytes(data)
  }
  private func diagnosticRow(_ row: [String: Any]) -> [String: Any] {
    var result = row.filter { $0.key != "resources" && $0.key != "data" }
    if let resources = row["resources"] as? [String: Any] {
      for key in ["title", "body", "workerScope"] { if let value = resources[key] { result[key] = value } }
    }
    return result
  }
  private func record(_ value: [String: Any]) {
    receipts.append(diagnosticRow(value))
    while receipts.count > 512 || ((try? JSONSerialization.data(withJSONObject: receipts))?.count ?? 0) > 128 * 1024 {
      receipts.removeFirst()
      diagnosticDrops += 1
    }
  }
  private func send(_ value: [String: Any], completion: @escaping @MainActor @Sendable ([String: Any]) -> Void = { _ in }) {
    guard !retired else { completion(["ok": false, "error": "retired"]); return }
    let callback: NotificationReply = { result in
      precondition(Thread.isMainThread)
      MainActor.assumeIsolated { completion(result as? [String: Any] ?? [:]) }
    }
    NotificationCenter.default.post(name: Notification.Name("SolaraNotificationEngineControl"), object: nil, userInfo: ["payload": value, "completion": callback])
  }

  func permission(_ completion: @escaping @MainActor @Sendable (String) -> Void) {
    guard !retired else { completion("denied"); return }
    #if DEBUG
    if simulated && debugAuthorizationEnabled {
      debugSettingsCalls += 1
      if debugHoldSettings { debugSettingsCompletions.append(completion) }
      else { authorizationStatus = "notDetermined"; completion("notDetermined") }
      return
    }
    #endif
    if simulated { authorizationStatus = "simulated"; completion("simulated"); return }
    install()
    effect("settings")
    center.getNotificationSettings { settings in
      let status: String
      switch settings.authorizationStatus {
      case .authorized: status = "granted"
      case .denied: status = "denied"
      case .provisional, .ephemeral: status = "provisional"
      default: status = "notDetermined"
      }
      DispatchQueue.main.async {
        guard !self.retired else { completion("denied"); return }
        self.authorizationStatus = status
        completion(status)
      }
    }
  }

  func requestPermission(whileEligible eligible: @escaping @MainActor @Sendable () -> Bool = { true }, _ completion: @escaping @MainActor @Sendable (Bool) -> Void) {
    guard !retired, !draining, eligible() else { completion(false); return }
    if simulated {
      #if DEBUG
      if !debugAuthorizationEnabled { authorizationStatus = "simulated"; completion(true); return }
      #else
      authorizationStatus = "simulated"; completion(true); return
      #endif
    }
    permissionWaiters.append((eligible, completion))
    guard permissionWaiters.count == 1 else { return }
    permission { [self] status in
      guard !draining, !retired else { finishPermission(false); return }
      if status != "notDetermined" { finishPermission(status == "granted" || status == "provisional"); return }
      guard permissionWaiters.contains(where: { $0.eligible() }) else { finishPermission(false); return }
      #if DEBUG
      if simulated && debugAuthorizationEnabled {
        debugAuthorizationCalls += 1
        debugAuthorizationPending = true
        return
      }
      #endif
      effect("authorization")
      center.requestAuthorization(options: [.alert, .sound, .badge]) { granted, _ in
        DispatchQueue.main.async { self.finishPermission(granted) }
      }
    }
  }
  #if DEBUG
  func debugAuthorization(_ payload: [String: Any]) -> [String: Any] {
    guard simulated, !retired, !draining else { return ["ok": false] }
    switch text(payload, "op") {
    case "configure":
      guard permissionWaiters.isEmpty, debugSettingsCompletions.isEmpty, debugConsumedEvents.isEmpty, !debugAuthorizationPending else { return ["ok": false] }
      debugAuthorizationEnabled = true
      debugHoldSettings = payload["holdSettings"] as? Bool == true
      debugHoldConsumption = payload["holdConsumption"] as? Bool == true
      debugSettingsCalls = 0
      debugAuthorizationCalls = 0
    case "releaseSettings":
      debugHoldSettings = false
      let callbacks = debugSettingsCompletions
      debugSettingsCompletions = []
      authorizationStatus = "notDetermined"
      callbacks.forEach { $0("notDetermined") }
    case "releaseConsumption":
      debugHoldConsumption = false
      let delayed = debugConsumedEvents
      debugConsumedEvents = []
      delayed.forEach { consume($0) }
    case "completeAuthorization":
      guard debugAuthorizationPending else { return ["ok": false] }
      debugAuthorizationPending = false
      finishPermission(payload["granted"] as? Bool == true)
    case "reset":
      debugAuthorizationEnabled = false
      debugHoldSettings = false
      debugHoldConsumption = false
      debugAuthorizationPending = false
      let callbacks = debugSettingsCompletions
      debugSettingsCompletions = []
      callbacks.forEach { $0("denied") }
      finishPermission(false)
      let delayed = debugConsumedEvents
      debugConsumedEvents = []
      delayed.forEach { consume($0) }
    case "snapshot": break
    default: return ["ok": false]
    }
    return ["ok": true, "enabled": debugAuthorizationEnabled, "settingsCalls": debugSettingsCalls, "authorizationCalls": debugAuthorizationCalls, "permissionWaiters": permissionWaiters.count, "heldSettings": debugSettingsCompletions.count, "heldConsumption": debugConsumedEvents.count, "authorizationPending": debugAuthorizationPending]
  }
  #endif
  private func deliveryPermission(requestEligibility: @escaping @MainActor @Sendable () -> Bool = { false }, completion: @escaping @MainActor @Sendable (Bool) -> Void) {
    if requestEligibility() { requestPermission(whileEligible: requestEligibility, completion); return }
    permission { status in completion(status == "granted" || status == "provisional" || status == "simulated") }
  }
  private func finishPermission(_ value: Bool) {
    guard !retired else { return }
    authorizationStatus = value ? "granted" : "denied"
    let waiters = permissionWaiters
    permissionWaiters = []
    waiters.forEach { $0.completion(value && !draining && !retired && $0.eligible()) }
  }

  private func enumerate(_ completion: @escaping @MainActor @Sendable ([String: [String: Any]], Set<String>) -> Void) {
    if retired { return }
    if simulated { completion(delivered, Set(pending.keys)); return }
    effect("query")
    center.getDeliveredNotifications { notifications in
      let copies = Dictionary(uniqueKeysWithValues: notifications.map { ($0.request.identifier, try? JSONSerialization.data(withJSONObject: $0.request.content.userInfo)) })
      DispatchQueue.main.async {
        guard !self.retired else { return }
        self.effect("query")
        self.center.getPendingNotificationRequests { requests in
          let ids = Set(requests.map(\.identifier))
          DispatchQueue.main.async {
            guard !self.retired else { return }
            let rows = copies.mapValues { data in data.flatMap { (try? JSONSerialization.jsonObject(with: $0)) as? [String: Any] } ?? [:] }
            completion(rows, ids)
          }
        }
      }
    }
  }
  private func removeExact(_ ids: [String]) {
    guard !retired, !ids.isEmpty else { return }
    changed()
    removalIDs.formUnion(ids)
    if simulated {
      ids.forEach { delivered.removeValue(forKey: $0); pending.removeValue(forKey: $0) }
      removalIDs.subtract(ids.filter { !inFlight.contains($0) })
      return
    }
    effect("removeDelivered")
    center.removeDeliveredNotifications(withIdentifiers: ids)
    effect("removePending")
    center.removePendingNotificationRequests(withIdentifiers: ids)
  }
  private func settle(_ ids: Set<String>, deadline: Date = Date().addingTimeInterval(4.5), completion: @escaping @MainActor @Sendable (Bool) -> Void) {
    guard !retired else { completion(false); return }
    enumerate { [self] rows, waiting in
      guard !retired else { completion(false); return }
      let absent = ids.isDisjoint(with: Set(rows.keys).union(waiting)) && ids.isDisjoint(with: Set(inFlight.compactMap { pending[$0]?["nativeID"] as? String }))
      if absent {
        removalIDs.subtract(ids)
        for id in ids { delivered.removeValue(forKey: id); pending.removeValue(forKey: id) }
        completion(true); return
      }
      if Date() >= deadline { removeExact(Array(ids)); completion(false); return }
      removeExact(Array(ids))
      DispatchQueue.main.asyncAfter(deadline: .now() + 0.025) { self.settle(ids, deadline: deadline, completion: completion) }
    }
  }
  private func barrier(_ completion: @escaping @MainActor @Sendable (Bool) -> Void) {
    let deadline = Date().addingTimeInterval(4.5)
    @MainActor @Sendable func check() {
      if self.retired { completion(false); return }
      if self.inFlight.isEmpty && self.removalIDs.isEmpty { completion(true); return }
      if Date() >= deadline { completion(false); return }
      self.enumerate { rows, pending in
        guard !self.retired else { completion(false); return }
        let native = Set(rows.keys).union(pending)
        let absent = self.removalIDs.subtracting(native).subtracting(self.inFlight)
        self.removalIDs.subtract(absent)
        for id in absent { self.delivered.removeValue(forKey: id) }
        if self.inFlight.isEmpty && self.removalIDs.isEmpty { completion(true); return }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.025, execute: check)
      }
    }
    check()
  }
  private func mint(_ payload: [String: Any], field: String) -> [String: Any] {
    let id = UUID().uuidString
    var proof = payload
    proof[field] = id
    if proof["N"] == nil { proof["N"] = String(revision) }
    proof["B"] = bridge
    proof["W"] = watch
    proof["valid"] = true
    proof["settled"] = true
    proof["inFlight"] = 0
    proofs[id] = proof
    if proofs.count > 4096 { proofs.removeValue(forKey: proofs.keys.first!) }
    return proof
  }

  private func postRoute(_ row: [String: Any], completion: @escaping @MainActor @Sendable (Bool) -> Void) {
    let id = text(row, "nativeID")
    guard allowed(row), text(row, "W") == watch else { completion(false); return }
    if delivered[id] != nil {
      if row["accepted"] as? Bool == true { completion(true) } else { acknowledgeDelivery(row, operation: UUID().uuidString, expectedWatch: watch, completion: completion) }
      return
    }
    if inFlight.contains(id) {
      barrier { [self] settled in
        if settled, allowed(row) { postRoute(row, completion: completion) } else { completion(false) }
      }
      return
    }
    let operation = UUID().uuidString
    let operationWatch = watch
    inFlight.insert(id)
    pending[id] = row
    changed()
    deliveryPermission(requestEligibility: { [self] in authorizationEligible.contains(id) && allowed(row) && operationWatch == watch && authorizationQuery?(route(row) as NSDictionary) == true }) { [self] granted in
      if !granted { record(diagnosticRow(row).merging(["kind": "post", "status": "denied", "authorizationStatus": authorizationStatus, "operation": operation]) { _, b in b }) }
      guard granted, allowed(row), operationWatch == watch else { finishAdd(row, operation: operation, expectedWatch: operationWatch, success: false, completion: completion); return }
      if simulated { finishAdd(row, operation: operation, expectedWatch: operationWatch, success: true, completion: completion); return }
      install()
      let content = UNMutableNotificationContent()
      let resources = row["resources"] as? [String: Any] ?? [:]
      content.title = text(resources, "title")
      content.body = text(resources, "body")
      content.threadIdentifier = hash([text(row, "scope"), text(row, "origin")])
      content.categoryIdentifier = Self.category
      if resources["silent"] as? Bool != true { content.sound = .default }
      content.userInfo = route(row)
      if let attachment = attachment(row) { content.attachments = [attachment] }
      submitted[id] = route(row)
      submit(id: id, content: content) { [self] success in
        finishAdd(row, operation: operation, expectedWatch: operationWatch, success: success, completion: completion)
      }
    }
  }
  private func submit(id: String, content: UNMutableNotificationContent, completion: @escaping @MainActor @Sendable (Bool) -> Void) {
    effect("add")
    let cleanup = NotificationAddCleanup(center: center, effects: effectLedger, lifetime: lifetime, nativeID: id)
    addOwners[id] = cleanup
    cleanup.completion = { [weak self] success in
      guard let self else { return }
      self.addOwners.removeValue(forKey: id)
      completion(success)
    }
    center.add(UNNotificationRequest(identifier: id, content: content, trigger: nil)) { error in
      let success = error == nil
      DispatchQueue.main.async { cleanup.finish(success) }
    }
  }
  private func finishAdd(_ row: [String: Any], operation: String, expectedWatch: String, success: Bool, completion: @escaping @MainActor @Sendable (Bool) -> Void) {
    guard !retired else { return }
    let id = text(row, "nativeID")
    inFlight.remove(id)
    pending.removeValue(forKey: id)
    submitted.removeValue(forKey: id)
    changed()
    guard success, allowed(row) else {
      if success {
        removeExact([id])
        settle([id]) { _ in completion(false) }
      } else { completion(false) }
      return
    }
    var stored = row
    let resources = row["resources"] as? [String: Any] ?? [:]
    stored["title"] = text(resources, "title")
    stored["body"] = text(resources, "body")
    delivered[id] = stored
    presented[id] = route(row)
    guard expectedWatch == watch else { completion(false); return }
    acknowledgeDelivery(row, operation: operation, expectedWatch: expectedWatch, completion: completion)
  }
  private func acknowledgeDelivery(_ row: [String: Any], operation: String, expectedWatch: String, completion: @escaping @MainActor @Sendable (Bool) -> Void) {
    let id = text(row, "nativeID")
    guard allowed(row), expectedWatch == watch else { completion(false); return }
    var stored = delivered[id] ?? row
    var proof = mint(current(row), field: "receipt")
    proof["operation"] = operation
    proofs[text(proof, "receipt")] = proof
    nativeReceipts[id] = proof
    stored["receipt"] = proof["receipt"]
    delivered[id] = stored
    var ack = current(row)
    ack["op"] = "postAck"
    ack["N"] = proof["N"]
    ack["receipt"] = proof["receipt"]
    ack["accepted"] = true
    record(stored.merging(["kind": "post", "status": "accepted", "receipt": proof["receipt"]!, "operation": operation]) { _, b in b })
    send(ack) { [self] answer in
      guard !retired else { return }
      record(answer.merging(["kind": "ack", "status": answer["engineAccepted"] as? Bool == true ? "accepted" : "rejected"]) { _, b in b })
      if answer["engineAccepted"] as? Bool != true, expectedWatch == watch, allowed(row) { revoked.insert(id); removeExact([id]) }
      completion(answer["engineAccepted"] as? Bool == true)
    }
  }
  private func attachment(_ row: [String: Any]) -> UNNotificationAttachment? {
    guard !simulated, text(row, "session").isEmpty, let resources = row["resources"] as? [String: Any],
          let encoded = (resources["image"] ?? resources["icon"]) as? String,
          encoded.utf8.count <= 2 * 1024 * 1024, let data = Data(base64Encoded: encoded), data.count <= 1024 * 1024 else { return nil }
    effect("attachmentLoad")
    let file = FileManager.default.temporaryDirectory.appendingPathComponent("solara-notification-\(UUID().uuidString).png")
    do {
      try data.write(to: file, options: .atomic)
      let value = try UNNotificationAttachment(identifier: "image", url: file)
      try? FileManager.default.removeItem(at: file)
      return value
    } catch {
      try? FileManager.default.removeItem(at: file)
      return nil
    }
  }

  private func fence(_ payload: [String: Any]) -> Set<String> {
    var ids = Set<String>()
    if let id = payload["nativeID"] as? String { ids.insert(id) }
    for disposition in payload["dispositions"] as? [[String: Any]] ?? [] where text(disposition, "disposition") == "revoked" {
      ids.insert(text(disposition, "nativeID"))
    }
    if text(payload, "reason") == "privateEnd", !text(payload, "session").isEmpty { revokedSessions.insert(text(payload, "session")) }
    if text(payload, "control") == "browserDrain" { ids.formUnion(owned.keys); ids.formUnion(liveIDs); draining = true; state = "Draining" }
    revoked.formUnion(ids)
    changed()
    return ids
  }
  private func control(_ payload: [String: Any], completion: @escaping @MainActor @Sendable ([String: Any]) -> Void) {
    let kind = text(payload, "control")
    if kind == "snapshot" || kind == "debugSnapshot" { completion(snapshot()); return }
    if kind == "consume" || kind == "event" {
      let event = payload["event"] as? [String: Any] ?? [:]
      #if DEBUG
      if simulated && debugAuthorizationEnabled && debugHoldConsumption {
        guard debugConsumedEvents.count < 8192 else { completion(["ok": false]); return }
        debugConsumedEvents.append(event)
        completion(["ok": true]); return
      }
      #endif
      consume(event); completion(["ok": true]); return
    }
    if kind == "retire" {
      #if DEBUG
      debugAuthorizationEnabled = false
      debugHoldSettings = false
      debugHoldConsumption = false
      debugAuthorizationPending = false
      let settings = debugSettingsCompletions
      debugSettingsCompletions = []
      debugConsumedEvents = []
      settings.forEach { $0("denied") }
      #endif
      draining = true
      finishPermission(false)
      lifetime.retired = true
      if let observer { NotificationCenter.default.removeObserver(observer); self.observer = nil }
      authorizationEligible = []
      let posts = Array(postCompletions.values)
      postCompletions = [:]
      posts.forEach { $0.finish(nil) }
      addOwners.values.forEach { $0.completion = nil }
      addOwners = [:]
      state = "Closed"
      for token in queuedActions { record(["kind": "operation", "token": token, "state": "settled", "engineCompleted": false, "error": "retired"]) }
      queuedActions = []
      actions = [:]
      events = []
      proofs = [:]
      let responses = earlyResponses
      earlyResponses = []
      responses.forEach { $0.3(["accepted": false, "error": "retired"]) }
      completion(["ok": true]); return
    }
    if retired { completion(["ok": false, "settled": false]); return }
    if kind == "initializeIdentity" {
      let path = text(payload, "canonicalRoot")
      let incarnation = text(payload, "B")
      guard !path.isEmpty, !incarnation.isEmpty else { completion(["ok": false]); return }
      let prefix = "solara.n2." + hashBytes(Data(path.utf8)) + "."
      guard (rootPrefix.isEmpty || rootPrefix == prefix), (bridge.isEmpty || bridge == incarnation) else { completion(["ok": false]); return }
      rootPrefix = prefix
      bridge = incarnation
      let responses = earlyResponses
      earlyResponses = []
      responses.forEach { decode(id: $0.0, identifier: $0.1, info: $0.2, completion: $0.3) }
      completion(["ok": true]); return
    }
    if kind == "own" || kind == "rebind" {
      let id = text(payload, "nativeID")
      if kind == "rebind" {
        guard let previous = owned[id], text(previous, "session").isEmpty, text(payload, "session").isEmpty, ["B", "root", "profile", "incarnation", "token", "creation", "generation", "nativeID"].allSatisfy({ text(previous, $0) == text(payload, $0) }) else { completion(["ok": false]); return }
      }
      if bridge.isEmpty { bridge = text(payload, "B") }
      if rootPrefix.isEmpty, !text(payload, "root").isEmpty { rootPrefix = "solara.n2." + text(payload, "root") + "." }
      if !revoked.contains(id), !revokedSessions.contains(text(payload, "session")), !draining {
        owned[id] = payload
        if payload["authorizationEligible"] as? Bool == true { authorizationEligible.insert(id) } else { authorizationEligible.remove(id) }
        changed()
      }
      completion(["ok": owned[id] != nil, "routeFenced": revoked.contains(id)]); return
    }
    if kind == "activate" {
      if bridge.isEmpty { bridge = text(payload, "B") }
      if rootPrefix.isEmpty, !text(payload, "root").isEmpty { rootPrefix = "solara.n2." + text(payload, "root") + "." }
      completion(["ok": !draining]); return
    }
    if kind == "fenceGeneration" || kind == "fenceScope" { _ = fence(payload); completion(["ok": true, "routeFenced": true]); return }
    if ["remove", "release", "browserDrain", "finalRemove", "rejectPriorProcessAction"].contains(kind) {
      var ids = fence(payload)
      if kind == "finalRemove" { ids.formUnion(payload["ids"] as? [String] ?? []) }
      if kind == "rejectPriorProcessAction" {
        let prefix = "solara.n2.\(text(payload, "namespace")).\(text(payload, "priorB"))."
        ids = Set(ids.filter { $0.hasPrefix(prefix) && text(payload, "priorB") != text(payload, "currentB") })
      }
      removeExact(Array(ids))
      let finish = { [self] (exact: Set<String>, ready: Bool) in
        guard !retired else { return }
        removeExact(Array(exact))
        settle(exact) { settled in
          let relevant = self.inFlight.intersection(exact).count
          completion(["ok": ready && settled, "settled": ready && settled, "complete": ready && settled, "routeFenced": true, "inFlight": relevant, "N": String(self.revision)])
        }
      }
      if kind == "browserDrain" {
        barrier { [self] ready in
          guard !retired else { return }
          enumerate { [self] rows, waiting in
            guard !retired else { return }
            let livePrefix = rootPrefix.replacingOccurrences(of: "solara.n2.", with: "solara.live.")
            let unknown = Set(rows.keys).union(waiting).filter { !rootPrefix.isEmpty && ($0.hasPrefix(rootPrefix) || $0.hasPrefix(livePrefix)) }
            finish(ids.union(unknown), ready)
          }
        }
      } else { finish(ids, true) }
      return
    }
    if kind == "purgePriorProcesses" {
      rootPrefix = text(payload, "nativePrefix")
      bridge = text(payload, "currentB")
      let responses = earlyResponses
      earlyResponses = []
      for response in responses { decode(id: response.0, identifier: response.1, info: response.2, completion: response.3) }
      enumerate { [self] rows, waiting in
        let livePrefix = rootPrefix.replacingOccurrences(of: "solara.n2.", with: "solara.live.")
        let ids = Set(rows.keys).union(waiting).filter { ($0.hasPrefix(rootPrefix) && !$0.hasPrefix(rootPrefix + bridge + ".")) || ($0.hasPrefix(livePrefix) && !$0.hasPrefix(livePrefix + bridge + ".")) }
        removeExact(Array(ids))
        settle(Set(ids)) { success in completion(["ok": success, "settled": success, "complete": success, "root": payload["root"] ?? "", "currentB": self.bridge]) }
      }
      return
    }
    if kind == "restore" {
      let id = text(payload, "nativeID")
      enumerate { [self] rows, waiting in
        let proof = nativeReceipts[id]
        let accepted = rows[id] != nil && !waiting.contains(id) && allowed(payload) && proof != nil
        if accepted { owned[id] = payload }
        completion(["ok": true, "settled": !inFlight.contains(id) && !removalIDs.contains(id), "accepted": accepted, "removed": rows[id] == nil && !waiting.contains(id), "nativeID": id, "generation": payload["generation"] ?? "", "receipt": proof?["receipt"] ?? "", "N": String(revision)])
      }
      return
    }
    if kind == "validateAction" {
      let token = text(payload, "actionToken")
      let valid = actions[token].map { same($0, payload) && text($0, "action") == text(payload, "action") && allowed(payload) } == true
      completion(["valid": valid, "actionToken": token, "nativeID": payload["nativeID"] ?? "", "generation": payload["generation"] ?? ""]); return
    }
    if kind.hasPrefix("validate") {
      let field = kind == "validateReceipt" || kind == "validateRemoval" ? "receipt" : "barrier"
      let token = text(payload, field)
      let isReceipt = kind == "validateReceipt" || kind == "validateRemoval"
      let settled = isReceipt ? !inFlight.contains(text(payload, "nativeID")) && !removalIDs.contains(text(payload, "nativeID")) : inFlight.isEmpty && removalIDs.isEmpty
      guard var proof = proofs[token], text(proof, "B") == text(payload, "B"), text(proof, "W") == text(payload, "W"), settled else { completion(["valid": false]); return }
      let fields: [String]
      switch kind {
      case "validateReceipt", "validateRemoval": fields = Self.routeKeys + ["N", "receipt"]
      case "validateEnumeration": fields = ["Q", "B", "W", "M", "N", "scope", "lifetime", "root", "profile", "incarnation", "session", "beginN", "endN", "inFlight", "settled", "complete", "ids", "barrier"]
      default: fields = ["B", "W", "N", "applied", "from", "barrier"]
      }
      let identical = fields.allSatisfy { key in
        if proof[key] == nil && payload[key] == nil { return true }
        guard let a = proof[key], let b = payload[key] else { return false }
        return hash(["value": a]) == hash(["value": b])
      }
      let revisionCurrent = kind == "validateReceipt" || kind == "validateRemoval" || number(proof[kind == "validateEnumeration" ? "endN" : "N"]) == revision
      guard identical, revisionCurrent else { completion(["valid": false]); return }
      proof["valid"] = true
      completion(proof); return
    }
    completion(["ok": false, "error": "unsupportedNativeControl"])
  }

  private func consume(_ event: [String: Any]) {
    let kind = text(event, "kind")
    guard let bytes = try? JSONSerialization.data(withJSONObject: event), bytes.count <= 3 * 1024 * 1024 else { invalidate(); return }
    let queuedBytes = events.reduce(0) { $0 + ((try? JSONSerialization.data(withJSONObject: $1))?.count ?? 0) } + entryJSON.reduce(0) { $0 + $1.utf8.count }
    guard queuedBytes + bytes.count <= 64 * 1024 * 1024 else { invalidate(); return }
    if kind == "replayBegin" {
      guard text(event, "B") == bridge, !draining, number(event["W"]) > maximumWatch else { return }
      maximumWatch = number(event["W"])
      watch = text(event, "W")
      replay = event
      entries = []
      entryJSON = []
      events = []
      state = "Replaying"
      return
    }
    guard text(event, "B") == bridge, text(event, "W") == watch, !draining, !retired else { return }
    if kind == "watchInvalidated" { invalidate(); return }
    if kind == "replayEntry" {
      guard let replay, ["B", "W", "H", "snapshot", "count", "hash"].allSatisfy({ $0 == "count" ? number(replay[$0]) == number(event[$0]) : text(replay, $0) == text(event, $0) }), event["entry"] is [String: Any], entries.count < 8192 else { invalidate(); return }
      guard let raw = event["_entryJSON"] as? String, let entry = (try? JSONSerialization.jsonObject(with: Data(raw.utf8))) as? [String: Any] else { invalidate(); return }
      entries.append(entry)
      entryJSON.append(raw)
      return
    }
    if kind == "replayEnd" {
      guard let start = replay, ["B", "W", "H", "snapshot", "count", "hash"].allSatisfy({ $0 == "count" ? number(start[$0]) == number(event[$0]) : text(start, $0) == text(event, $0) }), number(event["count"]) == UInt64(entries.count), hashBytes(Data(("[" + entryJSON.joined(separator: ",") + "]").utf8)) == text(event, "hash") else { invalidate(); return }
      let routes = entries.filter { text($0, "entryType") == "route" }
      applied = number(event["H"])
      busy = true
      let validIDs = Set(routes.filter { $0["withdrawn"] as? Bool != true }.map { text($0, "nativeID") })
      let stale = Set(owned.keys.filter { !validIDs.contains($0) && number(owned[$0]?["M"]) <= number(event["H"]) })
      revoked.formUnion(stale)
      removeExact(Array(stale))
      barrier { [self] settled in
        guard text(event, "W") == watch, !draining, !retired else { return }
        guard settled else { busy = false; invalidate(); return }
        reconcileStores(expectedWatch: text(event, "W")) { [self] reconciled in
          guard text(event, "W") == watch, !draining, !retired else { return }
          guard reconciled else { invalidate(); return }
          reconcile(routes, index: 0, expectedWatch: text(event, "W")) { [self] in
            guard text(event, "W") == watch, !draining, !retired else { return }
            barrier { [self] settled in
              guard text(event, "W") == watch, !draining, !retired else { return }
              guard settled else { busy = false; invalidate(); return }
              finishReplay(event)
            }
          }
        }
      }
      return
    }
    events.append(event)
    if events.count > 8192 { invalidate(); return }
    pump()
  }
  private func reconcileStores(expectedWatch: String, deadline: Date = Date().addingTimeInterval(4.5), completion: @escaping @MainActor @Sendable (Bool) -> Void) {
    enumerate { [self] rows, waiting in
      guard expectedWatch == watch, !draining, !retired else { return }
      if waiting.contains(where: { $0.hasPrefix(rootPrefix) }) {
        if Date() >= deadline { completion(false); return }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.025) { self.reconcileStores(expectedWatch: expectedWatch, deadline: deadline, completion: completion) }
        return
      }
      var orphans = Set<String>()
      for id in Array(delivered.keys) where id.hasPrefix(rootPrefix) && rows[id] == nil { delivered.removeValue(forKey: id) }
      for (id, info) in rows where id.hasPrefix(rootPrefix) {
        guard let owner = owned[id], allowed(owner), let envelope = presented[id], same(envelope, info), text(envelope, "W") == text(info, "W") else { orphans.insert(id); continue }
        if delivered[id] == nil { delivered[id] = owner }
      }
      if orphans.isEmpty { completion(true); return }
      removeExact(Array(orphans))
      settle(orphans) { completion($0) }
    }
  }
  private func acknowledgeRemoval(_ row: [String: Any], completion: @escaping @MainActor @Sendable () -> Void) {
    var value = current(row)
    let proof = mint(value, field: "receipt")
    value["op"] = "nativeRemoved"
    value["receipt"] = proof["receipt"]
    value["N"] = proof["N"]
    value["removed"] = true
    send(value) { _ in completion() }
  }
  private func finishReplay(_ event: [String: Any]) {
    guard state == "Replaying", text(event, "W") == watch, !retired else { return }
    if let delta = events.first {
      events.removeFirst()
      let next = number(delta["M"])
      if text(delta, "kind") == "displayedQuery" || next <= applied { DispatchQueue.main.async { self.finishReplay(event) }; return }
      guard next == applied + 1 else { invalidate(); return }
      let finish = {
        guard self.text(event, "W") == self.watch, self.state == "Replaying", !self.retired else { return }
        self.applied = next
        DispatchQueue.main.async { self.finishReplay(event) }
      }
      if text(delta, "kind") == "display" { postRoute(delta) { _ in finish() } } else { finish() }
      return
    }
    barrier { [self] settled in
      guard text(event, "W") == watch, state == "Replaying", !retired, !draining else { return }
      guard settled else { invalidate(); return }
      if !events.isEmpty { finishReplay(event); return }
      var ack = event.filter { ["B", "W", "H", "snapshot", "count", "hash"].contains($0.key) }
      ack["op"] = "replayAck"
      ack["applied"] = String(applied)
      let proof = mint(ack, field: "barrier")
      ack["N"] = proof["N"]
      ack["barrier"] = proof["barrier"]
      send(ack) { [self] answer in
        guard text(event, "W") == watch, state == "Replaying" else { return }
        busy = false
        replay = nil
        if answer["ok"] as? Bool == true { state = "Live"; acknowledged = applied; compactOwned(); flushActions(); pump() } else { invalidate() }
      }
    }
  }
  private func reconcile(_ routes: [[String: Any]], index: Int, expectedWatch: String, completion: @escaping @MainActor @Sendable () -> Void) {
    guard expectedWatch == watch, state == "Replaying", !draining, !retired else { return }
    guard index < routes.count else { completion(); return }
    var row = routes[index]
    row["B"] = bridge
    row["W"] = watch
    row["M"] = row["routeM"]
    if row["withdrawn"] as? Bool == true {
      let id = text(row, "nativeID")
      revoked.insert(id)
      removeExact([id])
      settle([id]) { [self] _ in DispatchQueue.main.async { self.reconcile(routes, index: index + 1, expectedWatch: expectedWatch, completion: completion) } }
    } else {
      let id = text(row, "nativeID")
      if let newer = owned[id], number(newer["M"]) > number(row["routeM"]) { row = newer; row["W"] = watch }
      else if !revoked.contains(id) { owned[id] = row }
      if row["accepted"] as? Bool == true, delivered[id] == nil {
        acknowledgeRemoval(row) { [self] in DispatchQueue.main.async { self.reconcile(routes, index: index + 1, expectedWatch: expectedWatch, completion: completion) } }
        return
      }
      postRoute(row) { [self] _ in DispatchQueue.main.async { self.reconcile(routes, index: index + 1, expectedWatch: expectedWatch, completion: completion) } }
    }
  }
  private func compactOwned() {
    for id in Array(owned.keys) where revoked.contains(id) && !inFlight.contains(id) && !removalIDs.contains(id) && delivered[id] == nil && pending[id] == nil {
      owned.removeValue(forKey: id)
      authorizationEligible.remove(id)
      nativeReceipts.removeValue(forKey: id)
      presented.removeValue(forKey: id)
    }
  }
  private func invalidate() {
    if !watch.isEmpty { send(["op": "observerLost", "B": bridge, "W": watch]) }
    state = "NoConsumer"
    watch = ""
    events = []
    entries = []
    entryJSON = []
    replay = nil
    busy = false
    if !draining && !retired { NotificationCenter.default.post(name: Notification.Name("SolaraNotificationWatchRequest"), object: nil) }
  }
  private func pump() {
    guard !busy, state == "Live", let event = events.first else { return }
    events.removeFirst()
    if text(event, "kind") == "displayedQuery" { displayed(event); pump(); return }
    let next = number(event["M"])
    if next <= applied { pump(); return }
    guard next == applied + 1 else { invalidate(); return }
    busy = true
    let finish = { [self] in
      guard text(event, "W") == watch, text(event, "B") == bridge, state == "Live" else { return }
      applied = next
      barrier { [self] settled in
        guard text(event, "W") == watch, state == "Live" else { return }
        guard settled else { busy = false; invalidate(); return }
        var ack: [String: Any] = ["op": "liveAck", "B": bridge, "W": watch, "from": String(acknowledged), "applied": String(applied)]
        let proof = mint(ack, field: "barrier")
        ack["N"] = proof["N"]
        ack["barrier"] = proof["barrier"]
        send(ack) { [self] value in
          guard text(event, "W") == watch, state == "Live" else { return }
          busy = false
          if value["ok"] as? Bool == true { acknowledged = next; compactOwned(); pump() } else { invalidate() }
        }
      }
    }
    if text(event, "kind") == "display" { postRoute(event) { _ in finish() } }
    else { finish() }
  }
  private func displayed(_ event: [String: Any]) {
    let captured = revision
    barrier { [self] settled in
      enumerate { [self] rows, waiting in
        guard !retired, !draining, text(event, "W") == watch, state == "Live" else { return }
        var ids: [[String: Any]] = []
        var orphans = Set<String>()
        for id in rows.keys where id.hasPrefix(rootPrefix) {
          if let row = owned[id], allowed(row), text(row, "scope") == text(event, "scope") {
            ids.append(["token": row["token"] ?? "", "generation": row["generation"] ?? "", "nativeID": id])
          } else if owned[id] == nil || revoked.contains(id) { orphans.insert(id) }
        }
        if !orphans.isEmpty { removeExact(Array(orphans)) }
        ids.sort { text($0, "nativeID") < text($1, "nativeID") }
        var answer = event.filter { ["Q", "B", "W", "M", "N", "scope", "lifetime", "root", "profile", "incarnation", "session"].contains($0.key) }
        answer["op"] = "displayedAnswer"
        answer["beginN"] = String(captured)
        answer["endN"] = String(revision)
        answer["inFlight"] = inFlight.count
        answer["settled"] = settled && captured == revision && inFlight.isEmpty && waiting.isEmpty && orphans.isEmpty
        answer["complete"] = state == "Live" && text(event, "W") == watch
        answer["ids"] = ids
        var proof = mint(answer, field: "barrier")
        proof["idsHash"] = hash(ids)
        proofs[text(proof, "barrier")] = proof
        answer["barrier"] = proof["barrier"]
        send(answer)
      }
    }
  }

  func debugRespond(_ id: String, identifier: String, completion: @escaping @MainActor @Sendable ([String: Any]) -> Void) {
    guard simulated else { completion(["accepted": false]); return }
    decode(id: id, identifier: identifier, info: presented[id] ?? delivered[id].map(route) ?? [:], completion: completion)
  }
  private func decode(id: String, identifier: String, info: [String: Any], completion: @escaping @MainActor @Sendable ([String: Any]) -> Void) {
    if !rootPrefix.isEmpty, !bridge.isEmpty, id.hasPrefix(rootPrefix), !id.hasPrefix(rootPrefix + bridge + ".") {
      removeExact([id])
      settle([id]) { removed in completion(["accepted": false, "error": "priorProcessAction", "removed": removed]) }
      return
    }
    let action = identifier == UNNotificationDefaultActionIdentifier ? "click" : identifier == UNNotificationDismissActionIdentifier ? "close" : ""
    guard !action.isEmpty, Set(info.keys) == Set(Self.routeKeys), Self.routeKeys.allSatisfy({ key in
      guard let value = info[key] as? String else { return false }
      return value.utf8.count <= (key == "profile" ? 4096 : key == "nativeID" ? 512 : 256)
    }), number(info["W"]) > 0, String(number(info["W"])) == text(info, "W"), number(info["generation"]) > 0, String(number(info["generation"])) == text(info, "generation"), text(info, "nativeID") == id else { completion(["accepted": false]); return }
    if rootPrefix.isEmpty || bridge.isEmpty {
      guard earlyResponses.count < 128 else { completion(["accepted": false]); return }
      earlyResponses.append((id, identifier, info, completion))
      DispatchQueue.main.asyncAfter(deadline: .now() + 5) { [self] in
        if let index = earlyResponses.firstIndex(where: { $0.0 == id && $0.1 == identifier }) { let response = earlyResponses.remove(at: index); response.3(["accepted": false, "error": "bootstrapIncomplete"]) }
      }
      return
    }
    guard text(info, "B") == bridge, text(info, "creation") == bridge, id == rootPrefix + bridge + "." + text(info, "token") + "." + text(info, "generation") else { completion(["accepted": false]); return }
    guard let original = presented[id], same(original, info), text(original, "W") == text(info, "W"), let owner = owned[id], allowed(owner), ["B", "root", "profile", "incarnation", "session", "token", "creation", "generation", "nativeID"].allSatisfy({ text(original, $0) == text(owner, $0) }), actions.count < 128 else { completion(["accepted": false]); return }
    let token = UUID().uuidString
    var payload = current(owner)
    payload["op"] = "action"
    payload["action"] = action
    payload["actionToken"] = token
    actions[token] = payload
    queuedActions.insert(token)
    completion(["accepted": true, "token": token])
    DispatchQueue.main.asyncAfter(deadline: .now() + 5) { [self] in
      guard !retired else { return }
      guard queuedActions.remove(token) != nil else { return }
      actions.removeValue(forKey: token)
      record(["kind": "operation", "token": token, "state": "settled", "engineCompleted": false, "error": "consumerUnavailable"])
    }
    flushActions()
  }
  private func flushActions() {
    guard state == "Live", !watch.isEmpty, !draining, !retired else { return }
    for token in Array(queuedActions) {
      guard let original = actions[token], let owner = owned[text(original, "nativeID")], allowed(owner) else {
        queuedActions.remove(token)
        actions.removeValue(forKey: token)
        record(["kind": "operation", "token": token, "state": "settled", "engineCompleted": false, "error": "routeRevoked"])
        continue
      }
      var payload = current(owner)
      payload["op"] = "action"
      payload["action"] = original["action"]
      payload["actionToken"] = token
      actions[token] = payload
      queuedActions.remove(token)
      send(payload) { [self] result in
        guard !retired else { return }
        actions.removeValue(forKey: token)
        record(result.merging(["kind": "operation", "token": token, "state": "settled"]) { _, b in b })
      }
    }
  }

  func flushPending() {
    guard let onResponse else { return }
    let responses = liveResponses
    liveResponses = []
    responses.forEach { onResponse($0.0, $0.1, $0.2) }
  }
  func snapshot() -> [String: Any] {
    var truncated = diagnosticDrops > 0
    var used = 0
    func bounded(_ rows: [[String: Any]]) -> [[String: Any]] {
      var result: [[String: Any]] = []
      for row in rows {
        let detail = diagnosticRow(row)
        let size = (try? JSONSerialization.data(withJSONObject: detail))?.count ?? 0
        if used + size > 256 * 1024 { truncated = true; continue }
        used += size
        result.append(detail)
      }
      return result
    }
    let pendingRows = bounded(Array(pending.values))
    let deliveredRows = bounded(Array(delivered.values))
    return ["mode": simulated ? "memory" : "system", "authorizationStatus": simulated ? "simulated" : authorizationStatus, "realEffects": effects, "watch": ["state": state, "B": bridge, "W": watch, "applied": String(applied)], "pending": pendingRows, "delivered": deliveredRows, "pendingCount": pending.count, "deliveredCount": delivered.count, "inFlight": inFlight.count, "removalCount": removalIDs.count, "posts": receipts.filter { text($0, "kind") == "post" }, "acks": receipts.filter { text($0, "kind") == "ack" }, "operations": receipts.filter { text($0, "kind") == "operation" }, "N": String(revision), "diagnosticsComplete": !truncated, "truncated": truncated, "diagnosticDrops": diagnosticDrops]
  }
  func debugRestorePrior(_ envelope: [String: Any]) -> Bool {
    guard simulated, !draining, !retired, Set(envelope.keys).isSubset(of: Set(Self.routeKeys)) else { return false }
    let id = text(envelope, "nativeID")
    guard !rootPrefix.isEmpty, id.hasPrefix(rootPrefix), text(envelope, "B") != bridge,
          id.hasPrefix(rootPrefix + text(envelope, "B") + "."), text(envelope, "nativeID") == id else { return false }
    delivered[id] = envelope
    changed()
    return true
  }
  private func completePost(_ id: String, value: String?) { postCompletions.removeValue(forKey: id)?.finish(value) }
  func post(_ options: [String: Any], completion: @escaping @MainActor @Sendable (String?) -> Void) {
    guard !retired, !draining, !rootPrefix.isEmpty, !bridge.isEmpty,
          let bytes = try? JSONSerialization.data(withJSONObject: options), let options = (try? JSONSerialization.jsonObject(with: bytes)) as? [String: Any] else { completion(nil); return }
    let logical = options["id"] as? String ?? UUID().uuidString
    let livePrefix = rootPrefix.replacingOccurrences(of: "solara.n2.", with: "solara.live.")
    let id = livePrefix + bridge + "." + hashBytes(Data(logical.utf8)) + "." + UUID().uuidString
    if let previous = liveBindings[logical] { revoked.insert(previous); removeExact([previous]) }
    liveBindings[logical] = id
    liveIDs.insert(id)
    inFlight.insert(id)
    pending[id] = ["nativeID": id]
    postCompletions[id] = NotificationPostCompletion(completion)
    let envelope: [String: Any] = ["live": true, "logicalID": logical, "data": options["data"] ?? [:]]
    changed()
    let finish: @MainActor @Sendable (Bool) -> Void = { [self] success in
      guard !retired else { completePost(id, value: nil); return }
      inFlight.remove(id)
      pending.removeValue(forKey: id)
      submitted.removeValue(forKey: id)
      changed()
      if success && (draining || revoked.contains(id) || liveBindings[logical] != id) {
        removeExact([id]); settle([id]) { [self] _ in completePost(id, value: nil) }; return
      }
      if success { delivered[id] = options.merging(["nativeID": id]) { _, b in b }; presented[id] = envelope }
      completePost(id, value: success ? id : nil)
    }
    deliveryPermission { [self] granted in
      guard granted, !draining, !retired, !revoked.contains(id), liveBindings[logical] == id else {
        record(["kind": "post", "nativeID": id, "status": "suppressed", "authorizationStatus": authorizationStatus])
        finish(false); return
      }
      submitted[id] = envelope
      if simulated { finish(true); return }
      install()
      let content = UNMutableNotificationContent()
      content.title = text(options, "title")
      content.body = text(options, "body")
      content.userInfo = envelope
      if options["silent"] as? Bool != true { content.sound = .default }
      submit(id: id, content: content, completion: finish)
    }
  }
  func remove(_ ids: [String]) {
    let exact = ids.compactMap { $0.hasPrefix("solara.live.") ? $0 : liveBindings[$0] }
    revoked.formUnion(exact)
    removeExact(exact)
  }
  private func liveAllowed(_ id: String, info: [String: Any]) -> Bool {
    let livePrefix = rootPrefix.replacingOccurrences(of: "solara.n2.", with: "solara.live.")
    let logical = text(info, "logicalID")
    guard !draining, !retired, !rootPrefix.isEmpty, !bridge.isEmpty, !revoked.contains(id), liveIDs.contains(id), liveBindings[logical] == id,
          id.hasPrefix(livePrefix + bridge + "."), let expected = submitted[id] ?? presented[id] else { return false }
    return NSDictionary(dictionary: expected).isEqual(to: info)
  }
  private func presentationAllowed(_ id: String, info: [String: Any]) -> Bool {
    if id.hasPrefix("solara.live.") { return liveAllowed(id, info: info) }
    guard !rootPrefix.isEmpty, !bridge.isEmpty, id == rootPrefix + bridge + "." + text(info, "token") + "." + text(info, "generation"),
          Set(info.keys) == Set(Self.routeKeys), Self.routeKeys.allSatisfy({ info[$0] is String }),
          let original = submitted[id] ?? presented[id], same(original, info), text(original, "W") == text(info, "W"),
          let owner = owned[id], allowed(owner), ["B", "root", "profile", "incarnation", "session", "token", "creation", "generation", "nativeID"].allSatisfy({ text(original, $0) == text(owner, $0) }),
          text(info, "B") == bridge, text(info, "creation") == bridge, text(info, "nativeID") == id else { return false }
    return true
  }
  nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification, withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void) {
    let id = notification.request.identifier
    let bytes = try? JSONSerialization.data(withJSONObject: notification.request.content.userInfo)
    let sound = notification.request.content.sound != nil
    let reply = NotificationDelegateCompletion(completionHandler)
    DispatchQueue.main.async { [weak self] in
      guard let self, let bytes, let info = (try? JSONSerialization.jsonObject(with: bytes)) as? [String: Any], self.presentationAllowed(id, info: info) else { reply.finish([]); return }
      var options: UNNotificationPresentationOptions = [.banner, .list]
      if sound { options.insert(.sound) }
      reply.finish(options)
    }
  }
  nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse, withCompletionHandler completionHandler: @escaping () -> Void) {
    let id = response.notification.request.identifier
    let identifier = response.actionIdentifier
    let bytes = try? JSONSerialization.data(withJSONObject: response.notification.request.content.userInfo)
    let textInput = response is UNTextInputNotificationResponse
    let reply = NotificationDelegateCompletion<Void> { _ in completionHandler() }
    DispatchQueue.main.async { [weak self] in
      defer { reply.finish(()) }
      guard let self else { return }
      let info = bytes.flatMap { (try? JSONSerialization.jsonObject(with: $0)) as? [String: Any] } ?? [:]
      if textInput {
        let livePrefix = self.rootPrefix.replacingOccurrences(of: "solara.n2.", with: "solara.live.")
        if !self.rootPrefix.isEmpty, id.hasPrefix(livePrefix), !id.hasPrefix(livePrefix + self.bridge + ".") { self.removeExact([id]) }
        else { self.decode(id: id, identifier: "unsupportedTextInput", info: info) { _ in } }
        return
      }
      if id.hasPrefix("solara.live.") {
        guard self.liveAllowed(id, info: info), let data = info["data"] as? [String: Any] else { self.removeExact([id]); return }
        let action = identifier == UNNotificationDefaultActionIdentifier ? "click" : identifier == UNNotificationDismissActionIdentifier ? "close" : ""
        if !action.isEmpty {
          let logical = self.text(info, "logicalID")
          if action == "click" && !self.simulated { NSApp.activate() }
          if let onResponse = self.onResponse { onResponse(logical, action, ["data": data]) }
          else if self.liveResponses.count < 128 { self.liveResponses.append((logical, action, ["data": data])) }
        }
        return
      }
      self.decode(id: id, identifier: identifier, info: info) { _ in }
    }
  }
}

@MainActor public enum ShellLiveNotifications {
  public static func requestCalendarAlertPermission() async -> Bool {
    await withCheckedContinuation { continuation in
      NotificationHub.shared.requestPermission { continuation.resume(returning: $0) }
    }
  }
  public static func post(id: String, title: String, body: String, data: [String: String]) async -> Bool {
    await withCheckedContinuation { continuation in
      NotificationHub.shared.post(["id": id, "title": title, "body": body, "data": data]) { continuation.resume(returning: $0 != nil) }
    }
  }
  public static func remove(ids: [String]) { NotificationHub.shared.remove(ids) }
}
