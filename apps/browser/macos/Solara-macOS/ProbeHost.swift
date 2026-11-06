#if SOLARA_PROBES
import AppKit
import CoreFoundation
import SolaraCore
import Foundation
import SolaraProbes
import SolaraStore
import SolaraShell
import SolaraSettingsAdapter

@_cdecl("SolaraProbeHostMarker")
public func SolaraProbeHostMarker() -> Int32 { 1 }

@MainActor
final class ProbeHost {
  private static var active: ProbeHost?
  private let files: ProbeFiles
  private var seen = ProbeSeenIds()
  private var timer: Timer?
  private let snapshotRequests = ProbeAsyncRequest()
  private var pending: [String: Timer] = [:]
  private var snapshotTasks: [String: Task<Void, Never>] = [:]
  private var cancellations: [String: () -> Void] = [:]
  private var swipeInFlight = false
  private var polling = false

  static func start() {
    guard SolaraProbeHostMarker() == 1 else { return }
    let environment = ProcessInfo.processInfo.environment
    guard Bundle.main.bundleIdentifier?.hasSuffix(".dev") == true,
      environment["SOLARA_BACKGROUND"] == "1",
      SolaraCoreTestHooksAllowed(),
      let path = environment["SOLARA_DATA_DIR"], !path.isEmpty else {
      NSLog("[solara-probe] gate: identity, background, or hooks denied")
      return
    }
    do {
      let files = try ProbeFiles.open(dataPath: path, defaultPath: SolaraCoreHost.installedDataDirectory, homePath: NSHomeDirectory())
      files.clearStale()
      let host = ProbeHost(files: files)
      active = host
      host.timer = Timer(timeInterval: 0.05, repeats: true) { [weak host] _ in
        MainActor.assumeIsolated { host?.poll() }
      }
      if let timer = host.timer { RunLoop.main.add(timer, forMode: .common) }
    } catch {
      NSLog("[solara-probe] gate: %@", String(describing: error))
    }
  }

  private init(files: ProbeFiles) { self.files = files }

  private func poll() {
    guard !polling else { return }
    polling = true
    defer { polling = false }
    var budget = ProbePollBudget()
    guard Bundle.main.bundleIdentifier?.hasSuffix(".dev") == true,
      ProcessInfo.processInfo.environment["SOLARA_BACKGROUND"] == "1",
      SolaraCoreTestHooksAllowed(), (try? files.recheck()) != nil else { return }
    for (id, data, readError) in files.claim() {
      var response: [String: Any]
      var expiresAtMs: Int64?
      do {
        guard Bundle.main.bundleIdentifier?.hasSuffix(".dev") == true,
          ProcessInfo.processInfo.environment["SOLARA_BACKGROUND"] == "1",
          SolaraCoreTestHooksAllowed() else { throw ProbeFailure.testHooksDenied }
        try files.recheck()
        if let readError { throw readError }
        guard let data else { throw ProbeFailure.invalidEnvelope }
        let request = try ProbeRequest.decode(data, nowMs: Int64(Date().timeIntervalSince1970 * 1000))
        expiresAtMs = request.expiresAtMs
        guard request.id.caseInsensitiveCompare(id) == .orderedSame else { throw ProbeFailure.invalidEnvelope }
        guard seen.insert(id.lowercased()) else { throw ProbeFailure.duplicate }
        switch request.command {
        case "probe.hello":
          guard request.args.isEmpty else { throw ProbeFailure.invalidArgument }
          response = ["id": id, "protocol": 1, "result": ["protocol": 1, "capabilities": ["probe.hello", "state.snapshot", "input.swipe", "input.hover", "view.capture", "onboarding.sync", "sync.enable", "pairing.trusted.arm", "pairing.trusted.select", "pairing.trusted.state", "pairing.trusted.decide"], "pid": getpid()]]
        case "input.swipe":
          try swipe(request)
          continue
        case "state.snapshot":
          if budget.takeSynchronousSnapshot(hasSavedLogin: request.args["savedLogin"] != nil) {
            _ = try validateSnapshot(request)
            let snapshot = try snapshot(request, savedLogin: nil)
            try checkGate(request)
            response = snapshot
            break
          }
          try snapshotRequests.start(id: request.id, expiresAtMs: request.expiresAtMs, checkGate: {
            try self.checkGate()
          }, lookup: {
            try await self.lookupSavedLogin(request)
          }, after: { savedLogin in
            try self.snapshot(request, savedLogin: savedLogin)
          }, reply: { result in
            switch result {
            case .success(let response):
              self.reply(response, id: id, expiresAtMs: request.expiresAtMs)
            case .failure(let error):
              self.reply(["id": id, "protocol": 1, "error": ["code": (error as? ProbeFailure)?.code ?? ProbeFailure.invalidEnvelope.code]], id: id, expiresAtMs: request.expiresAtMs)
            }
          })
          continue
        case "view.capture":
          guard Set(request.args.keys) == ["windowId"],
            let windowId = request.args["windowId"] as? String, !windowId.isEmpty, windowId.utf8.count <= 128 else { throw ProbeFailure.invalidArgument }
          guard NativeStoreHandle.store?.state.windows[windowId] != nil,
            let window = WindowHost.window(id: windowId), let content = window.contentView else { throw ProbeFailure.windowGone }
          let artifact = ".solara-probe-window-\(UUID().uuidString.lowercased()).png"
          try files.checkArtifactBudget()
          try checkAction(request, window: window)
          let dragBefore = Self.tabDrag(TabDragRead.snapshot)
          let sequenceBefore = DragPreviewRead.snapshot["sequence"] as? Int
          guard let png = try ProbeCapture.shared.withPreparedWindow(window, render: { WindowCaptureRead.png(windowId: windowId) })
          else { throw ProbeFailure.notReady }
          let dragAfter = Self.tabDrag(TabDragRead.snapshot)
          let consistent = NSDictionary(dictionary: dragBefore).isEqual(to: dragAfter)
            && sequenceBefore == DragPreviewRead.snapshot["sequence"] as? Int
          try files.writeArtifact(name: artifact, data: png, beforePublication: {
            try self.checkAction(request, window: window)
          })
          let scale = window.backingScaleFactor
          response = ["id": id, "protocol": 1, "result": ["artifact": artifact,
            "width": Int(content.bounds.width * scale), "height": Int(content.bounds.height * scale), "scale": scale,
            "tabDrag": dragBefore, "consistent": consistent]]
        case "onboarding.sync":
          let keys = Set(request.args.keys)
          guard keys == ["action"] || keys == ["action", "cid"],
            let action = request.args["action"] as? String, !action.isEmpty, action.utf8.count <= 32 else { throw ProbeFailure.invalidArgument }
          let cid = request.args["cid"] as? String
          if keys.contains("cid") { guard let cid, cid.utf8.count == 26 else { throw ProbeFailure.invalidArgument } }
          guard let route = OnboardingRead.sync(action: action, cid: cid) else { throw ProbeFailure.notReady }
          response = ["id": id, "protocol": 1, "result": ["ok": true, "syncRoute": route]]
        case "sync.enable":
          guard request.args.isEmpty, let folder = ProcessInfo.processInfo.environment["SOLARA_SYNC_DEFAULT_FOLDER"], !folder.isEmpty else { throw ProbeFailure.invalidArgument }
          let probeId = id
          let expires = request.expiresAtMs
          Task { @MainActor in
            let result = await PairingProbe.enableSync(folder: folder)
            self.reply(["id": probeId, "protocol": 1, "result": result], id: probeId, expiresAtMs: expires)
          }
          continue
        case "pairing.trusted.arm", "pairing.trusted.select", "pairing.trusted.state", "pairing.trusted.decide":
          let result: [String: Any]
          do {
            switch request.command {
            case "pairing.trusted.arm":
              guard request.args.isEmpty else { throw ProbeFailure.invalidArgument }
              result = try PairingProbe.armTrusted()
            case "pairing.trusted.select":
              guard request.args.isEmpty else { throw ProbeFailure.invalidArgument }
              result = try PairingProbe.selectTrusted()
            case "pairing.trusted.state":
              guard request.args.isEmpty else { throw ProbeFailure.invalidArgument }
              result = PairingProbe.trustedState()
            default:
              guard Set(request.args.keys) == ["decision"], let decision = request.args["decision"] as? String else { throw ProbeFailure.invalidArgument }
              result = try PairingProbe.decideTrusted(decision)
            }
          } catch PairingProbe.Refusal.invalid {
            throw ProbeFailure.invalidArgument
          } catch PairingProbe.Refusal.unsupported {
            throw ProbeFailure.unsupported
          } catch let failure as ProbeFailure {
            throw failure
          } catch {
            throw ProbeFailure.notReady
          }
          response = ["id": id, "protocol": 1, "result": result]
        case "input.hover":
          guard Set(request.args.keys) == ["windowId", "area", "target", "on"],
            let windowId = request.args["windowId"] as? String, !windowId.isEmpty, windowId.utf8.count <= 128,
            let area = request.args["area"] as? String, ["sidebar", "topStrip", "downloads"].contains(area),
            let target = request.args["target"] as? String, !target.isEmpty, target.utf8.count <= 512,
            let on = request.args["on"] as? NSNumber, CFGetTypeID(on) == CFBooleanGetTypeID() else { throw ProbeFailure.invalidArgument }
          guard NativeStoreHandle.store?.state.windows[windowId] != nil,
            let window = WindowHost.window(id: windowId) else { throw ProbeFailure.windowGone }
          try checkAction(request, window: window)
          guard let sample = HoverLayoutRead.snapshot(windowId: windowId, area: area),
            let targets = sample["targets"] as? [String], targets.count <= 128, targets.contains(target) else { throw ProbeFailure.invalidArgument }
          try checkAction(request, window: window)
          response = ["id": id, "protocol": 1, "result": ["delivered": HoverLayoutInput.perform(windowId: windowId, area: area, target: target, on: on.boolValue)]]
        default:
          throw ProbeFailure.unsupported
        }
      } catch {
        let code = (error as? ProbeFailure)?.code ?? ProbeFailure.invalidEnvelope.code
        response = ["id": id, "protocol": 1, "error": ["code": code]]
      }
      reply(response, id: id, expiresAtMs: expiresAtMs)
    }
  }

