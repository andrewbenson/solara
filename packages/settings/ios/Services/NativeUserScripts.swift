import SolaraCore
import SolaraShell
import Foundation
import SolaraModel
import SolaraStore
import SolaraUI

@MainActor
final class NativeUserScripts: UserScriptsHost {
  static let shared = NativeUserScripts()

  private var requested = false
  private var started = false
  private var lifecycle: Int?
  private var subscription: Int?
  private var profileObserver: NSObjectProtocol?
  private lazy var sync = UserScriptsSync(host: self, product: Bundle.main.productName)

  private init() {}

  func startWhenReady() {
    guard !SolaraCoreHost.safeMode, !requested else { return }
    requested = true
    lifecycle = NativeStoreHandle.subscribeLifecycle { NativeUserScripts.shared.prepare() }
  }

  private func prepare() {
    guard !SolaraCoreHost.safeMode, !started, NativeSettingsHandle.model != nil, let store = NativeStoreHandle.store else { return }
    started = true
    UserScripts.shared.emit = {
      DispatchQueue.main.async { MainActor.assumeIsolated { NativeUserScripts.shared.sync.schedule() } }
    }
    subscription = store.subscribe { commit in
      DispatchQueue.main.async { MainActor.assumeIsolated { NativeUserScripts.shared.stateChanged(commit.state) } }
    }
    profileObserver = NotificationCenter.default.addObserver(forName: SolaraCoreHost.profileDidLoad, object: nil, queue: .main) { _ in
      MainActor.assumeIsolated {
        if let state = NativeStoreHandle.store?.state { NativeUserScripts.shared.stateChanged(state) }
      }
    }
    stateChanged(store.state)
  }

  private func stateChanged(_ state: BrowserState) {
    guard !SolaraCoreHost.safeMode else { return }
    sync.sync(enabled: state.settings["cliControl"]?.bool ?? false, targets: UserScriptsSync.targets(state).filter { NativeProfileLoading.isLoaded($0.engine) })
  }

  func watch(_ on: Bool) {
    if on { UserScripts.shared.start() } else { UserScripts.shared.stop() }
  }

  func read() async throws -> UserScriptsFolder {
    await withCheckedContinuation { continuation in
      UserScripts.work.async { continuation.resume(returning: UserScriptsFolder(UserScripts.shared.read())) }
    }
  }

  func readStatus() async throws -> String? {
    await withCheckedContinuation { continuation in
      UserScripts.work.async { continuation.resume(returning: UserScripts.shared.readStatus()) }
    }
  }

  func writeStatus(_ json: String) async throws {
    try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, any Error>) in
      UserScripts.work.async {
        do {
          try UserScripts.shared.writeStatus(json)
          continuation.resume()
        } catch { continuation.resume(throwing: error) }
      }
    }
  }

  func list(_ profile: String) async throws -> [UserScriptsExtension] {
    try await withCheckedThrowingContinuation { continuation in
      SolaraCoreServices.listExtensions(profile: profile) { result in
        if let error = result["error"] as? String { return continuation.resume(throwing: ScriptsEngineFailure(error)) }
        let extensions = (result["extensions"] as? [[String: Any]] ?? []).map(UserScriptsExtension.init)
        continuation.resume(returning: extensions)
      }
    }
  }

  func install(_ path: String, profile: String) async throws -> String {
    try await withCheckedThrowingContinuation { continuation in
      SolaraCoreServices.installExtension(path: path, profile: profile) { result in
        if let error = result["error"] as? String { return continuation.resume(throwing: ScriptsEngineFailure(error)) }
        continuation.resume(returning: result["id"] as? String ?? "")
      }
    }
  }

  func reload(_ id: String, profile: String) async throws {
    try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, any Error>) in
      SolaraCoreServices.reloadExtension(id, profile: profile) { result in
        if let error = result["error"] as? String { continuation.resume(throwing: ScriptsEngineFailure(error)) }
        else { continuation.resume() }
      }
    }
  }

  func uninstall(_ id: String, profile: String) async throws {
    try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, any Error>) in
      SolaraCoreServices.uninstallExtension(id, profile: profile) { result in
        if let error = result["error"] as? String { continuation.resume(throwing: ScriptsEngineFailure(error)) }
        else { continuation.resume() }
      }
    }
  }

  func warn(_ message: String, error: any Error) {
    NSLog("%@ %@", message, error.localizedDescription)
  }
}

private struct ScriptsEngineFailure: LocalizedError {
  let errorDescription: String?

  init(_ message: String) { errorDescription = message }
}
