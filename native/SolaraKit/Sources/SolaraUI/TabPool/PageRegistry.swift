import Foundation
import Synchronization

public typealias PageRegistrationGeneration = UInt64

private let pageRegistrationGenerations = Mutex<PageRegistrationGeneration>(0)

private func nextPageRegistrationGeneration() -> PageRegistrationGeneration {
  pageRegistrationGenerations.withLock { value in
    precondition(value < 9_007_199_254_740_991)
    value += 1
    return value
  }
}

public struct PageRegistration: Equatable, Hashable, Sendable {
  public let tabID: String
  public let registrationGeneration: PageRegistrationGeneration

  public init(tabID: String, registrationGeneration: PageRegistrationGeneration) {
    self.tabID = tabID
    self.registrationGeneration = registrationGeneration
  }
}

public struct PageDescriptor: Equatable, Sendable {
  public let registration: PageRegistration
  public let engine: PageEngine
  public let host: PageHost
  public let nativeTag: Int?
  public var tabID: String { registration.tabID }
  public var registrationGeneration: PageRegistrationGeneration { registration.registrationGeneration }
}

public enum PageRegistryEvent: Equatable, Sendable {
  case registered(PageDescriptor)
  case retired(PageRegistration)
}

public enum PageRegistryError: Error, Equatable, Sendable, LocalizedError {
  case noPage(String)
  case retired(PageRegistration)
  case unsupported(PageEngine, String)
  case invalidArguments(String, Int)
  case unknownCommand(String)
  case invalidValue
  case failed(String)
  case timedOut(PageRegistration)
  case cancelled(PageRegistration)

  public var code: String {
    switch self {
    case .noPage: "ERR_NO_PAGE"
    case .retired: "ERR_PAGE_RETIRED"
    case .unsupported: "ERR_UNSUPPORTED_COMMAND"
    case .invalidArguments: "ERR_PAGE_ARGS"
    case .unknownCommand: "ERR_PAGE_METHOD"
    case .invalidValue: "ERR_PAGE_VALUE"
    case .failed: "ERR_PAGE_CALL"
    case .timedOut: "ERR_PAGE_TIMEOUT"
    case .cancelled: "ERR_PAGE_CANCELLED"
    }
  }

  public var message: String {
    switch self {
    case .noPage(let id): "No live page for \(id)"
    case .retired(let token): "Page \(token.tabID) registration \(token.registrationGeneration) retired"
    case .unsupported(let engine, let method): "\(engine.rawValue) does not support \(method)"
    case .invalidArguments(let method, let index): "\(method): argument \(index) is missing or invalid"
    case .unknownCommand(let method): "Unknown page method \(method)"
    case .invalidValue: "Invalid page result or non-JSON value"
    case .failed(let message): message
    case .timedOut(let token): "Page \(token.tabID) registration \(token.registrationGeneration) did not reply before its deadline"
    case .cancelled(let token): "Page \(token.tabID) registration \(token.registrationGeneration) call cancelled"
    }
  }

  public var errorDescription: String? { message }
}

@MainActor
public final class PageRegistry {
  public typealias Completion = @MainActor (Result<PageValue, PageRegistryError>) -> Void
  public typealias Perform = @MainActor (PageCommand, @escaping Completion) -> Void
  public typealias Deliver = @MainActor (@escaping @MainActor () -> Void) -> Void
  typealias ScheduleTimeout = @MainActor (Duration, @escaping @MainActor () -> Void) -> (@MainActor () -> Void)
  public static let shared = PageRegistry()

  private struct Entry {
    let descriptor: PageDescriptor
    let perform: Perform
  }

  private struct Pending {
    let registration: PageRegistration
    let resultKind: PageResultKind
    let completion: Completion
    var cancelDeadline: (@MainActor () -> Void)?
  }

  @MainActor
  private final class AwaitingCall {
    var id: UUID?
  }

  private let timeout: Duration
  private var deliver: Deliver
  private let scheduleTimeout: ScheduleTimeout
  private var hasRegistered = false
  private var entries: [String: Entry] = [:]
  private var pending: [UUID: Pending] = [:]
  private var pendingOrder: [UUID] = []
  private var observers: [(id: UUID, receive: @MainActor (PageRegistryEvent) -> Void)] = []
  private var deliveries: [@MainActor () -> Void] = []
  private var deliveryPending = false
  private var deliveryID: UUID?
  private var schedulingDelivery = false

