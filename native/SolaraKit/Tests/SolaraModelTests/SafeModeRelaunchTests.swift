import Foundation
import Testing
@testable import SolaraModel

@Suite struct SafeModeRelaunchTests {
  static let bundle = "/tmp/build-x/Build/Products/Debug/Solara Dev.app"
  static let token = "0D7E3A51-6B2C-4F18-A9E4-5C1B7D3F2A60"
  static let tokenArguments = ["--env", "\(LaunchSwitches.safeModeRequestVariable)=\(token)"]
  static let windowsSwiftBookmarkQuitTimerSeconds = 30
  static let updaterSwiftQuitWaitLimitSeconds = 8

  static func arguments(_ environment: [String: String], development: Bool, pid: Int32 = 7) -> [String] {
    SafeModeRelaunch.arguments(
      waitingFor: pid, bundlePath: bundle, executableName: "Solara Dev", environment: environment, development: development, safeModeToken: token)
  }

  static func passed(_ arguments: [String]) -> [String] { Array(arguments.dropFirst(SafeModeRelaunch.fixedArgumentCount)) }

  @Test func everyValueIsAnArgumentAfterTheFixedScript() {
    let hostile = "/tmp/data $(touch /tmp/owned); `id`\nnext"
    let arguments = Self.arguments(["SOLARA_DATA_DIR": hostile, "SOLARA_BACKGROUND": "1"], development: false, pid: 4242)
    #expect(Array(arguments.prefix(SafeModeRelaunch.fixedArgumentCount)) == [
      "/bin/sh", "-c", SafeModeRelaunch.waitThenOpenScript, "sh", "4242", String(SafeModeRelaunch.waitSeconds * 10),
      "\(Self.bundle)/Contents/MacOS/Solara Dev",
    ])
    #expect(arguments.last == Self.bundle)
    #expect(arguments.contains("SOLARA_DATA_DIR=\(hostile)"))
    #expect(!SafeModeRelaunch.waitThenOpenScript.contains("4242"))
    #expect(!SafeModeRelaunch.waitThenOpenScript.contains(Self.bundle))
    #expect(!SafeModeRelaunch.waitThenOpenScript.contains(Self.token))
    #expect(!SafeModeRelaunch.waitThenOpenScript.contains("touch"))
    #expect(!SafeModeRelaunch.waitThenOpenScript.contains(String(SafeModeRelaunch.waitSeconds * 10)))
    #expect(SafeModeRelaunch.waitThenOpenScript.hasPrefix(#"pid=$1; limit=$2; executable=$3; shift 3;"#))
    #expect(SafeModeRelaunch.waitThenOpenScript.hasSuffix(#"exec /usr/bin/open -n "$@""#))
  }

  @Test func theHelperWaitsLongerThanTheSlowestGracefulQuit() {
    let slowestQuit = Self.windowsSwiftBookmarkQuitTimerSeconds + Self.updaterSwiftQuitWaitLimitSeconds
    #expect(SafeModeRelaunch.bookmarkQuitTimeoutSeconds == Self.windowsSwiftBookmarkQuitTimerSeconds)
    #expect(SafeModeRelaunch.updaterQuitWaitLimitSeconds == Self.updaterSwiftQuitWaitLimitSeconds)
    #expect(SafeModeRelaunch.waitSeconds >= slowestQuit + 15)
    #expect(SafeModeRelaunch.waitSeconds == 53)
    #expect(SafeModeRelaunch.pollsPerSecond == 10)
    #expect(Self.arguments([:], development: false)[5] == String(SafeModeRelaunch.waitSeconds * 10))
    #expect(Self.arguments([:], development: false)[5] == "530")
  }

  @Test func theTokenAlwaysPassesJustBeforeTheBundle() {
    for development in [false, true] {
      for environment in [[:], ["SOLARA_BACKGROUND": "1"], [LaunchSwitches.safeModeRequestVariable: "stale"]] as [[String: String]] {
        let passed = Self.passed(Self.arguments(environment, development: development))
        #expect(Array(passed.suffix(3)) == Self.tokenArguments + [Self.bundle], "\(environment) \(development)")
        #expect(passed.filter { $0.hasPrefix("\(LaunchSwitches.safeModeRequestVariable)=") }.count == 1)
      }
    }
  }

  @Test func aBackgroundInstanceRelaunchesHiddenWithItsDataFolderAndOnlyADebugBuildPassesItsPort() {
    let environment = [
      "SOLARA_BACKGROUND": "1", "SOLARA_DATA_DIR": "/tmp/ac-x/data", "SOLARA_REMOTE_DEBUGGING_PORT": "9333",
      LaunchSwitches.defaultsVariable: "suite",
    ]
    #expect(Self.passed(Self.arguments(environment, development: true)) == [
      "-g",
      "--env", "SOLARA_DATA_DIR=/tmp/ac-x/data",
      "--env", "SOLARA_BACKGROUND=1",
      "--env", "\(LaunchSwitches.defaultsVariable)=suite",
      "--env", "SOLARA_REMOTE_DEBUGGING_PORT=9333",
    ] + Self.tokenArguments + [Self.bundle])
    let release = Self.passed(Self.arguments(environment, development: false))
    #expect(release == [
      "-g",
      "--env", "SOLARA_DATA_DIR=/tmp/ac-x/data",
      "--env", "SOLARA_BACKGROUND=1",
      "--env", "\(LaunchSwitches.defaultsVariable)=suite",
    ] + Self.tokenArguments + [Self.bundle])
    #expect(!release.contains { $0.contains("SOLARA_REMOTE_DEBUGGING_PORT") })
  }

  @Test func aNormalInstanceRelaunchesInFrontWithOnlyTheToken() {
    let passed = Self.passed(Self.arguments(["HOME": "/Users/x", "PATH": "/bin"], development: true))
    #expect(passed == Self.tokenArguments + [Self.bundle])
  }

  @Test func testSeamsAndUnlistedVariablesNeverPass() {
    let environment = [
      "SOLARA_TEST_STORE_OPEN_FAIL": "openFailed", "SOLARA_TEST_EARLY_LINK_FAILS": "1", "SOLARA_TEST_EARLY_WINDOW_IGNORES_HIDDEN": "1",
      "SOLARA_LAUNCH_SWITCHES_OPTION": "1", "SOLARA_ACCEPT_EXTERNAL_URLS": "1", "DYLD_INSERT_LIBRARIES": "/tmp/x.dylib",
      "SOLARA_JS_LOCATION": "localhost:1", LaunchSwitch.nativeWindowLayout.rawValue: "1", "SOLARA_DATA_DIR": "",
    ]
    let release = Self.passed(Self.arguments(environment, development: false))
    #expect(release == Self.tokenArguments + [Self.bundle])
    let development = Self.passed(Self.arguments(environment, development: true))
    #expect(development == [
      "--env", "SOLARA_JS_LOCATION=localhost:1", "--env", "\(LaunchSwitch.nativeWindowLayout.rawValue)=1",
    ] + Self.tokenArguments + [Self.bundle])
    #expect(!development.contains { $0.contains("SOLARA_TEST_") || $0.contains("DYLD_") })
    #expect(!(SafeModeRelaunch.passedVariables + SafeModeRelaunch.developmentVariables).contains { $0.hasPrefix("SOLARA_TEST_") })
  }

  @Test func theHelperGetsOnlyAPath() {
    #expect(SafeModeRelaunch.helperEnvironment == ["PATH=/usr/bin:/bin:/usr/sbin:/sbin"])
  }

  @Test func anUntranslocatedBundleIsItsOwnOriginal() {
    let url = URL(fileURLWithPath: Self.bundle, isDirectory: true)
    #expect(SafeModeRelaunch.originalBundleURL(url) == url)
  }

  @Test func theHelperStartsWithDefaultSignalsAndAnEmptyMaskInItsOwnSession() {
    let flags = Int32(SafeModeRelaunch.spawnFlags)
    for flag in [POSIX_SPAWN_SETSID, POSIX_SPAWN_CLOEXEC_DEFAULT, POSIX_SPAWN_SETSIGDEF, POSIX_SPAWN_SETSIGMASK] {
      #expect(flags & Int32(flag) != 0, "\(flag)")
    }
  }

  static func runScript(pid: Int32, limit: Int, executable: String) throws -> Int32 {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/bin/sh")
    process.arguments = ["-c", SafeModeRelaunch.waitThenOpenScript, "sh", String(pid), String(limit), executable, "/nonexistent/Solara Test.app"]
    process.standardOutput = FileHandle.nullDevice
    process.standardError = FileHandle.nullDevice
    try process.run()
    process.waitUntilExit()
    return process.terminationStatus
  }

  @Test func theHelperGivesUpWithoutOpeningWhileTheOldInstanceStillRuns() throws {
    #expect(try Self.runScript(pid: getpid(), limit: 0, executable: "/nonexistent/Solara") == 0)
  }

  @Test func theHelperSkipsOpeningWhenSolaraAlreadyRunsFromTheBundle() throws {
    #expect(try Self.runScript(pid: 999_999, limit: 5, executable: "/bin/sh") == 0)
  }

  @Test func theHelperOpensOnceTheOldInstanceIsGoneAndNothingRunsFromTheBundle() throws {
    #expect(try Self.runScript(pid: 999_999, limit: 5, executable: "/nonexistent/Solara") != 0)
  }

  @Test func theHelperLogsWhyItDidNotOpenWithoutTheToken() {
    let script = SafeModeRelaunch.waitThenOpenScript
    #expect(script.contains(#"/usr/bin/logger -t Solara "safe mode relaunch gave up"#))
    #expect(script.contains(#"/usr/bin/logger -t Solara "safe mode relaunch skipped"#))
    #expect(!script.contains(LaunchSwitches.safeModeRequestVariable))
  }
}
