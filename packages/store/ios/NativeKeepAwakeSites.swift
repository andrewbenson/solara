import Foundation
import SolaraCore
internal import SolaraModel
internal import SolaraStore

@MainActor
final class NativeKeepAwakeSites {
  private let store: Store
  private var observer: Int?
  private var applied: (sites: [String], adopted: [String])?
  private var stopped = false
  private let writtenFile: URL
  private var written: [String: [String]]

  init(store: Store, folder: URL) {
    self.store = store
    writtenFile = folder.appending(path: "keep-awake-written.json")
    written = (try? JSONDecoder().decode([String: [String]].self, from: Data(contentsOf: writtenFile))) ?? [:]
    SolaraCoreServices.setKeepAwakeRecord({ [weak self] profile, patterns in
      if Thread.isMainThread { MainActor.assumeIsolated { self?.record(profile, patterns) } }
      else { DispatchQueue.main.async { MainActor.assumeIsolated { self?.record(profile, patterns) } } }
    }, written: written, normalize: { KeepAwakeSites.normalized($0) })
    SolaraCoreServices.setKeepAwakeAdoption { [weak self] profile, existing in
      DispatchQueue.main.async {
        MainActor.assumeIsolated { self?.adopt(profile, existing) }
      }
    }
    apply(store.state.settings)
    observer = store.subscribe { [weak self] commit in
      let settings = commit.state.settings
      DispatchQueue.main.async {
        MainActor.assumeIsolated { self?.apply(settings) }
      }
    }
  }

  private func apply(_ settings: Settings) {
    let sites = KeepAwakeSites.sites(settings[KeepAwakeSites.settingKey])
    let adopted = KeepAwakeSites.sites(settings[KeepAwakeSites.adoptedKey])
    guard !stopped, applied?.sites != sites || applied?.adopted != adopted else { return }
    applied = (sites, adopted)
    SolaraCoreServices.setKeepAwakeSites(sites, adopted: adopted)
  }

  private func record(_ profile: String, _ patterns: [String]) {
    guard written[profile] != patterns else { return }
    written[profile] = patterns
    do {
      try JSONEncoder().encode(written).write(to: writtenFile, options: .atomic)
    } catch {
      FileHandle.standardError.write(Data("NativeKeepAwakeSites: recording \(profile)'s sleep exceptions failed: \(error)\n".utf8))
    }
  }

  private func adopt(_ profile: String, _ existing: [String]) {
    guard !stopped else { return }
    let settings = store.state.settings
    let adopted = KeepAwakeSites.sites(settings[KeepAwakeSites.adoptedKey])
    let current = KeepAwakeSites.sites(settings[KeepAwakeSites.settingKey])
    let sites = KeepAwakeSites.adopting(existing, into: current)
    let newlyAdopted = !adopted.contains(profile)
    guard newlyAdopted || sites != current else { return }
    var patch: JSONObject = [KeepAwakeSites.settingKey: JSONValue(sites)]
    if newlyAdopted { patch[KeepAwakeSites.adoptedKey] = JSONValue(adopted + [profile]) }
    do {
      _ = try store.dispatch(Command("updateSettings", [.object(patch), ["fromSync": false]]), origin: .native)
    } catch {
      FileHandle.standardError.write(Data("NativeKeepAwakeSites: adopting \(profile)'s sleep exceptions failed: \(error)\n".utf8))
    }
  }

  nonisolated func stop() {
    if Thread.isMainThread { MainActor.assumeIsolated { stopOnMain() } }
    else { DispatchQueue.main.sync { MainActor.assumeIsolated { stopOnMain() } } }
  }

  private func stopOnMain() {
    if !stopped {
      for (profile, added) in SolaraCoreServices.keepAwakeAdditions() { adopt(profile, added) }
    }
    stopped = true
    SolaraCoreServices.setKeepAwakeAdoption { _, _ in }
    SolaraCoreServices.setKeepAwakeRecord({ _, _ in }, written: [:], normalize: { _ in nil })
    if let observer { store.unsubscribe(observer) }
    observer = nil
  }
}