  public convenience init(timeout: Duration = .seconds(30), deliver: @escaping Deliver = { $0() }) {
    self.init(timeout: timeout, deliver: deliver, scheduleTimeout: Self.makeTimeout)
  }

  init(timeout: Duration = .seconds(30), deliver: @escaping Deliver = { $0() }, scheduleTimeout: @escaping ScheduleTimeout) {
    precondition(timeout > .zero)
    self.timeout = timeout
    self.deliver = deliver
    self.scheduleTimeout = scheduleTimeout
  }

  isolated deinit {
    for item in pending.values { item.cancelDeadline?() }
  }

  @discardableResult
  public func configureDelivery(_ deliver: @escaping Deliver) -> Bool {
    guard !hasRegistered, deliveries.isEmpty, !deliveryPending, !schedulingDelivery else { return false }
    self.deliver = deliver
    return true
  }

  private static func makeTimeout(_ duration: Duration, _ action: @escaping @MainActor () -> Void) -> @MainActor () -> Void {
    let task = Task { @MainActor in
      do { try await Task.sleep(for: duration) } catch { return }
      action()
    }
    return { task.cancel() }
  }

  public var descriptors: [PageDescriptor] {
    entries.values.map(\.descriptor).sorted { $0.tabID < $1.tabID }
  }

  public func descriptor(_ registration: PageRegistration) -> PageDescriptor? {
    guard let entry = entries[registration.tabID], entry.descriptor.registration == registration else { return nil }
    return entry.descriptor
  }

  @discardableResult
  public func observe(_ observer: @escaping @MainActor (PageRegistryEvent) -> Void) -> UUID {
    let id = UUID()
    observers.append((id, observer))
    return id
  }

  public func removeObserver(_ id: UUID) { observers.removeAll { $0.id == id } }

  @discardableResult
  public func register(tabID: String, engine: PageEngine, host: PageHost, nativeTag: Int? = nil, perform: @escaping Perform) -> PageRegistration {
    let token = PageRegistration(tabID: tabID, registrationGeneration: nextPageRegistrationGeneration())
    hasRegistered = true
    let descriptor = PageDescriptor(registration: token, engine: engine, host: host, nativeTag: nativeTag)
    let old = entries.updateValue(Entry(descriptor: descriptor, perform: perform), forKey: tabID)
    let abandoned = old.map { extract($0.descriptor.registration) } ?? []
    if let old { enqueue(.retired(old.descriptor.registration)) }
    enqueue(.registered(descriptor))
    for item in abandoned { enqueue(.failure(.retired(item.registration)), completion: item.completion) }
    scheduleDelivery()
    return token
  }

  public func retire(_ registration: PageRegistration) {
    guard descriptor(registration) != nil else { return }
    entries.removeValue(forKey: registration.tabID)
    let abandoned = extract(registration)
    enqueue(.retired(registration))
    for item in abandoned { enqueue(.failure(.retired(registration)), completion: item.completion) }
    scheduleDelivery()
  }

  @discardableResult
  public func call(tabID: String, registrationGeneration: PageRegistrationGeneration? = nil, method: String, args: [PageValue], completion: @escaping Completion) -> UUID {
    do {
      let command = try PageCommand.decode(method: method, args: args)
      return call(tabID: tabID, registrationGeneration: registrationGeneration, command: command, completion: completion)
    } catch let error as PageRegistryError {
      return complete(.failure(error), completion: completion)
    } catch {
      return complete(.failure(.invalidValue), completion: completion)
    }
  }

  @discardableResult
  public func call(tabID: String, registrationGeneration: PageRegistrationGeneration? = nil, command: PageCommand, completion: @escaping Completion) -> UUID {
    if let registrationGeneration {
      return call(PageRegistration(tabID: tabID, registrationGeneration: registrationGeneration), command: command, completion: completion)
    }
    guard let entry = entries[tabID] else {
      return complete(.failure(.noPage(tabID)), completion: completion)
    }
    return call(entry.descriptor.registration, command: command, completion: completion)
  }