  private func reply(_ response: [String: Any], id: String, expiresAtMs: Int64?) {
    do {
      try ProbeReply.publish(response, id: id, expiresAtMs: expiresAtMs, checkGate: { try self.checkGate() }, write: { data, beforePublication in
        try self.files.reply(id: id, data: data, beforePublication: beforePublication)
      })
    } catch {
      NSLog("[solara-probe] reply: %@", String(describing: error))
    }
  }

  private func checkAction(_ request: ProbeRequest, window: NSWindow) throws {
    try checkGate(request)
    let windows = NSApp.windows
    try ProbeActionAdmission.check(mode: RunLoop.current.currentMode,
      hasModalWindow: NSApp.modalWindow != nil,
      hasAttachedSheet: window.attachedSheet != nil || windows.contains { $0.attachedSheet != nil },
      hasSheetParent: window.sheetParent != nil || windows.contains { $0.sheetParent != nil })
    try checkGate(request)
  }

  private func checkGate(_ request: ProbeRequest? = nil) throws {
    guard Bundle.main.bundleIdentifier?.hasSuffix(".dev") == true,
      ProcessInfo.processInfo.environment["SOLARA_BACKGROUND"] == "1",
      SolaraCoreTestHooksAllowed() else { throw ProbeFailure.testHooksDenied }
    try files.recheck()
    if let request, Int64(Date().timeIntervalSince1970 * 1000) >= request.expiresAtMs { throw ProbeFailure.timeout }
  }

  private func checkSnapshot(_ request: ProbeRequest) throws {
    if request.args["savedLogin"] == nil {
      try checkGate(request)
    } else {
      try snapshotRequests.check(id: request.id, expiresAtMs: request.expiresAtMs) { try self.checkGate() }
    }
  }

  private func begin(_ request: ProbeRequest) {
    let seconds = max(0, Double(request.expiresAtMs) / 1000 - Date().timeIntervalSince1970)
    pending[request.id] = Timer.scheduledTimer(withTimeInterval: seconds, repeats: false) { [weak self] _ in
      MainActor.assumeIsolated {
        guard let self else { return }
        self.snapshotTasks[request.id]?.cancel()
        self.cancellations.removeValue(forKey: request.id)?()
        self.finish(request, response: ["id": request.id, "protocol": 1, "error": ["code": ProbeFailure.timeout.code]])
      }
    }
  }

  private func finish(_ request: ProbeRequest, response: [String: Any]) {
    guard let timer = pending.removeValue(forKey: request.id) else { return }
    timer.invalidate()
    let cancel = cancellations.removeValue(forKey: request.id)
    do {
      try checkGate(request)
      reply(response, id: request.id, expiresAtMs: request.expiresAtMs)
    } catch {
      cancel?()
      reply(["id": request.id, "protocol": 1, "error": ["code": (error as? ProbeFailure)?.code ?? ProbeFailure.testHooksDenied.code]],
        id: request.id, expiresAtMs: request.expiresAtMs)
    }
  }

  private static func number(_ value: Any?) -> Double? {
    guard let number = value as? NSNumber, CFGetTypeID(number) != CFBooleanGetTypeID(), number.doubleValue.isFinite else { return nil }
    return number.doubleValue
  }

  private func swipe(_ request: ProbeRequest) throws {
    let args = request.args
    guard Set(args.keys) == Set(["windowId", "x", "y", "steps", "ignorePreference"]),
      let windowId = args["windowId"] as? String, !windowId.isEmpty, windowId.utf8.count <= 256,
      let x = Self.number(args["x"]), let y = Self.number(args["y"]),
      x >= 0, y >= 0, x <= 32768, y <= 32768,
      let ignore = args["ignorePreference"] as? NSNumber, CFGetTypeID(ignore) == CFBooleanGetTypeID(),
      let steps = args["steps"] as? [[String: Any]], steps.count <= 128 else { throw ProbeFailure.invalidArgument }
    guard NativeStoreHandle.store?.state.windows[windowId] != nil,
      let window = WindowHost.window(id: windowId) else { throw ProbeFailure.windowGone }
    guard let content = window.contentView, x <= content.bounds.width, y <= content.bounds.height else { throw ProbeFailure.invalidArgument }
    var previousTime = 0.0
    for (index, step) in steps.enumerated() {
      guard Set(step.keys).isSubset(of: ["phase", "dx", "dy", "atMs", "timestampMs"]),
        let phase = step["phase"] as? String, ["began", "changed", "ended", "cancelled", "swipe"].contains(phase),
        let dx = Self.number(step["dx"]), abs(dx) <= 1000,
        let at = Self.number(step["atMs"]), at >= previousTime, at <= 5000,
        index != 0 || at == 0,
        step["dy"] == nil || Self.number(step["dy"]).map({ abs($0) <= 1000 }) == true,
        step["timestampMs"] == nil || Self.number(step["timestampMs"]) == at else { throw ProbeFailure.invalidArgument }
      previousTime = at
    }
    if let first = steps.first, let last = steps.last {
      if first["phase"] as? String == "swipe" {
        guard steps.count == 1 else { throw ProbeFailure.invalidArgument }
      } else {
        guard steps.count >= 2, first["phase"] as? String == "began",
          ["ended", "cancelled"].contains(last["phase"] as? String ?? ""),
          steps.dropFirst().dropLast().allSatisfy({ $0["phase"] as? String == "changed" }) else { throw ProbeFailure.invalidArgument }
      }
    }
    guard Int64(Date().timeIntervalSince1970 * 1000) + Int64(previousTime) + 250 < request.expiresAtMs else { throw ProbeFailure.invalidArgument }
    guard !swipeInFlight else { throw ProbeFailure.notReady }
    try checkAction(request, window: window)
    swipeInFlight = true
    begin(request)
    var failure: ProbeFailure?
    let cancel = SwipeInput.perform(windowNumber: window.windowNumber, x: x, y: y, steps: steps, ignorePreference: ignore.boolValue, shouldContinue: { [weak self] in
      guard let self else { return false }
      do {
        try checkAction(request, window: window)
        guard pending[request.id] != nil else { throw ProbeFailure.timeout }
        return true
      } catch {
        failure = (error as? ProbeFailure) ?? .testHooksDenied
        return false
      }
    }) { [weak self] result in
      guard let self else { return }
      swipeInFlight = false
      if let failure {
        finish(request, response: ["id": request.id, "protocol": 1, "error": ["code": failure.code]])
      } else {
        finish(request, response: ["id": request.id, "protocol": 1, "result": result])
      }
    }
    if pending[request.id] != nil { cancellations[request.id] = { failure = .timeout; cancel() } }
  }

