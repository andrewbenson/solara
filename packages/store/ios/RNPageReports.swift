import AppKit
import Foundation
import SolaraCore
internal import SolaraModel
internal import SolaraOmnibox
internal import SolaraStore
internal import SolaraUI

@MainActor
enum RNPageReports {
  private final class Attachment {
    weak var owner: NSView?
    weak var page: NSView?
    let tabId: String
    let engine: PageEngine
    let profile: String
    let runtimeID: UUID?
    let emit: @MainActor (String, [String: Any]) -> Void
    var binding: PageHostBinding?
    var execution = PageExecutionMemory(initial: nil)
    var detached = false

    init(owner: NSView, page: NSView, tabId: String, engine: PageEngine, profile: String, runtimeID: UUID?,
      emit: @escaping @MainActor (String, [String: Any]) -> Void) {
      self.owner = owner
      self.page = page
      self.tabId = tabId
      self.engine = engine
      self.profile = profile
      self.runtimeID = runtimeID
      self.emit = emit
    }
  }

  private static var issuer: PageIssuer?
  private static var runtimeID: UUID?
  private static var attachments: [ObjectIdentifier: Attachment] = [:]

  static func install(issuer: PageIssuer?) {
    self.issuer = issuer
    if let runtimeID { issuer?.beginRuntime(runtimeID) }
    RNPageEventTap.install(RNPageHostHooks(attach: { @MainActor in attach(owner: $0, page: $1, tabId: $2, engine: $3, profile: $4, initialContext: $5, previous: $6, emit: $7) }, start: { @MainActor in start($0, action: $1) }, detach: detach, reserve: reserve, call: call,
      deliver: { @MainActor work in
        if let issuer { issuer.afterSequence(work) }
        else { work() }
      }))
  }

  static func beginRuntime(_ id: UUID) {
    guard runtimeID != id else { return }
    if let old = runtimeID { endRuntime(old) }
    runtimeID = id
    issuer?.beginRuntime(id)
  }

  static func endRuntime(_ id: UUID) {
    guard runtimeID == id else { return }
    issuer?.endRuntime(id)
    for attachment in attachments.values where attachment.runtimeID == id {
      attachment.detached = true
      if let binding = attachment.binding { issuer?.retire(binding) }
    }
    attachments = attachments.filter { $0.value.runtimeID != id }
    runtimeID = nil
  }

