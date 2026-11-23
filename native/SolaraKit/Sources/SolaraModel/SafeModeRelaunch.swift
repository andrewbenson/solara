import Foundation

public enum SafeModeRelaunch {
  public static let bookmarkQuitTimeoutSeconds = 30
  public static let updaterQuitWaitLimitSeconds = 8
  public static let quitMarginSeconds = 15
  public static let waitSeconds = bookmarkQuitTimeoutSeconds + updaterQuitWaitLimitSeconds + quitMarginSeconds
  public static let pollsPerSecond = 10
  public static let waitThenOpenScript =
    #"pid=$1; limit=$2; executable=$3; shift 3; n=0; while kill -0 "$pid" 2>/dev/null; do n=$((n+1)); if [ "$n" -gt "$limit" ]; then /usr/bin/logger -t Solara "safe mode relaunch gave up: the failed instance was still running"; exit 0; fi; sleep 0.1; done; if /bin/ps -axo comm= | /usr/bin/grep -Fxq -- "$executable"; then /usr/bin/logger -t Solara "safe mode relaunch skipped: Solara is already running from this bundle"; exit 0; fi; exec /usr/bin/open -n "$@""#
  public static let passedVariables = ["SOLARA_DATA_DIR", "SOLARA_BACKGROUND", LaunchSwitches.defaultsVariable]
  public static let developmentVariables = ["SOLARA_REMOTE_DEBUGGING_PORT", "SOLARA_JS_LOCATION", LaunchSwitch.nativeWindowLayout.rawValue]
  public static let helperEnvironment = ["PATH=/usr/bin:/bin:/usr/sbin:/sbin"]
  public static let fixedArgumentCount = 7

  public static func arguments(
    waitingFor pid: Int32, bundlePath: String, executableName: String, environment: [String: String], development: Bool, safeModeToken: String
  ) -> [String] {
    let names = passedVariables + (development ? developmentVariables : [])
    let passed = names.flatMap { name -> [String] in
      guard !name.hasPrefix("SOLARA_TEST_"), let value = environment[name], !value.isEmpty else { return [] }
      return ["--env", "\(name)=\(value)"]
    }
    let token = ["--env", "\(LaunchSwitches.safeModeRequestVariable)=\(safeModeToken)"]
    let background = environment["SOLARA_BACKGROUND"] == "1" ? ["-g"] : []
    let executable = "\(bundlePath)/Contents/MacOS/\(executableName)"
    return ["/bin/sh", "-c", waitThenOpenScript, "sh", String(pid), String(waitSeconds * pollsPerSecond), executable] + background + passed + token + [bundlePath]
  }

  public static func originalBundleURL(_ url: URL) -> URL {
    #if os(macOS)
    typealias IsTranslocated = @convention(c) (CFURL, UnsafeMutablePointer<Bool>, UnsafeMutablePointer<Unmanaged<CFError>?>?) -> UInt8
    typealias OriginalPath = @convention(c) (CFURL, UnsafeMutablePointer<Unmanaged<CFError>?>?) -> Unmanaged<CFURL>?
    guard let security = dlopen("/System/Library/Frameworks/Security.framework/Security", RTLD_LAZY) else { return url }
    defer { dlclose(security) }
    guard let isTranslocatedSymbol = dlsym(security, "SecTranslocateIsTranslocatedURL"),
      let originalPathSymbol = dlsym(security, "SecTranslocateCreateOriginalPathForURL") else { return url }
    var translocated = false
    guard unsafeBitCast(isTranslocatedSymbol, to: IsTranslocated.self)(url as CFURL, &translocated, nil) != 0, translocated,
      let original = unsafeBitCast(originalPathSymbol, to: OriginalPath.self)(url as CFURL, nil)?.takeRetainedValue()
    else { return url }
    return original as URL
    #else
    return url
    #endif
  }

  #if os(macOS)
  public static let spawnFlags = Int16(POSIX_SPAWN_SETSID | POSIX_SPAWN_CLOEXEC_DEFAULT | POSIX_SPAWN_SETSIGDEF | POSIX_SPAWN_SETSIGMASK)
  #endif

  @discardableResult
  public static func spawn(_ arguments: [String]) -> Bool {
    #if os(macOS)
    guard let executable = arguments.first else { return false }
    var attributes: posix_spawnattr_t?
    guard posix_spawnattr_init(&attributes) == 0 else { return false }
    defer { posix_spawnattr_destroy(&attributes) }
    guard posix_spawnattr_setflags(&attributes, spawnFlags) == 0 else { return false }
    var defaultSignals = sigset_t()
    sigfillset(&defaultSignals)
    var signalMask = sigset_t()
    sigemptyset(&signalMask)
    guard posix_spawnattr_setsigdefault(&attributes, &defaultSignals) == 0, posix_spawnattr_setsigmask(&attributes, &signalMask) == 0 else { return false }
    var actions: posix_spawn_file_actions_t?
    guard posix_spawn_file_actions_init(&actions) == 0 else { return false }
    defer { posix_spawn_file_actions_destroy(&actions) }
    for (descriptor, flags) in [(Int32(0), O_RDONLY), (Int32(1), O_WRONLY), (Int32(2), O_WRONLY)] {
      guard posix_spawn_file_actions_addopen(&actions, descriptor, "/dev/null", flags, 0) == 0 else { return false }
    }
    let argv: [UnsafeMutablePointer<CChar>?] = arguments.map { strdup($0) } + [nil]
    let envp: [UnsafeMutablePointer<CChar>?] = helperEnvironment.map { strdup($0) } + [nil]
    defer { for pointer in argv + envp { free(pointer) } }
    var child: pid_t = 0
    return posix_spawn(&child, executable, &actions, &attributes, argv, envp) == 0
    #else
    return false
    #endif
  }
}
