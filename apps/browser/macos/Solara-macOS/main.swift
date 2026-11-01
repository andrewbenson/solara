import AppKit
import SolaraCore
import SolaraStoreAdapter
import SolaraSyncAdapter

SolaraCoreHost.prepareEnvironment()

if getenv("SOLARA_PREWARM") != nil { exit(0) }

if let code = SafeStorageRekeyRun.runAtLaunch(
  chromeUsesRealKeychain: SolaraCoreHost.chromeUsesRealKeychain, installedUserDataDir: SolaraCoreHost.installedDataDirectory,
  stores: { RekeyStores(onStaged: $0) }) { exit(code) }

_ = MainActor.assumeIsolated { NativeStore.launchAtStartup() }
SolaraCoreHost.safeMode = NativeStore.safeMode

exit(SolaraCoreHost.run(argc: CommandLine.argc, argv: CommandLine.unsafeArgv) { AppDelegate() })
