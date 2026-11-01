import AppKit
import ApplicationServices
import Foundation

func fail(_ message: String) -> Never {
  FileHandle.standardError.write(("FAIL  " + message + "\n").data(using: .utf8)!)
  exit(1)
}
func log(_ message: String) {
  print(message)
  fflush(stdout)
}
let args = CommandLine.arguments
let mode = args.count > 1 ? args[1] : ""
func applications(_ path: String) -> [NSRunningApplication] {
  NSWorkspace.shared.runningApplications.filter { $0.bundleURL?.resolvingSymlinksInPath().path == path && !$0.isTerminated }
}
func attribute(_ element: AXUIElement, _ name: CFString) -> CFTypeRef? {
  var result: CFTypeRef?
  return AXUIElementCopyAttributeValue(element, name, &result) == .success ? result : nil
}
func installButton(_ root: AXUIElement) -> AXUIElement? {
  var pending = [(root, 0)], seen = 0
  let titles: Set<String> = ["Install Update", "Install and Relaunch", "Relaunch", "Restart"]
  while let (element, depth) = pending.popLast(), seen < 4000 {
    seen += 1
    let role = attribute(element, kAXRoleAttribute as CFString) as? String
    let title = attribute(element, kAXTitleAttribute as CFString) as? String ?? ""
    if role == (kAXButtonRole as String) && titles.contains(title) { return element }
    if depth < 12, let children = attribute(element, kAXChildrenAttribute as CFString) as? [AXUIElement] {
      pending.append(contentsOf: children.map { ($0, depth + 1) })
    }
  }
  return nil
}
if mode == "preflight" {
  guard AXIsProcessTrusted() else { fail("Accessibility access is required for the terminal to press this scratch app's updater buttons without activation") }
  exit(0)
}
guard args.count >= 3 else { fail("usage: self-update-proof preflight | quit <app> | exercise <app> <old pid> <version> <build> <data>") }
let path = URL(fileURLWithPath: args[2]).resolvingSymlinksInPath().path
if mode == "quit" {
  let owned = applications(path)
  owned.forEach { _ = $0.terminate() }
  let deadline = Date().addingTimeInterval(15)
  while Date() < deadline && !applications(path).isEmpty { RunLoop.main.run(until: Date().addingTimeInterval(0.2)) }
  applications(path).forEach { _ = $0.forceTerminate() }
  exit(0)
}
guard mode == "exercise", args.count == 7, let oldPID = pid_t(args[3]), AXIsProcessTrusted() else { fail("bad exercise arguments or Accessibility access is unavailable") }
let expected = args[4], build = args[5], data = args[6]
guard applications(path).contains(where: { $0.processIdentifier == oldPID }) else { fail("the original scratch process is not running at the expected path") }
let deadline = Date().addingTimeInterval(300)
var lastPress = Date.distantPast
var pressed = false
while Date() < deadline {
  let running = applications(path)
  if let relaunched = running.first(where: { $0.processIdentifier != oldPID }), !running.contains(where: { $0.processIdentifier == oldPID }) {
    let executable = relaunched.executableURL?.resolvingSymlinksInPath().path ?? ""
    guard executable.hasPrefix(path + "/Contents/MacOS/") else { fail("relaunched executable escaped the scratch app") }
    guard let info = NSDictionary(contentsOfFile: path + "/Contents/Info.plist"),
      info["CFBundleShortVersionString"] as? String == expected,
      info["CFBundleVersion"] as? String == build else { fail("relaunched bundle has the wrong version or build") }
    let process = Process(), pipe = Pipe()
    process.executableURL = URL(fileURLWithPath: "/bin/ps")
    process.arguments = ["-E", "-ww", "-p", String(relaunched.processIdentifier), "-o", "command="]
    process.standardOutput = pipe
    process.standardError = FileHandle.nullDevice
    do { try process.run() } catch { fail("could not inspect relaunched process environment") }
    let environment = String(data: pipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
    process.waitUntilExit()
    guard environment.contains("SOLARA_BACKGROUND=1"), environment.contains("SOLARA_DATA_DIR=" + data),
      environment.contains("CFFIXED_USER_HOME=" + URL(fileURLWithPath: data).deletingLastPathComponent().appendingPathComponent("home").path)
    else { _ = relaunched.terminate(); fail("Sparkle relaunch did not preserve the fixture's hidden scratch environment") }
    guard pressed else { fail("process changed before an install/relaunch choice was accepted") }
    let result: [String: Any] = ["pid": relaunched.processIdentifier, "path": path, "binary": executable, "build": build, "version": expected]
    do {
      let json = try JSONSerialization.data(withJSONObject: result, options: [.prettyPrinted, .sortedKeys])
      try json.write(to: URL(fileURLWithPath: data).appendingPathComponent("relaunched.json"))
    } catch { fail("could not save relaunch evidence") }
    log("PASS  Sparkle replaced pid \(oldPID) and relaunched pid \(relaunched.processIdentifier): \(expected) build \(build), \(path), hidden with scratch data")
    exit(0)
  }
  if running.contains(where: { $0.processIdentifier == oldPID }), Date().timeIntervalSince(lastPress) >= 2 {
    let root = AXUIElementCreateApplication(oldPID)
    if let button = installButton(root) {
      let title = attribute(button, kAXTitleAttribute as CFString) as? String ?? "install"
      if AXUIElementPerformAction(button, kAXPressAction as CFString) == .success {
        pressed = true
        lastPress = Date()
        log("Sparkle UI: accepted \(title) in scratch pid \(oldPID)")
      }
    }
  }
  RunLoop.main.run(until: Date().addingTimeInterval(0.25))
}
fail("Sparkle did not install and relaunch the expected scratch app in 300 seconds")
