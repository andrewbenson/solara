import AppKit
import SolaraShaders
import SolaraShell
import Foundation
import SolaraModel
import SolaraStore
import SolaraUI
import SwiftUI

@MainActor
enum NativeOnboarding {
  static let kind = "onboarding"

  nonisolated static var enabled: Bool {
    NativeSettingsWindow.enabled
  }

  private static var sessions: [OnboardingSession] = []
  static func register() {
    guard enabled else { return }
    OnboardingProbe.enabled = ProcessInfo.processInfo.environment["SOLARA_BACKGROUND"] == "1"
    HostedViews.register(kind) { windowId, requestId in
      guard let settings = NativeSettingsHandle.model else {
        NativeAppStartup.shared.cancelOnboardingReplay(requestId)
        return nil
      }
      let session = OnboardingSession(windowId: windowId, settings: settings, replayRequestId: requestId)
      sessions.append(session)
      return HostedContent(view: session.view, onUnmount: {
        session.end()
        sessions.removeAll { $0 === session }
      })
    }
  }

  static func resumeCommittedJoinAtLaunch() {
    guard let settings = NativeSettingsHandle.model else { return }
    let adapter = OnboardingAdapter(windowId: "", settings: settings)
    let model = OnboardingModel(services: adapter, store: StoreSettingsSource(model: settings), appName: Bundle.main.productName)
    _ = model.resumeCommittedJoin()
    adapter.dispose()
  }

  static func drive(_ action: String, _ argument: String?) -> String {
    guard enabled else { return #"{"error":"native onboarding is off"}"# }
    guard let model = sessions.last?.model else { return #"{"active":false}"# }
    switch action {
    case "go":
      let parts = (argument ?? "").split(separator: ":").map(String.init)
      guard let step = parts.first.flatMap(OnboardingStep.init(rawValue:)) else { return #"{"error":"unknown step"}"# }
      model.go(step, sub: parts.count > 1 ? Int(parts[1]) ?? 0 : 0)
    case "next": model.next()
    case "back": model.back()
    case "skip": model.skip()
    case "finish": model.finish()
    case "state": break
    case "find":
      guard let view = sessions.last?.view, let window = view.window, let content = window.contentView else { return #"{"error":"no window"}"# }
      guard let row = OnboardingProbe.rows[argument ?? ""] else { return #"{"found":false}"# }
      let local = view.isFlipped ? row.frame : NSRect(x: row.frame.minX, y: view.bounds.height - row.frame.maxY, width: row.frame.width, height: row.frame.height)
      let inContent = content.convert(view.convert(local, to: nil), from: nil)
      let top = content.isFlipped ? inContent.minY : content.bounds.height - inContent.maxY
      return json(["found": true, "value": row.on ? "1" : "0", "enabled": !row.disabled, "frame": [inContent.minX, top, inContent.width, inContent.height]])
    default: return #"{"error":"unknown action"}"#
    }
    return json(["active": model.isActive, "step": model.step.rawValue, "sub": model.sub, "windowId": sessions.last?.windowId ?? ""])
  }

  private static func json(_ object: [String: Any]) -> String {
    guard let data = try? JSONSerialization.data(withJSONObject: object), let text = String(data: data, encoding: .utf8) else { return "{}" }
    return text
  }

}

@MainActor
final class OnboardingSession {
  let windowId: String
  let adapter: OnboardingAdapter
  let model: OnboardingModel
  private(set) var view: NSView = NSView()
  private var ended = false
  private let replayRequestId: String?

  init(windowId: String, settings: SettingsModel, replayRequestId: String? = nil) {
    self.windowId = windowId
    self.replayRequestId = replayRequestId
    adapter = OnboardingAdapter(windowId: windowId, settings: settings)
    model = OnboardingModel(
      services: adapter, store: StoreSettingsSource(model: settings),
      appName: Bundle.main.productName, appIcon: NSApp.applicationIconImage)
    model.powerUpView = { spec in AnyView(OnboardingPowerUp(spec: spec)) }
    adapter.onWindowChange = { [weak model] in model?.refreshSettings() }
    let hosting = NSHostingView(rootView: OnboardingHostedRoot(model: model, windowId: windowId) { [weak self] in self?.dismissed() })
    hosting.safeAreaRegions = []
    view = hosting
    adapter.onboardingWindow = { [weak self] in self?.view.window }
    begin(replayRequested: NativeAppStartup.shared.takeOnboardingReplay(replayRequestId))
  }

  private func begin(replayRequested: Bool) {
    adapter.onboardingSession = { [weak model] in model?.session }
    adapter.onRecoveryPhraseConnected = { [weak model] session in
      guard let model, model.isActive, model.session == session else { return }
      model.finish()
    }
    let saved = adapter.savedDocument
    let token = saved?.string("joinedCompletionToken")
    let committed = adapter.committedOnboardingJoinToken
    let entered = saved?["joinedEnteredBrowser"] as? Bool == true
    let step = saved?.string("step").flatMap(OnboardingStep.init(rawValue:))
    let finishedJoin = token != nil && entered && committed == token
    if replayRequested, saved?["completedAt"] is NSNumber, finishedJoin {
      model.start(windowId: windowId, step: .intro)
    } else if model.startCommittedJoin(windowId: windowId) {
      return
    } else if saved?["completedAt"] is NSNumber, committed == nil {
      model.start(windowId: windowId, step: step ?? .intro)
    } else if committed != nil {
      model.maybeStart(windowId: windowId)
    } else if step == nil || step == .intro {
      let firstRun = saved?["startedAt"] is NSNumber || !adapter.hasSessionDocument()
      model.start(windowId: windowId, step: .intro, isFirstRunOnboarding: firstRun)
      model.discoverSync()
    } else {
      model.maybeStart(windowId: windowId)
    }
  }

  private func dismissed() {
    guard !ended else { return }
    OnboardingAdapter.fire("onboarding.dismissed", windowId, replayRequestId ?? "")
  }

  func end() {
    guard !ended else { return }
    ended = true
    model.leaveSetup()
    adapter.stopIntroMusic(fade: 0.2)
    adapter.dispose()
  }
}

struct OnboardingHostedRoot: View {
  let model: OnboardingModel
  let windowId: String
  let onDismiss: () -> Void

  var body: some View {
    OnboardingOverlayView(model: model, windowId: windowId)
      .ignoresSafeArea()
      .onChange(of: model.isActive(in: windowId)) { was, now in
        if was && !now { onDismiss() }
      }
  }
}

struct OnboardingPowerUp: NSViewRepresentable {
  let spec: PowerUpSpec

  func makeNSView(context: Context) -> NSView {
    PowerUpViews.make(palette: spec.palette, speed: spec.speed, origin: spec.origin, cornerRadius: spec.cornerRadius, halo: spec.halo)
  }

  func updateNSView(_ view: NSView, context: Context) {}
}

#if SOLARA_PROBES
@MainActor
public enum OnboardingRead {
  public static func snapshot() -> [String: Any] {
    func object(_ raw: String) -> [String: Any] {
      guard let data = raw.data(using: .utf8) else { return [:] }
      return (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] ?? [:]
    }
    let label = "Set \(Bundle.main.productName) as default browser"
    return ["state": object(NativeOnboarding.drive("state", nil)),
      "defaultBrowserRow": object(NativeOnboarding.drive("find", label))]
  }
}
#endif