  private static func attach(owner: NSView, page: NSView, tabId: String?, engine: String, profile: String,
    initialContext: [String: Any], previous: RNPageAttachment?, emit: @escaping @MainActor (String, [String: Any]) -> Void) -> RNPageAttachment? {
    guard NativeStore.ownsWorkspace, let issuer, let tabId, !tabId.isEmpty,
      let engine = PageEngine(rawValue: engine) else { return nil }
    return issuer.store.sequence {
      let suppliedContext = (try? JSONSerialization.data(withJSONObject: initialContext)).flatMap { data in
        (try? JSONValue.parse(data)).flatMap { Self.context($0) }
      }
      if let previous, let attachment = previous.value as? Attachment {
        guard attachment.owner === owner, attachment.page === page, attachment.tabId == tabId,
          attachment.engine == engine, attachment.profile == profile, attachment.runtimeID == runtimeID,
          !attachment.detached, let binding = attachment.binding else { return previous }
        _ = issuer.ensurePageEstablished(binding)
        if let suppliedContext { _ = issuer.updateContext(binding, context: suppliedContext) }
        return previous
      }
      let attachment = Attachment(owner: owner, page: page, tabId: tabId, engine: engine, profile: profile,
        runtimeID: runtimeID, emit: emit)
      let handle = RNPageAttachment(attachment, allowsStart: false)
      attachments[ObjectIdentifier(owner)] = attachment
      guard runtimeID != nil, let tab = issuer.store.state.tabs[tabId],
        issuer.store.state.engineProfile(tab.profileId) == profile else { return handle }
      attachment.execution = PageExecutionMemory(initial: navigation(tab.navigation))
      let navigationSeq = tab.navigation.flatMap { Int(exactly: $0.seq) }
      let context = PageHostContext.initial(navigationSeq: navigationSeq, wasNewTab: tab.url.isEmpty,
        cached: suppliedContext.map { .object($0.json) })
      attachment.binding = issuer.attach(tabId: tabId, engine: engine, host: .reactNative, owner: owner,
        runtimeID: runtimeID, context: context,
        onCreated: { binding, reestablished in
          issuer.noteDelivery(binding)
          var payload = identity(binding)
          payload["generation"] = binding.sessionGeneration
          payload["reestablished"] = reestablished
          emit("onPageCreated", payload)
        },
        onClearNewTabShown: { binding, consumed in
          var payload = identity(binding)
          payload["accepted"] = true
          payload["clearNewTabShown"] = true
          payload["contextRevision"] = consumed.contextRevision
          payload["navigation"] = PageValue(json: consumed.json["navigation"] ?? .null).foundation
          emit("onPageIssue", payload)
        },
        onNeedsFollow: { binding in
          var payload = identity(binding)
          payload["retry"] = true
          emit("onPageIssue", payload)
        }, perform: { [weak attachment] command, finish in
          guard let attachment, let page = attachment.page else { finish(.failure(.noPage(tabId))); return }
          if case .loadUrl(let url, let userInitiated) = command {
            var current: SolaraModel.Navigation?
            if let binding = attachment.binding,
              let snapshot = try? issuer.store.pageHostSnapshotInScope(tabId, generation: binding.sessionGeneration) {
              current = snapshot.state.tabs[tabId]?.navigation
            }
            attachment.execution.stage(navigation: navigation(current), url: toAppUrl(url), userInitiated: userInitiated)
          }
          defer { attachment.execution.finishStaging() }
          var arguments = command.arguments.map(\.foundation)
          if case .loadUrl(let url, _) = command { arguments[0] = toEngineUrl(url) }
          PageCalls.run(page, command.method, arguments, resolve: { result in
            do { finish(.success(try PageValue(any: result))) }
            catch { finish(.failure(.invalidValue)) }
          }, reject: { code, message in finish(.failure(.failed("\(code): \(message)"))) })
        })
      handle.allowsStart = attachment.binding != nil
      return handle
    }
  }

  private static func start(_ handle: RNPageAttachment, action: @escaping @MainActor () -> Void) {
    guard let issuer, let attachment = handle.value as? Attachment, !attachment.detached,
      attachment.runtimeID == runtimeID, let binding = attachment.binding else { return }
    issuer.store.sequence {
      guard issuer.ensurePageEstablished(binding) else { return }
      action()
    }
  }

  private static func detach(_ handle: RNPageAttachment) {
    guard let attachment = handle.value as? Attachment, !attachment.detached else { return }
    attachment.detached = true
    if let binding = attachment.binding { issuer?.retire(binding) }
    if let owner = attachment.owner, attachments[ObjectIdentifier(owner)] === attachment {
      attachments[ObjectIdentifier(owner)] = nil
    }
  }

  private static func reserve(_ handle: RNPageAttachment, _ name: String, _ payload: [String: Any]) -> RNPageReportDisposition {
    guard let attachment = handle.value as? Attachment else { return .rejected(sessionGeneration: nil, registrationGeneration: nil) }
    guard let issuer, !attachment.detached, attachment.runtimeID == runtimeID,
      let binding = attachment.binding else { return rejected(attachment.binding) }
    return issuer.store.sequence {
      guard issuer.ensurePageEstablished(binding) else { return rejected(binding) }
      if name == "onPageConstructorCaptured", let url = payload["url"] as? String {
        attachment.execution.constructorCaptured(url: toAppUrl(url))
      } else if name == "onPageRequestAccepted", let url = payload["url"] as? String {
        attachment.execution.accepted(url: toAppUrl(url))
      } else if name == "onPagePhysical", let physicalPage = payload["page"] as? NSView {
        issuer.transferExecution(from: physicalPage, to: binding)
        issuer.associateNativePage(binding, page: physicalPage)
      } else if name == "onPageExecution", let url = payload["url"] as? String {
        let sequence = attachment.execution.executed(url: toAppUrl(url), constructor: payload["constructor"] as? Bool ?? false)
        issuer.noteExecuted(binding, navigationSeq: sequence)
      } else {
        guard let payload = json(payload), let sequence = issuer.reserveEvent(binding, name: name, payload: payload) else { return rejected(binding) }
        issuer.noteDelivery(binding)
        return .reserved(sessionGeneration: binding.sessionGeneration, registrationGeneration: binding.registrationGeneration, eventSeq: sequence)
      }
      guard issuer.isCurrent(binding) else { return rejected(binding) }
      return .reserved(sessionGeneration: binding.sessionGeneration, registrationGeneration: binding.registrationGeneration)
    }
  }

