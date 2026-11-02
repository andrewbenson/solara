import AppKit
import Foundation
import SolaraShell
import SolaraLive
import SolaraUI

@MainActor
final class LiveAdapter: LiveFoldersServices, CalendarServices {
  private let engine = NativeLiveEngine.shared.engine
  private var mocked: Bool { !(engine.effects.environment.mockBase ?? "").isEmpty }

  func liveFoldersState() async -> LiveFoldersState {
    LiveSettingsMapping.folders(await engine.snapshot.live, mocked: mocked)
  }

  func liveFoldersChanges() -> AsyncStream<LiveFoldersState> {
    let (stream, continuation) = AsyncStream<LiveFoldersState>.makeStream(bufferingPolicy: .bufferingNewest(1))
    let task = Task {
      var previous: LiveFoldersState?
      for await snapshot in await engine.changes() {
        let mapped = LiveSettingsMapping.folders(snapshot.live, mocked: mocked)
        if mapped != previous {
          continuation.yield(mapped)
          previous = mapped
        }
      }
      continuation.finish()
    }
    continuation.onTermination = { _ in task.cancel() }
    return stream
  }

  func refreshFolder(_ id: String) async {
    await perform(.manualRefresh(.object(["folderId": .string(id)])))
  }

  func deleteFolder(_ id: String) { SettingsJS.shared.fire("liveFolders.deleteFolder", id) }

  func updateFolder(_ id: String, groupStacks: Bool?, showCompleted: Bool?) {
    var patch: [String: LiveAnyJSON] = [:]
    if let groupStacks { patch["groupStacks"] = .bool(groupStacks) }
    if let showCompleted { patch["showCompleted"] = .bool(showCompleted) }
    guard !patch.isEmpty else { return }
    fire(.updateFolder(.object(["folderId": .string(id), "patch": .object(patch)])))
  }

  func disconnect(_ source: LiveSourceId) async {
    await perform(.disconnect(.object(["source": .string(source.rawValue)])))
  }

  func connectGithub(token: String) async throws {
    _ = try await connect(.connectGithub(.object(["token": .string(token)])))
  }

  func setGithubClientId(_ clientId: String) {
    let trimmed = clientId.trimmingCharacters(in: .whitespacesAndNewlines)
    fire(.updateConfig(.object(["patch": .object(["githubClientId": .string(trimmed)])])))
  }

  func startGithubDeviceFlow(clientId: String) async throws -> LiveDeviceFlow {
    let trimmed = clientId.trimmingCharacters(in: .whitespacesAndNewlines)
    let result = try await connect(.startGithubDeviceFlow(.object(["clientId": .string(trimmed)])))
    guard let flow = result.deviceFlow else { throw LiveConnectError("GitHub didn't start the sign-in") }
    return LiveDeviceFlow(id: flow.id, userCode: flow.userCode, verificationUri: flow.verificationUri)
  }

  func finishGithubDeviceFlow(_ flow: LiveDeviceFlow) async throws {
    _ = try await connect(.finishGithubDeviceFlow(.object(["id": .string(flow.id)])))
  }

  func cancelGithubDeviceFlow(_ flow: LiveDeviceFlow) {
    fire(.cancelGithubDeviceFlow(.object(["id": .string(flow.id)])))
  }

  func connectNotion(token: String) async throws {
    _ = try await connect(.connectNotion(.object(["token": .string(token)])))
  }

  func connectGoogleDrive(clientId: String, clientSecret: String) async throws {
    do {
      _ = try await SettingsJS.shared.invoke("liveFolders.connectGoogleDrive", [clientId, clientSecret])
    } catch let error as SettingsJSError {
      throw LiveConnectError(error.description)
    }
  }

  func copyText(_ text: String) { SettingsAdapters.copyText(text) }

  func openInBrowser(_ url: String) { SettingsJS.shared.fire("liveFolders.openInBrowser", url) }

  func calendarState() async -> CalendarPaneState {
    let snapshot = await engine.snapshot
    return LiveSettingsMapping.calendar(snapshot.live, data: snapshot.calendar)
  }

  func calendarChanges() -> AsyncStream<CalendarPaneState> {
    let (stream, continuation) = AsyncStream<CalendarPaneState>.makeStream(bufferingPolicy: .bufferingNewest(1))
    let task = Task {
      var previous: CalendarPaneState?
      for await snapshot in await engine.changes() {
        let mapped = LiveSettingsMapping.calendar(snapshot.live, data: snapshot.calendar)
        if mapped != previous {
          continuation.yield(mapped)
          previous = mapped
        }
      }
      continuation.finish()
    }
    continuation.onTermination = { _ in task.cancel() }
    return stream
  }

  func refreshCalendar() async { await perform(.refreshCalendar(.object([:]))) }

  func connectCalendar() async { await perform(.connectCalendar(.object([:]))) }

  func requestCalendarAlertPermission() async -> Bool {
    await ShellLiveNotifications.requestCalendarAlertPermission()
  }

  func updateCalendarOptions(_ change: LiveCalendarOptionChange) {
    let patch: [String: LiveAnyJSON]
    switch change {
    case .alertLead(let value): patch = ["alertLead": .string(value)]
    case .alertCondition(let value):
      guard AlertCondition(rawValue: value) != nil else { return }
      patch = ["alertCondition": .string(value)]
    case .showPreview(let value): patch = ["showPreview": .bool(value)]
    case .showTimeToNext(let value): patch = ["showTimeToNext": .bool(value)]
    }
    fire(.updateCalendarSettings(.object(["patch": .object(patch)])))
  }

  func setCalendarHidden(_ id: String, hidden: Bool) {
    fire(.setCalendarHidden(.object(["id": .string(id), "hidden": .bool(hidden)])))
  }

  func openCalendarPrivacySettings() {
    guard let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Calendars") else { return }
    if ProcessInfo.processInfo.environment["SOLARA_BACKGROUND"] == "1" { return NSLog("[settings] background instance, not opening %@", url.absoluteString) }
    NSWorkspace.shared.open(url)
  }

  private func connect(_ command: LiveCommand) async throws -> LiveCommandResult {
    do {
      return try await engine.perform(command)
    } catch let error as LiveError {
      throw LiveConnectError(error.message)
    } catch {
      throw LiveConnectError(String(describing: error))
    }
  }

  private func perform(_ command: LiveCommand) async {
    do {
      _ = try await engine.perform(command)
    } catch {
      NSLog("[settings] Live command failed: %@", String(describing: error))
    }
  }

  private func fire(_ command: LiveCommand) {
    Task { await perform(command) }
  }
}