  @discardableResult
  public func call(_ registration: PageRegistration, command: PageCommand, completion: @escaping Completion) -> UUID {
    guard let entry = entries[registration.tabID], entry.descriptor.registration == registration else {
      return complete(.failure(.retired(registration)), completion: completion)
    }
    guard command.supports(engine: entry.descriptor.engine) else {
      return complete(.failure(.unsupported(entry.descriptor.engine, command.method)), completion: completion)
    }
    if command == .nativeTag {
      return complete(.success(entry.descriptor.nativeTag.map { .number(Double($0)) } ?? .null), completion: completion)
    }
    if entry.descriptor.engine == .webKit, case .takeControlPress = command {
      return complete(.success(.bool(true)), completion: completion)
    }
    let id = UUID()
    pending[id] = Pending(registration: registration, resultKind: command.resultKind, completion: completion)
    pendingOrder.append(id)
    let cancelDeadline = scheduleTimeout(timeout) { [weak self] in
      self?.finish(id, result: .failure(.timedOut(registration)))
    }
    guard pending[id] != nil else {
      cancelDeadline()
      return id
    }
    pending[id]?.cancelDeadline = cancelDeadline
    entry.perform(command) { [weak self] result in self?.finish(id, result: result) }
    return id
  }

  public func call<Output>(_ registration: PageRegistration, request: PageRequest<Output>) async throws -> Output {
    let awaiting = AwaitingCall()
    let value: PageValue = try await withTaskCancellationHandler {
      if Task.isCancelled { throw PageRegistryError.cancelled(registration) }
      return try await withCheckedThrowingContinuation { continuation in
        awaiting.id = call(registration, command: request.command) { continuation.resume(with: $0) }
      }
    } onCancel: {
      Task { @MainActor [weak self] in
        if let id = awaiting.id { self?.cancel(id) }
      }
    }
    return try request.decode(value)
  }

  public func cancel(_ id: UUID) {
    guard let item = pending[id] else { return }
    finish(id, result: .failure(.cancelled(item.registration)))
  }

  private func extract(_ registration: PageRegistration) -> [Pending] {
    let ids = pendingOrder.filter { pending[$0]?.registration == registration }
    let abandoned = ids.compactMap { id in
      let item = pending.removeValue(forKey: id)
      item?.cancelDeadline?()
      return item
    }
    pendingOrder.removeAll { pending[$0] == nil }
    return abandoned
  }

  private func finish(_ id: UUID, result: Result<PageValue, PageRegistryError>) {
    guard let item = pending.removeValue(forKey: id) else { return }
    pendingOrder.removeAll { $0 == id }
    item.cancelDeadline?()
    let output: Result<PageValue, PageRegistryError>
    if descriptor(item.registration) == nil {
      output = .failure(.retired(item.registration))
    } else if case .success(let value) = result, !item.resultKind.accepts(value) {
      output = .failure(.invalidValue)
    } else {
      output = result
    }
    enqueue(output, completion: item.completion)
    scheduleDelivery()
  }

  private func complete(_ result: Result<PageValue, PageRegistryError>, completion: @escaping Completion) -> UUID {
    let id = UUID()
    enqueue(result, completion: completion)
    scheduleDelivery()
    return id
  }

  private func enqueue(_ result: Result<PageValue, PageRegistryError>, completion: @escaping Completion) {
    deliveries.append { completion(result) }
  }

  private func enqueue(_ event: PageRegistryEvent) {
    let receivers = observers.map(\.receive)
    deliveries.append { for receive in receivers { receive(event) } }
  }

  private func scheduleDelivery() {
    guard !schedulingDelivery else { return }
    schedulingDelivery = true
    defer { schedulingDelivery = false }
    while !deliveryPending, !deliveries.isEmpty {
      let id = UUID()
      deliveryID = id
      deliveryPending = true
      deliver { [weak self] in
        guard let self, self.deliveryID == id else { return }
        self.deliveryID = nil
        let action = self.deliveries.removeFirst()
        action()
        self.deliveryPending = false
        self.scheduleDelivery()
      }
    }
  }
}