  private static func call(_ handle: RNPageAttachment?, _ page: NSView, _ transferKey: String?, _ propsReady: Bool,
    _ method: String, _ args: [Any], resolve: @escaping @MainActor @Sendable (Any?) -> Void,
    reject: @escaping @MainActor @Sendable (String, String) -> Void) {
    guard let handle else {
      guard RNPageCallPolicy.allowsUnattachedFallback(ownsWorkspace: NativeStore.ownsWorkspace,
        transferKey: transferKey, propsReady: propsReady) else {
        if let issuer { issuer.afterSequence { @MainActor in reject("ERR_PAGE_UNATTACHED", "The workspace page has not attached") } }
        else { reject("ERR_PAGE_UNATTACHED", "The workspace page has not attached") }
        return
      }
      PageCalls.run(page, method, args, resolve: { resolve($0) }, reject: { reject($0, $1) })
      return
    }
    guard let issuer, let attachment = handle.value as? Attachment,
      !attachment.detached, attachment.runtimeID == runtimeID, let binding = attachment.binding else {
      if let issuer { issuer.afterSequence { @MainActor in reject("ERR_PAGE_RETIRED", "The native page attachment retired") } }
      else { reject("ERR_PAGE_RETIRED", "The native page attachment retired") }
      return
    }
    do {
      let command = try PageCommand.decode(method: method, args: args.map { try PageValue(any: $0) })
      issuer.issue(tabId: attachment.tabId, identity: binding.identity, command: command) { @MainActor result in
        switch result {
        case .success(let value): resolve(value == .null ? nil : value.foundation)
        case .failure(let error): reject(error.code, error.message)
        }
      }
    } catch let error as PageRegistryError {
      issuer.afterSequence { @MainActor in reject(error.code, error.message) }
    } catch {
      issuer.afterSequence { @MainActor in reject("ERR_PAGE_VALUE", "Invalid page command arguments") }
    }
  }

  static func protectionKnown(tabId: String, sessionGeneration: String) -> Bool {
    guard let issuer, let binding = issuer.binding(tabId: tabId),
      binding.sessionGeneration == sessionGeneration else { return false }
    return issuer.protectionKnown(binding)
  }

  static func isPageCurrent(tabId: String, sessionGeneration: String, registrationGeneration: Double) -> Bool {
    guard registrationGeneration.isFinite, registrationGeneration > 0, registrationGeneration <= 9_007_199_254_740_991,
      registrationGeneration.rounded(.towardZero) == registrationGeneration,
      let issuer, let binding = issuer.binding(tabId: tabId), binding.sessionGeneration == sessionGeneration,
      binding.registrationGeneration == UInt64(registrationGeneration),
      binding.host != .reactNative || binding.runtimeID == runtimeID else { return false }
    return issuer.isCurrent(binding)
  }

  static func updatePageContext(tabId: String, sessionGeneration: String, registrationGeneration: Double, contextJSON: String) -> Bool {
    guard isPageCurrent(tabId: tabId, sessionGeneration: sessionGeneration, registrationGeneration: registrationGeneration),
      let issuer, let binding = issuer.binding(tabId: tabId), binding.sessionGeneration == sessionGeneration,
      binding.registrationGeneration == UInt64(registrationGeneration), let value = try? JSONValue.parse(contextJSON),
      let context = context(value) else { return false }
    return issuer.updateContext(binding, context: context)
  }