  private func validateSnapshot(_ request: ProbeRequest) throws -> (origin: String, username: String)? {
    try checkSnapshot(request)
    guard Set(request.args.keys).isSubset(of: ["windowId", "dropTargets", "viewFrames", "hitPoint", "reactBlockerStep", "savedLogin", "hoverPresentation", "hoverArea", "textFields", "shortcuts", "shortcutTable", "shortcutTrace", "fields", "swipeTracePage", "swipeTraceStartNs", "swipeTraceSequence", "pages", "stripPoints", "topStrip", "stripTrace", "stripLabels", "dragPoints", "tabDrag", "fileDropAfter"]),
      request.args["windowId"] == nil || request.args["windowId"] is String else { throw ProbeFailure.invalidArgument }
    if let raw = request.args["dragPoints"] {
      guard let points = raw as? [[String: Any]], points.count <= 16,
        request.args["windowId"] is String else { throw ProbeFailure.invalidArgument }
      for point in points {
        guard Set(point.keys) == Set(["x", "y"]), let x = Self.number(point["x"]), let y = Self.number(point["y"]),
          x >= 0, y >= 0, x <= 32768, y <= 32768 else { throw ProbeFailure.invalidArgument }
      }
    }
    if let fields = request.args["fields"] {
      guard let fields = fields as? [String], fields.count <= 128,
        fields.allSatisfy({ field in
          let parts = field.split(separator: ".", omittingEmptySubsequences: false)
          return field.utf8.count <= 80 && parts.count == 2 && ["root", "windows", "tabs"].contains(String(parts[0])) &&
            !parts[1].isEmpty && parts[1].allSatisfy({ $0.isASCII && ($0.isLetter || $0.isNumber) }) &&
            !(parts[0] == "root" && ["windows", "tabs"].contains(String(parts[1])))
        }) else { throw ProbeFailure.invalidArgument }
    }
    if let titles = request.args["shortcutTable"] {
      guard let titles = titles as? [String], titles.count <= 16,
        titles.allSatisfy({ !$0.isEmpty && $0.utf8.count <= 512 }) else { throw ProbeFailure.invalidArgument }
    }
    if let trace = request.args["shortcutTrace"] {
      guard let trace = trace as? NSNumber, CFGetTypeID(trace) == CFBooleanGetTypeID() else { throw ProbeFailure.invalidArgument }
    }
    if let shortcuts = request.args["shortcuts"] {
      guard let shortcuts = shortcuts as? NSNumber, CFGetTypeID(shortcuts) == CFBooleanGetTypeID() else { throw ProbeFailure.invalidArgument }
    }
    if let value = request.args["tabDrag"] {
      guard let flag = value as? NSNumber, CFGetTypeID(flag) == CFBooleanGetTypeID() else { throw ProbeFailure.invalidArgument }
    }
    if let value = request.args["fileDropAfter"] {
      guard let after = Self.number(value), after >= 0, after <= 9007199254740991,
        after.rounded(.down) == after, request.args["tabDrag"] as? Bool == true else { throw ProbeFailure.invalidArgument }
    }
    if let value = request.args["stripLabels"] {
      guard let flag = value as? NSNumber, CFGetTypeID(flag) == CFBooleanGetTypeID() else { throw ProbeFailure.invalidArgument }
    }
    if let value = request.args["stripTrace"] {
      guard let trace = value as? String, ["group", "slot", "glow", "peek"].contains(trace),
        request.args["topStrip"] as? Bool == true, request.args["windowId"] is String else { throw ProbeFailure.invalidArgument }
    }
    if let value = request.args["topStrip"] {
      guard let flag = value as? NSNumber, CFGetTypeID(flag) == CFBooleanGetTypeID() else { throw ProbeFailure.invalidArgument }
    }
    if let value = request.args["stripPoints"] {
      guard let points = value as? [[NSNumber]], points.count <= 4, request.args["windowId"] is String,
        points.allSatisfy({ $0.count == 2 && $0.allSatisfy({ CFGetTypeID($0) != CFBooleanGetTypeID() && $0.doubleValue.isFinite && $0.doubleValue >= 0 && $0.doubleValue <= 32768 }) }) else { throw ProbeFailure.invalidArgument }
    }
    if let value = request.args["pages"] {
      guard let flag = value as? NSNumber, CFGetTypeID(flag) == CFBooleanGetTypeID() else { throw ProbeFailure.invalidArgument }
    }
    if let value = request.args["swipeTracePage"] {
      guard let page = Self.number(value), page.rounded(.down) == page, page >= 0, page < 32 else { throw ProbeFailure.invalidArgument }
    }
    if let value = request.args["swipeTraceStartNs"] {
      guard let startNs = value as? String, !startNs.isEmpty, startNs.utf8.count <= 32,
        startNs.utf8.allSatisfy({ (48...57).contains($0) }) else { throw ProbeFailure.invalidArgument }
    }
    if let value = request.args["swipeTraceSequence"] {
      guard request.args["swipeTraceStartNs"] is String, let sequence = Self.number(value),
        sequence >= 1, sequence <= 9007199254740991, sequence.rounded(.down) == sequence else { throw ProbeFailure.invalidArgument }
    }
    if let textFields = request.args["textFields"] {
      guard let textFields = textFields as? NSNumber, CFGetTypeID(textFields) == CFBooleanGetTypeID() else { throw ProbeFailure.invalidArgument }
    }
    let dropTargets = request.args["dropTargets"] as? [[String: Any]] ?? []
    let viewFrames = request.args["viewFrames"] as? [String] ?? []
    let hitPoint = request.args["hitPoint"] as? [Double]
    let blockerStep = request.args["reactBlockerStep"] as? Double
    let hoverPresentation = request.args["hoverPresentation"] as? [Double]
    let hoverArea = request.args["hoverArea"] as? String
    let dropTypes = Set(["public.file-url", "public.url", "public.utf8-plain-text"])
    guard request.args["dropTargets"] == nil || request.args["dropTargets"] is [[String: Any]],
      request.args["viewFrames"] == nil || request.args["viewFrames"] is [String],
      request.args["hitPoint"] == nil || hitPoint?.count == 2,
      request.args["reactBlockerStep"] == nil || (blockerStep != nil && blockerStep! >= 8 && blockerStep! <= 64),
      request.args["hoverPresentation"] == nil || ((request.args["hoverPresentation"] as? [NSNumber])?.allSatisfy({ CFGetTypeID($0) != CFBooleanGetTypeID() }) == true && hoverPresentation?.count == 6 && hoverPresentation!.allSatisfy({ $0.isFinite && abs($0) <= 10000 }) && hoverPresentation![2] > 0 && hoverPresentation![2] <= hoverPresentation![3] && hoverPresentation![4] > 0 && hoverPresentation![4] <= hoverPresentation![5]),
      request.args["hoverArea"] == nil || hoverArea.map({ ["sidebar", "topStrip", "downloads"].contains($0) }) == true,
      dropTargets.count <= 12, viewFrames.count <= 4,
      viewFrames.allSatisfy({ ["PopoverView", "SidebarTabCardView", "SplitChromeView", "MeetingAlertFrameView", "NativeDeviceChooserView", "NativePromptView", "NativePromptView^3", "PromptPressable#0", "PromptPressable#1", "PromptPressable#2", "PromptPressable#3", "PromptPressable#4", "PromptPressable#5"].contains($0) }),
      dropTargets.allSatisfy({ sample in
        sample.count == 3 && (sample["x"] as? Double)?.isFinite == true &&
          (sample["y"] as? Double)?.isFinite == true &&
          (sample["type"] as? String).map(dropTypes.contains) == true
      }) else { throw ProbeFailure.invalidArgument }
    if let query = request.args["savedLogin"] {
      guard let query = query as? [String: Any], Set(query.keys) == Set(["origin", "username"]),
        let origin = query["origin"] as? String, origin.utf8.count <= 2048,
        let username = query["username"] as? String, username.utf8.count <= 256,
        !username.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains),
        let components = URLComponents(string: origin), let scheme = components.scheme, ["http", "https"].contains(scheme),
        let host = components.host, !host.isEmpty, components.user == nil, components.password == nil,
        components.path.isEmpty || components.path == "/", components.query == nil, components.fragment == nil,
        let url = components.url else { throw ProbeFailure.invalidArgument }
      let canonical = url.absoluteString.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
      return (canonical, username)
    }
    return nil
  }

  private func lookupSavedLogin(_ request: ProbeRequest) async throws -> [String: Any]? {
    guard let query = try validateSnapshot(request) else { return nil }
    let exists = await SavedLoginRead.exists(origin: query.origin, username: query.username)
    return ["exists": exists]
  }

  private func snapshot(_ request: ProbeRequest, savedLogin: [String: Any]?) throws -> [String: Any] {
    let dragPoints = request.args["dragPoints"] as? [[String: Any]] ?? []
    let shortcuts = request.args["shortcuts"] as? Bool ?? false
    let shortcutTitles = request.args["shortcutTable"] as? [String]
    let shortcutTrace = request.args["shortcutTrace"] as? Bool ?? false
    let tabDrag = request.args["tabDrag"] as? Bool ?? false
    let fileDropAfter = Self.number(request.args["fileDropAfter"])
    let topStrip = request.args["topStrip"] as? Bool ?? false
    let stripTrace = request.args["stripTrace"] as? String
    let stripLabels = request.args["stripLabels"] as? Bool ?? false
    let readPages = request.args["pages"] as? Bool ?? false
    let swipeTracePage = Self.number(request.args["swipeTracePage"]).map { Int($0) }
    let swipeTraceStartNs = request.args["swipeTraceStartNs"] as? String
    let swipeTraceSequence = Self.number(request.args["swipeTraceSequence"]).map { Int($0) }
    let textFields = request.args["textFields"] as? Bool ?? false
    let dropTargets = request.args["dropTargets"] as? [[String: Any]] ?? []
    let viewFrames = request.args["viewFrames"] as? [String] ?? []
    let hitPoint = request.args["hitPoint"] as? [Double]
    let blockerStep = request.args["reactBlockerStep"] as? Double
    let hoverPresentation = request.args["hoverPresentation"] as? [Double]
    let hoverArea = request.args["hoverArea"] as? String
    guard let store = NativeStoreHandle.store else { throw ProbeFailure.notReady }
    let wanted = request.args["windowId"] as? String
    if let wanted, wanted != "settings", store.state.windows[wanted] == nil { throw ProbeFailure.windowGone }
    var initial = store.snapshot
    var final = initial
    for attempt in 0..<2 {
      let state = initial.state
      let ids = wanted == "settings" ? [] : wanted.map { [$0] } ?? state.windowOrder
      var windows: [[String: Any]] = try ids.compactMap { id in
        guard let model = state.windows[id] else { return nil }
        let window = WindowHost.window(id: id)
        let chrome = SolaraCoreHost.chromeWindows.first { entry in
          if let number = entry["window"] as? Int, number == window?.windowNumber { return true }
          guard entry["hasRoot"] as? Bool == true, let text = entry["frame"] as? String else { return false }
          let frame = NSRectFromString(text)
          if let window { return abs(frame.minX - window.frame.minX) < 2 && abs(frame.width - window.frame.width) < 2 }
          guard let saved = model.frame, saved.count == 4 else { return false }
          return abs(frame.minX - CGFloat(saved[0])) < 2 && abs(frame.width - CGFloat(saved[2])) < 2
        }
        let chromeNumber = chrome?["window"] as? Int
        let chromeWindow = chromeNumber.flatMap { NSApp.window(withWindowNumber: $0) }
        let frame = (chromeWindow ?? window).map { NSRect(origin: .zero, size: $0.frame.size) }
        let selections: [[String: Any]] = model.tabIds.compactMap { tabId in
          guard let selection = PaneOverlayRead.selection(windowId: id, tabId: tabId) else { return nil }
          return ["id": "selection.\(tabId)", "kind": "selection", "tabId": tabId,
            "visible": !(selection["hidden"] as? Bool ?? true),
            "opacity": selection["opacity"] ?? NSNull(),
            "frame": Self.rect(selection["bar"]),
            "controls": [["id": "search", "frame": Self.rect(selection["button"])]],
            "area": Self.rect(selection["area"]), "above": selection["above"] ?? NSNull()]
        }
        var overlays = selections
        for tabId in model.tabIds {
          if let zoom = PaneOverlayRead.zoom(windowId: id, tabId: tabId) { overlays.append(Self.popover(zoom, kind: "zoom", tabId: tabId)) }
          if let history = PaneOverlayRead.history(windowId: id, tabId: tabId) { overlays.append(Self.popover(history, kind: "history", tabId: tabId)) }
          if let sadTab = PaneOverlayRead.sadTab(windowId: id, tabId: tabId) { overlays.append(Self.sadTabOverlay(sadTab, tabId: tabId)) }
        }
        if let downloads = DownloadsPanelRead.panel(windowId: id) { overlays.append(Self.downloadsOverlay(downloads)) }
        let focusedURL = OmniboxRead.focusedURL(windowId: id).map { source -> [String: Any] in
          ["field": source["field"] ?? NSNull(), "value": safeURL(source["value"] as? String ?? ""),
            "selection": source["selection"] ?? NSNull()]
        }
        let omnibox = OmniboxRead.bar(windowId: id).map { source -> [String: Any] in
          let items = source["items"] as? [[String: Any]] ?? []
          var rows: [[String: Any]] = []
          for item in items.prefix(shortcuts ? 0 : 64) {
            let title = (item["title"] as? String).map { String($0.prefix(512)) }
            rows.append(["kind": Self.value(item["kind"] as? String),
              "url": safeURL(item["url"] as? String ?? ""), "title": Self.value(title),
              "tabId": Self.value(item["tabId"] as? String)])
          }
          return ["variant": Self.value(source["variant"] as? String), "source": Self.value(source["source"] as? String),
            "open": Self.value(source["mounted"] as? Bool), "focused": Self.value(source["focused"] as? Bool),
            "typed": omniboxText(source["typed"] as? String), "value": omniboxText(source["value"] as? String),
            "completion": omniboxText(source["completion"] as? String),
            "selectedIndex": Self.value(source["selected"] as? Int), "rows": rows]
        }
        var dropSamples: [[String: Any]] = []
        var frames: [String: Any] = [:]
        if let chromeNumber {
          for sample in dropTargets {
            let x = sample["x"] as! Double
            let y = sample["y"] as! Double
            let type = sample["type"] as! String
            let target = PagesRead.dropTarget(windowNumber: chromeNumber, x: x, y: y, type: type)
            dropSamples.append(["x": x, "y": y, "type": type, "view": target["view"] ?? NSNull(), "chain": target["chain"] ?? []])
          }
          for needle in viewFrames { frames[needle] = PagesRead.viewFrame(windowNumber: chromeNumber, needle: needle) }
        }
        var toolbarStates: [String: Any] = [:]
        for tabId in model.tabIds {
          if let toolbar = ToolbarStateRead.snapshot(windowId: id, tabId: tabId) { toolbarStates[tabId] = toolbar }
        }
        var media: [String: Any] = [:]
        for kind in ["media.sidebarPlayer", "media.hoverPlayer", "media.cliPill", "media.castPicker", "media.sharePicker", "media.shareBar", "littleSolara.bar"] {
          media[kind] = MediaRead.rows(kind: kind, windowId: id)
        }
        let hitSlot = hitPoint.flatMap { WindowShellRead.hitSlot(windowId: id, x: $0[0], y: $0[1]) }
        let hitView = hitPoint.flatMap { WindowShellRead.hitView(windowId: id, x: $0[0], y: $0[1]) }
        var dragPointSamples: [[String: Any]] = []
        if let chromeNumber {
          for point in dragPoints {
            let x = point["x"] as! Double, y = point["y"] as! Double
            dragPointSamples.append(["x": x, "y": y, "hit": Self.dragString(DragPointRead.hit(windowNumber: chromeNumber, x: x, y: y), limit: 4096)])
          }
        }
        var shortcutFields: [[String: Any]] = []
        if shortcuts, let chromeNumber {
          for field in WindowAccessibilityRead.shortcutFields(windowNumber: chromeNumber) {
            shortcutFields.append(["role": field["role"] ?? NSNull(), "label": field["label"] ?? NSNull(),
              "value": omniboxText(field["value"] as? String)])
          }
        }
        var stripPoints: [[String: Any]] = []
        if let points = request.args["stripPoints"] as? [[Double]], let chromeNumber,
          let frameView = (chromeWindow ?? window)?.contentView?.superview {
          guard points.allSatisfy({ $0[0] <= frameView.bounds.width && $0[1] <= frameView.bounds.height }) else { throw ProbeFailure.invalidArgument }
          for source in WindowPointRead.samples(windowNumber: chromeNumber, points: points, labels: stripLabels) {
            var row = source
            for key in ["tip", "ax"] {
              if let text = source[key] as? String { row[key] = labelText(text) }
            }
            stripPoints.append(row)
          }
        }
        let responder = (chromeWindow ?? window)?.firstResponder.map { NSStringFromClass(type(of: $0)) }
        let textFieldCount = textFields ? chromeNumber.flatMap { WindowAccessibilityRead.textFieldCount(windowNumber: $0) } : nil
        return ["id": id, "kind": model.fields.kind ?? "browser", "profileId": model.profileId,
          "incognito": model.incognito, "order": state.windowOrder.firstIndex(of: id) ?? 0,
          "key": window?.isKeyWindow ?? false, "visible": window?.isVisible ?? false,
          "occluded": NSNull(), "frame": Self.value(frame.map(Self.rectFromWindow)),
          "accessibilityLayers": Self.value(WindowShellRead.accessibilityReach(windowId: id)),
          "split": Self.value(SplitChromeRead.snapshot(windowId: id)),
          "tour": Self.value(ToolTourRead.snapshot(windowId: id)),
          "folderPanel": Self.value(FolderPanelRead.snapshot(windowId: id)),
          "iconPicker": Self.value(SidebarIconPickerRead.snapshot(windowId: id)),
          "shell": Self.value(WindowShellRead.snapshot(windowId: id)),
          "shellHover": Self.value(WindowShellRead.hoverMeasurements(windowId: id)),
          "sidebarShell": Self.value(SidebarShellRead.snapshot(windowId: id)),
          "sidebarChromeMetrics": Self.value(SidebarChromeRead.snapshot(windowId: id)),
          "sidebarAddressBar": Self.value(SidebarAddressBarRead.snapshot(windowId: id)),
          "toolbarHosts": ToolbarRead.snapshot(windowId: id),
          "topStrip": topStrip ? Self.value(TopStripRead.snapshot(windowId: id, trace: stripTrace)) : NSNull(), "stripPoints": stripPoints,
          "sidePanel": Self.value(SidePanelRead.snapshot(windowId: id)),
          "sheet": Self.value(SheetRead.snapshot(windowId: id)),
          "hoverCard": Self.value(SidebarHoverCardRead.snapshot(windowId: id)),
          "hoverPresentation": Self.value(hoverPresentation.flatMap { SidebarHoverCardRead.presentation(windowId: id, sample: $0) }),
          "hoverPresentationTrace": SidebarHoverCardRead.trace(windowId: id),
          "hoverLayout": Self.value(hoverArea.flatMap { HoverLayoutRead.snapshot(windowId: id, area: $0) }),
          "reactBlockers": Self.value(blockerStep.flatMap { WindowShellRead.reactBlockers(windowId: id, step: $0) }),
          "dropTargets": dropSamples, "viewFrames": frames, "hitSlot": Self.value(hitSlot), "hitView": Self.value(hitView),
          "firstResponder": Self.value(responder),
          "shortcuts": shortcuts || shortcutTrace ? ShortcutRead.snapshot(windowId: id, focusTrace: shortcutTrace) as Any : NSNull(),
          "shortcutTable": shortcutTitles.map { ShortcutRead.table(titles: $0) } ?? [], "shortcutFields": shortcutFields,
          "sidebarDrag": tabDrag ? Self.value(SidebarDragRead.snapshot(windowId: id).map(Self.sidebarDrag)) : NSNull(), "dragPoints": dragPointSamples,
          "savedFrame": Self.dragNumbers(model.frame, count: 4),
          "screenFrame": Self.dragNumbers((chromeWindow ?? window).map { [$0.frame.minX, $0.frame.minY, $0.frame.width, $0.frame.height] }, count: 4),
          "panelOpen": state.windowUi[id]?.panelOpen ?? false, "sidebarOpen": model.sidebarOpen,
          "activeTabIds": Dictionary(uniqueKeysWithValues: model.activeTabIds.map { ($0.key, $0.value) }),
          "textFieldCount": Self.value(textFieldCount),
          "media": media, "mediaKinds": MediaRead.kinds,
          "paneOverlays": Self.value(PaneOverlayRead.snapshot(windowId: id)),
          "toolbarStates": toolbarStates, "bookmarks": readPages ? pageBookmarks(windowId: id) as Any : NSNull(),
          "pager": Self.value(SwipeRead.pager(windowId: id)), "profilePager": Self.value(ProfilePagerRead.snapshot(windowId: id)),
          "contentFrame": Self.value(window?.contentView.map { Self.rectFromWindow($0.bounds) }),
          "chromeWindowNumber": Self.value(chromeNumber),
          "selectedTabId": Self.value(model.activeTabIds[model.profileId]),
          "selectedTabIds": NSNull(), "tabIds": model.tabIds,
          "spaces": NSNull(), "panes": NSNull(), "focus": NSNull(), "focusedURL": Self.value(focusedURL),
          "omnibox": Self.value(omnibox), "overlays": overlays,
          "views": NSNull()]
      }
      if wanted == nil || wanted == "settings", let settingsWindow = WindowHost.window(id: "settings"),
        let settings = SettingsRead.snapshot() {
        windows.append(["id": "settings", "kind": "settings", "visible": settingsWindow.isVisible,
          "frame": Self.rectFromWindow(NSRect(origin: .zero, size: settingsWindow.frame.size)),
          "omnibox": Self.value(nil), "overlays": [], "settings": settings])
      }
      let allowedIds = Set(ids)
      let tabs: [[String: Any]] = state.tabs.keys.sorted().compactMap { id in
        guard let tab = state.tabs[id], allowedIds.contains(tab.windowId) else { return nil }
        return ["id": id, "windowId": tab.windowId, "profileId": tab.profileId,
          "url": safeURL(tab.url), "title": String(tab.title.prefix(512)),
          "customTitle": Self.value(tab.customTitle.map { String($0.prefix(512)) }),
          "customIcon": Self.value(tab.customIcon),
          "pinned": tab.pinned, "tileFolderId": Self.dragString(tab.tileFolder?.id), "pinnedAsRow": tab.pinnedAsRow ?? false, "loading": NSNull(), "live": Self.value(TabPoolRead.live(id)),
          "visible": NSNull(), "zoom": tab.zoom,
          "find": ["open": state.find[id]?.json["open"]?.truthy ?? false,
            "query": String((state.find[id]?.json["query"]?.string ?? "").prefix(512))]]
      }
      var groups: [[String: Any]] = []
      for id in tabDrag ? state.groups.keys.sorted() : [] {
        guard let group = state.groups[id], allowedIds.contains(group.windowId) else { continue }
        groups.append(["id": Self.dragString(id), "windowId": Self.dragString(group.windowId),
          "tabIds": Self.dragStrings(group.tabIds), "pinned": group.pinned])
        if groups.count == 60 { break }
      }
      var splits: [[String: Any]] = []
      for id in tabDrag ? state.splits.keys.sorted() : [] {
        guard let split = state.splits[id], allowedIds.contains(split.windowId) else { continue }
        splits.append(["id": Self.dragString(id), "windowId": Self.dragString(split.windowId),
          "tabIds": Self.dragStrings(split.tabIds)])
        if splits.count == 60 { break }
      }
      var fileDragURLs: [Any] = []
      for url in tabDrag ? Array(FileDragRead.urls.prefix(16)) : [] { fileDragURLs.append(safeURL(url)) }
      for url in tabDrag ? Array(DownloadDragRead.urls.prefix(16)) : [] { fileDragURLs.append(safeURL(url)) }
      var fileDropResults: [[String: Any]] = []
      if tabDrag, let fileDropAfter {
        for row in FileDragRead.results.suffix(32) {
          guard let sequence = Self.dragSequence(row["sequence"]), sequence > fileDropAfter,
            let windowId = row["windowId"] as? String, allowedIds.contains(windowId) else { continue }
          fileDropResults.append(["sequence": sequence, "windowId": String(windowId.prefix(128)),
            "phase": Self.dragString(row["phase"], limit: 32), "result": Self.dragString(row["result"], limit: 512)])
        }
      }
      var profiles: [[String: Any]] = []
      for id in state.profileOrder {
        guard let profile = state.profiles[id] else { continue }
        profiles.append(["id": id, "name": String(profile.name.prefix(512)), "dataId": profile.dataId ?? id])
      }
      let pages = readPages ? pageSnapshots() : [:]
      var chromeWindows: [[String: Any]] = []
      for source in SolaraCoreHost.chromeWindows {
        var row: [String: Any] = [:]
        for key in ["window", "hasRoot", "profile", "group", "visible"] {
          if let value = source[key] { row[key] = value }
        }
        chromeWindows.append(row)
      }
      let upscaling = VideoUpscalingRead.snapshot()
      let upscalingTabs: [[String: Any]] = (upscaling["tabs"] as? [[String: Any]] ?? []).map { entry in
        ["tabId": entry["tabId"] ?? NSNull(), "url": safeURL(entry["url"] as? String ?? ""),
          "allowed": entry["allowed"] ?? NSNull()]
      }
      let upscalingWindows: [[String: Any]] = (upscaling["windows"] as? [[String: Any]] ?? []).map { entry in
        ["key": entry["key"] ?? NSNull(), "visible": entry["visible"] ?? NSNull(),
          "miniaturized": entry["miniaturized"] ?? NSNull(), "occlusionVisible": entry["occlusionVisible"] ?? NSNull(),
          "littleSolara": entry["littleSolara"] ?? NSNull(), "internal": entry["internal"] ?? NSNull(),
          "focusedTab": safeURL(entry["focusedTab"] as? String ?? "")]
      }
      let videoUpscaling: [String: Any] = ["tabs": upscalingTabs, "windows": upscalingWindows,
        "enabled": upscaling["enabled"] ?? NSNull(), "lowPower": upscaling["lowPower"] ?? NSNull(),
        "thermalPressure": upscaling["thermalPressure"] ?? NSNull(), "appActive": upscaling["appActive"] ?? NSNull()]
      final = store.snapshot
      if final.rev == initial.rev || attempt == 1 {
        try checkSnapshot(request)
        let windowDragCount = WindowDragRead.count
        let swipeHaptics = SwipeRead.haptics
        let shellHaptics = ShellHapticRead.snapshot
        let swipePerformed = swipeHaptics["performed"] as? Int ?? 0
        let swipeSuppressed = swipeHaptics["suppressed"] as? Int ?? 0
        let shellPerformed = shellHaptics["performed"] as? Int ?? 0
        let shellSuppressed = shellHaptics["suppressed"] as? Int ?? 0
        let haptics: [String: Any] = ["performed": swipePerformed + shellPerformed, "suppressed": swipeSuppressed + shellSuppressed,
          "swipe": swipeHaptics, "shell": shellHaptics]
        try checkSnapshot(request)
        let result: [String: Any] = ["schema": 1,
          "storeRevision": initial.rev, "endRevision": final.rev, "capturedAtNs": DispatchTime.now().uptimeNanoseconds,
          "consistent": final.rev == initial.rev,
          "coordinateSpace": ["origin": "windowContentTopLeft", "unit": "point", "displayScale": windowScale(ids)],
          "focusedWindowId": Self.value(state.ui.focusedWindowId), "poolAvailable": TabPoolRead.available,
          "hostedKinds": HostedRead.kinds, "sidePanelLiveViews": SidePanelRead.liveViews,
          "settings": ["extensionSidePanelWidth": state.settings["extensionSidePanelWidth"]?.number ?? 360],
          "windowDragCount": windowDragCount, "onboarding": OnboardingRead.snapshot(), "newTabAvailable": NewTabRead.available, "swipeSimulation": SwipeRead.snapshot(tracePage: swipeTracePage, traceStartNs: swipeTraceStartNs, traceSequence: swipeTraceSequence), "haptics": haptics,
          "videoUpscaling": videoUpscaling, "savedLogin": Self.value(savedLogin),
          "groups": groups, "splits": splits, "dragPreview": tabDrag ? Self.dragPreview(DragPreviewRead.snapshot) : [:], "tabDrag": tabDrag ? Self.tabDrag(TabDragRead.snapshot) : [:],
          "fileDragURLs": fileDragURLs, "fileDropResults": fileDropResults,
          "fileDropSequence": Self.dragSequence(FileDragRead.results.last?["sequence"]) ?? 0,
          "calendar": readPages ? PageCalendarRead.snapshot() as Any : NSNull(), "hoverStats": HoverStatsRead.snapshot(), "hoverStatsLive": HoverStatsRead.current(),
          "windows": windows, "tabs": tabs, "downloads": ["count": state.downloads.count, "finished": state.downloads.filter { $0.state == "finished" }.count, "ids": state.downloads.map(\.id)], "profiles": profiles, "profileOrder": state.profileOrder, "pages": pages["pages"] ?? NSNull(), "pageFrames": pages["frames"] ?? NSNull(), "chromeWindows": chromeWindows,
          "capabilities": ["available": ["windows.frame", "windows.chromeWindowNumber", "windows.accessibilityLayers", "windows.focusedURL", "windows.omnibox", "windows.split", "windows.tour", "windows.folderPanel", "windows.iconPicker", "windows.shell", "windows.sidebarShell", "windows.sidebarChromeMetrics", "windows.sidebarAddressBar", "windows.hoverCard", "windows.reactBlockers", "windows.dropTargets", "windows.viewFrames", "windows.hitSlot", "windows.hitView", "windows.firstResponder", "windows.textFieldCount", "windows.media", "windows.media.labels", "windows.mediaKinds", "windows.paneOverlays", "poolAvailable", "onboarding", "newTabAvailable", "windowDragCount", "swipeSimulation", "haptics", "videoUpscaling", "savedLogin", "tabs.url", "tabs.title", "tabs.customTitle", "tabs.customIcon", "tabs.zoom", "windows.overlays.selection", "windows.overlays.zoom", "windows.overlays.history", "windows.overlays.downloads", "windows.overlays.sadTab", "downloads.count", "downloads.finished", "windows.settings.layout", "windows.settings.search", "windows.toolbarStates", "hostedKinds", "windows.hoverPresentation", "windows.hoverPresentationTrace", "windows.hoverLayout", "tabs.pinned", "tabs.pinnedAsRow", "windows.shellHover", "hoverStats", "hoverStatsLive", "windows.toolbarHosts", "windows.shortcuts", "windows.shortcutTable", "windows.shortcuts.focusTrace", "snapshot.fields", "windows.shortcutFields", "windows.omnibox.value", "windows.panelOpen", "windows.sidebarOpen", "windows.activeTabIds", "tabs.find", "windows.sidePanel", "windows.sheet", "sidePanelLiveViews", "settings.extensionSidePanelWidth", "profileOrder", "chromeWindows", "windows.pager", "windows.profilePager", "swipeSimulation.trace", "swipeSimulation.completedTraces", "pages", "calendar", "windows.bookmarks", "downloads.ids", "profiles", "pageFrames", "windows.topStrip", "windows.stripPoints", "windows.sidebarDrag", "windows.savedFrame", "windows.screenFrame", "tabs.tileFolderId", "groups", "splits", "dragPreview", "tabDrag", "fileDragURLs", "fileDropResults", "windows.dragPoints", "fileDropSequence"],
            "partial": ["tabs.live"], "unavailable": ["windows.occluded", "windows.selectedTabIds", "windows.spaces", "windows.panes", "windows.focus", "windows.views", "tabs.loading", "tabs.visible"]]]
        return ["id": request.id, "protocol": 1, "result": Self.project(result, fields: request.args["fields"] as? [String])]
      }
      initial = final
    }
    throw ProbeFailure.timeout
  }

  private static func dragString(_ source: Any?, limit: Int = 128) -> Any {
    guard let source = source as? String else { return NSNull() }
    return String(source.prefix(limit))
  }

  private static func dragStrings(_ source: Any?, limit: Int = 60) -> [String] {
    Array((source as? [String] ?? []).prefix(limit)).map { String($0.prefix(128)) }
  }

  private static func dragNumber(_ source: Any?) -> Double? {
    guard let value = number(source), abs(value) <= 9_007_199_254_740_991 else { return nil }
    return value
  }

  private static func dragInteger(_ source: Any?) -> Double? {
    guard let value = dragNumber(source), value.rounded(.towardZero) == value else { return nil }
    return value
  }

  private static func dragSequence(_ source: Any?) -> Double? {
    guard let value = dragInteger(source), value >= 0 else { return nil }
    return value
  }

  private static func dragNumbers(_ source: Any?, count: Int) -> Any {
    guard let source = source as? [Any], source.count == count else { return NSNull() }
    let values = source.compactMap(dragNumber)
    return values.count == count ? values : NSNull()
  }

  private static func dragFields(_ source: [String: Any], strings: [String] = [], numbers: [String] = [], integers: [String] = [], counts: [String] = [], flags: [String] = []) -> [String: Any] {
    var result: [String: Any] = [:]
    for key in strings { result[key] = dragString(source[key]) }
    for key in numbers { result[key] = value(dragNumber(source[key])) }
    for key in integers { result[key] = value(dragInteger(source[key])) }
    for key in counts { result[key] = value(dragSequence(source[key])) }
    for key in flags { result[key] = value(source[key] as? Bool) }
    return result
  }

  private static func dragDrop(_ source: Any?) -> [String: Any] {
    guard let source = source as? [String: Any], !source.isEmpty else { return [:] }
    var result = dragFields(source, strings: ["over"], flags: ["outside", "zonePage", "jsOnPage", "timedOut", "owned"])
    result["screen"] = dragNumbers(source["screen"], count: 2)
    result["source"] = dragNumbers(source["source"], count: 4)
    result["jsPointer"] = dragNumbers(source["jsPointer"], count: 2)
    return result
  }

  private static func tabDrag(_ source: [String: Any]) -> [String: Any] {
    var result = dragFields(source, strings: ["sourceWindow", "overWindow"], numbers: ["x", "y"], flags: ["outside", "onPage", "insert", "lifted"])
    result["tabIds"] = dragStrings(source["tabIds"])
    if let target = source["target"] as? [String: Any] {
      var clean: [String: Any] = [:]
      for key in ["tabId", "side", "beforeId", "kind"] where target[key] != nil { clean[key] = dragString(target[key]) }
      result["target"] = clean
    } else { result["target"] = NSNull() }
    result["lastDrop"] = dragDrop(source["lastDrop"])
    return result
  }

  private static func dragPreview(_ source: [String: Any]) -> [String: Any] {
    var result = dragFields(source, strings: ["shape"], numbers: ["alpha"], integers: ["level"], flags: ["visible", "page", "placeholder", "key", "ignoresMouse", "activeApp"])
    result["frame"] = dragNumbers(source["frame"], count: 4)
    result["shapes"] = dragStrings(source["shapes"], limit: 128)
    result["sequence"] = value(dragSequence(source["sequence"]))
    if let growth = source["growth"] as? [String: Any] {
      result["growth"] = dragFields(growth, numbers: ["width", "height", "targetWidth", "targetHeight"], counts: ["sequence"], flags: ["visible"])
    } else { result["growth"] = NSNull() }
    return result
  }

  private static func sidebarDrag(_ source: [String: Any]) -> [String: Any] {
    var result = dragFields(source, strings: ["gapKey"], numbers: ["scrollY", "pitch"], counts: ["external"], flags: ["active", "escaping"])
    for key in ["viewport", "folderPanel"] {
      if let frame = source[key] as? [String: Any] { result[key] = dragFields(frame, numbers: ["x", "y", "w", "h"]) }
      else { result[key] = NSNull() }
    }
    if let landed = source["landed"] as? [String: Any] { result["landed"] = dragFields(landed, strings: ["key"], numbers: ["x", "y"]) }
    else { result["landed"] = NSNull() }
    let marks = source["marks"] as? [String: Any] ?? [:]
    var cleanMarks = dragFields(marks, strings: ["dropInto", "onto", "landing", "pinBefore", "folded", "folderTarget"], counts: ["pinCount"], flags: ["pins", "folderAway"])
    cleanMarks["sources"] = dragStrings(marks["sources"])
    result["marks"] = cleanMarks
    var items: [[String: Any]] = []
    for item in (source["items"] as? [[String: Any]] ?? []).prefix(60) {
      var clean = dragFields(item, strings: ["key", "kind", "section", "parentGroup", "groupId", "folderId"], numbers: ["x", "y", "w", "h"])
      clean["tabIds"] = dragStrings(item["tabIds"])
      items.append(clean)
    }
    result["items"] = items
    let regions = source["regions"] as? [String: Any] ?? [:]
    var cleanRegions: [String: Any] = [:]
    for key in regions.keys.sorted().prefix(16) {
      if let frame = regions[key] as? [String: Any] { cleanRegions[String(key.prefix(128))] = dragFields(frame, numbers: ["x", "y", "w", "h"]) }
    }
    result["regions"] = cleanRegions
    result["lastDrop"] = dragDrop(source["lastDrop"])
    return result
  }

  private static func project(_ source: [String: Any], fields: [String]?) -> [String: Any] {
    guard let fields else { return source }
    let wanted = Set(fields)
    let metadata: Set<String> = ["schema", "storeRevision", "endRevision", "capturedAtNs", "consistent", "coordinateSpace", "capabilities"]
    var result: [String: Any] = [:]
    for (key, value) in source where metadata.contains(key) || wanted.contains("root." + key) {
      result[key] = value
    }
    for area in ["windows", "tabs"] {
      guard fields.contains(where: { $0.hasPrefix(area + ".") }) else { continue }
      var rows: [[String: Any]] = []
      for sourceRow in source[area] as? [[String: Any]] ?? [] {
        var row: [String: Any] = [:]
        for (key, value) in sourceRow where key == "id" || wanted.contains(area + "." + key) {
          row[key] = value
        }
        rows.append(row)
      }
      result[area] = rows
    }
    return result
  }

  private static func popover(_ source: [String: Any], kind: String, tabId: String) -> [String: Any] {
    let controls = source["controls"] as? [String: [Double]] ?? [:]
    let labels = kind == "zoom" ? ["Zoom In (⌘+)"] : controls.keys.filter { $0 != "Show Full History" }.sorted()
    return ["id": "\(kind).\(tabId)", "kind": kind, "tabId": tabId,
      "visible": !(source["hidden"] as? Bool ?? true), "opacity": source["opacity"] ?? NSNull(),
      "frame": rect(source["card"]), "area": rect(source["frame"]),
      "controls": labels.compactMap { label in controls[label].map { ["id": label, "frame": rect($0)] } }]
  }

  private static func sadTabOverlay(_ source: [String: Any], tabId: String) -> [String: Any] {
    let controls = source["controls"] as? [String: [Double]] ?? [:]
    return ["id": "sadTab.\(tabId)", "kind": "sadTab", "tabId": tabId,
      "visible": !(source["hidden"] as? Bool ?? true), "mode": source["mode"] ?? NSNull(),
      "frame": rect(source["frame"]),
      "controls": controls.keys.sorted().map { ["id": $0, "frame": rect(controls[$0])] }]
  }

  private static func downloadsOverlay(_ source: [String: Any]) -> [String: Any] {
    let controls = source["controls"] as? [String: [Double]] ?? [:]
    return ["id": "downloads", "kind": "downloads", "visible": true,
      "opacity": source["opacity"] ?? NSNull(), "frame": rect(source["card"]),
      "list": rect(source["list"]),
      "controls": controls.keys.sorted().map { ["id": $0, "frame": rect(controls[$0])] }]
  }

  private func labelText(_ raw: String) -> String {
    let ancestors = raw.components(separatedBy: " < ").map { ancestor in
      ancestor.components(separatedBy: "\n").map { line in
        line.components(separatedBy: "|").map { part in
          if part.range(of: "^[A-Za-z][A-Za-z0-9+.-]*:", options: .regularExpression) != nil {
            return safeURL(part) as? String ?? ""
          }
          return part
        }.joined(separator: "|")
      }.joined(separator: "\n")
    }
    return String(ancestors.joined(separator: " < ").prefix(512))
  }

  private func pageBookmarks(windowId: String) -> [[String: Any]] {
    var result: [[String: Any]] = []
    for var node in PageLibraryRead.bookmarks(windowId: windowId) {
      node["url"] = safeURL(node["url"] as? String ?? "")
      result.append(node)
    }
    return result
  }

  private func pageSnapshots() -> [String: Any] {
    var result: [[String: Any]] = []
    var sharedFrames: [[String: Any]] = []
    for var page in PagesRead.snapshot() {
      if page["url"] != nil { page["url"] = safeURL(page["url"] as? String ?? "") }
      if page["kind"] as? String == "history" {
        for key in ["shown", "selected"] {
          if let urls = page[key] as? [String] { page[key] = urls.map { safeURL($0) } }
        }
      }
      if sharedFrames.isEmpty, let frames = page["frames"] as? [[String: Any]] {
        var rows: [[String: Any]] = []
        for var frame in frames.prefix(256) {
          if let label = frame["label"] as? String {
            if label.hasPrefix("row:") {
              frame["label"] = "row:" + (safeURL(String(label.dropFirst(4))) as? String ?? "")
            } else {
              frame["label"] = String(label.prefix(512))
            }
          }
          rows.append(frame)
        }
        sharedFrames = rows
      }
      page.removeValue(forKey: "frames")
      result.append(page)
    }
    return ["pages": result, "frames": sharedFrames]
  }

  private func omniboxText(_ raw: String?) -> Any {
    guard let raw else { return Self.value(nil) }
    if raw.range(of: "^[A-Za-z][A-Za-z0-9+.-]*:", options: .regularExpression) != nil {
      let sanitized = safeURL(raw) as? String
      return Self.value(sanitized.map { String($0.prefix(512)) })
    }
    return String(raw.prefix(512))
  }

  private func safeURL(_ raw: String) -> Any {
    guard var components = URLComponents(string: raw), let scheme = components.scheme?.lowercased() else { return NSNull() }
    guard ["http", "https", "about", "chrome", "file", "solara", "solara"].contains(scheme) else { return "\(scheme):" }
    if scheme == "file" {
      let path = components.url.flatMap { ProbeFiles.realPath($0.path) } ?? ""
      guard path == files.dataPath || path.hasPrefix(files.dataPath + "/") else { return NSNull() }
    }
    components.user = nil
    components.password = nil
    return String((components.string ?? raw).prefix(2048))
  }

  private static func value(_ optional: Any?) -> Any { optional ?? NSNull() }

  private static func rect(_ value: Any?) -> Any {
    guard let list = value as? [Double], list.count == 4 else { return NSNull() }
    return ["x": list[0], "y": list[1], "width": list[2], "height": list[3]]
  }

  private static func rectFromWindow(_ value: NSRect) -> [String: Double] {
    ["x": value.minX, "y": value.minY, "width": value.width, "height": value.height]
  }

  private func windowScale(_ ids: [String]) -> Double {
    Double(ids.compactMap { WindowHost.window(id: $0)?.backingScaleFactor }.first ?? 1)
  }
}
#endif
