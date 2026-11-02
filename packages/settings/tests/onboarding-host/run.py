import os
from pathlib import Path
import subprocess
import sys

source = Path(__file__).resolve().parents[4]
package = source / 'native/SolaraKit'
build = package / '.build/out/Products/Debug'
output = Path(os.environ['SOLARA_HOST_TEST_BUILD']).resolve()
output.mkdir(parents=True, exist_ok=True)
modules = output / 'Modules'
modules.mkdir(exist_ok=True)
environment = dict(os.environ)
environment['CLANG_MODULE_CACHE_PATH'] = str(output / 'clang')
environment['SWIFTPM_MODULECACHE_OVERRIDE'] = str(output / 'clang')
empty = output / 'Empty.swift'
empty.write_text('import Foundation\n')
for name in ['SolaraShell', 'SolaraShaders']:
    subprocess.run(['swiftc', '-emit-module', '-module-name', name, str(empty), '-emit-module-path', str(modules / (name + '.swiftmodule'))], env=environment, check=True)
subprocess.run(['swift', 'build', '--package-path', str(package)], env=environment, check=True)
objects = []
for name in ['SolaraUI', 'SolaraModel', 'SolaraStore', 'SolaraOmnibox', 'SolaraEngine', 'SolaraLive', 'SolaraProbes']:
    objects.append(str(build / (name + '.o')))
host = source / 'packages/settings/ios'
files = [host / 'Onboarding/NativeOnboarding.swift', host / 'Onboarding/OnboardingAdapter.swift', host / 'Services/NativeAppStartup.swift', Path(__file__).with_name('Stubs.swift'), Path(__file__).with_name('Main.swift')]
command = ['swiftc', '-swift-version', '6', '-parse-as-library', '-I', str(build), '-I', str(modules), '-o', str(output / 'host-tests')] + [str(p) for p in files] + objects
subprocess.run(command, env=environment, check=True)
failed = False
for case in sys.argv[1:] or ['dismissalKeepsOwnPresentationId', 'automaticDismissalHasNoPresentationId', 'pendingBrowserEntryRemount', 'failedBrowserEntryRemount', 'pendingBrowserEntryReload', 'failedBrowserEntryReload', 'pendingInstallRemount', 'failedInstallRemount', 'pendingInstallReload', 'failedInstallReload', 'firstLaunchStartupKeepsIntroAndHostWindow', 'showOnboardingWithOnlySessionForcesIntro', 'savedIntroRestartsIntro', 'folderAdapterAdmitsChangeAfterSelection', 'folderAdapterRejectsStaleSelection', 'recoveryWithoutHostReportsUnavailable', 'importCancellationDrainsThroughProductionAdapter', 'approvedInstallSurvivesHostUnmount', 'launchCommittedJoinWithoutOnboardingMount', 'replacementCommittedInstallDoesNotReuseOldBrowserEntry', 'joinedCompletionWaitsForTheDurableWrite', 'joinedWriteWaitsForSuccessfulAcknowledgment', 'joinedWritePropagatesImmediateFailure', 'failedStagedBrowserEntryCanBeRetried', 'failedStagedInstallIsAcknowledgedOnRecovery', 'silentBrowserEntryRetryRemount', 'silentBrowserEntryRetryReload', 'silentBrowserEntryRetryThenInstalled', 'installedBeforeBrowserEntryRetry', 'showOnboardingAfterFinishedCommittedJoin', 'showOnboardingReroutesClosedWindow', 'automaticMountCannotTakeShowOnboarding', 'nilWindowReplayRequiresPresentation', 'supersededReplayCannotMount', 'disconnectedReplayCannotMount', 'unavailableReplayCannotMount']:
    result = subprocess.run([str(output / 'host-tests'), case], env=environment)
    failed = failed or result.returncode != 0
sys.exit(1 if failed else 0)