  static func isCurrent(tabId: String, sessionGeneration: String) -> Bool {
    guard let issuer, let binding = issuer.binding(tabId: tabId), binding.host == .reactNative,
      binding.runtimeID == runtimeID, binding.sessionGeneration == sessionGeneration else { return false }
    return issuer.isCurrent(binding)
  }

  static func updateContext(tabId: String, sessionGeneration: String, contextJSON: String) -> Bool {
    guard let issuer, let binding = issuer.binding(tabId: tabId), binding.host == .reactNative,
      binding.runtimeID == runtimeID, binding.sessionGeneration == sessionGeneration,
      let value = try? JSONValue.parse(contextJSON), let context = context(value) else { return false }
    return issuer.updateContext(binding, context: context)
  }

  static func finish(tabId: String, guardJSON: String, resolve: @escaping (Any?) -> Void, reject: @escaping (String, String) -> Void) {
    guard let issuer, let binding = issuer.binding(tabId: tabId), binding.host == .reactNative,
      binding.runtimeID == runtimeID else { resolve(["accepted": false]); return }
    do {
      let guardValue = try PageIssueGuard(json: JSONValue.parse(guardJSON))
      issuer.issue(tabId: tabId, identity: binding.identity, command: .finishPageIssue(guardValue)) { result in
        switch result {
        case .success(let value): resolve(value.foundation)
        case .failure: resolve(["accepted": false])
        }
      }
    } catch { issuer.afterSequence { reject("ERR_PAGE_ARGS", "Invalid page issue guard") } }
  }

  static func normalize(_ commands: [Command]) throws -> [Command] {
    guard let issuer else { return commands }
    return commands.map { command in
      guard command.name == "pageReport", command.args.count >= 2,
        let tabId = command.args[0].string, let generation = command.args[1]["generation"]?.string,
        let binding = issuer.binding(tabId: tabId), binding.host == .reactNative,
        binding.sessionGeneration == generation, binding.runtimeID == runtimeID else { return command }
      var command = command
      if command.args[1]["type"]?.string == "issued", var report = command.args[1].object {
        let flags = issuer.executionFlags(binding, navigationSeq: safeInteger(report["navigation"]?["seq"]))
        report["startedEarly"] = .bool(flags?.startedEarly ?? false)
        report["sameProfileMove"] = .bool(flags?.sameProfileMove ?? false)
        command.args[1] = .object(report)
      }
      return command
    }
  }

  private static func context(_ value: JSONValue) -> PageHostContext? {
    PageHostContext(json: value)
  }

  private static func navigation(_ value: SolaraModel.Navigation?) -> TabNavigationRequest? {
    guard let value, let sequence = Int(exactly: value.seq) else { return nil }
    return TabNavigationRequest(seq: sequence, url: toAppUrl(value.url), userInitiated: value.userInitiated ?? false)
  }

  private static func safeInteger(_ value: JSONValue?) -> Int? {
    guard let number = value?.number, number.isFinite, number.rounded() == number,
      number >= 0, number <= 9_007_199_254_740_991 else { return nil }
    return Int(exactly: number)
  }

  private static func identity(_ binding: PageHostBinding) -> [String: Any] {
    ["tabId": binding.tabId, "sessionGeneration": binding.sessionGeneration,
      "registrationGeneration": binding.registrationGeneration]
  }

  private static func rejected(_ binding: PageHostBinding?) -> RNPageReportDisposition {
    .rejected(sessionGeneration: binding?.sessionGeneration, registrationGeneration: binding?.registrationGeneration)
  }

  private static func json(_ value: Any) -> JSONValue? {
    guard let data = try? JSONSerialization.data(withJSONObject: value, options: [.fragmentsAllowed]) else { return nil }
    return try? JSONValue.parse(data)
  }
}
