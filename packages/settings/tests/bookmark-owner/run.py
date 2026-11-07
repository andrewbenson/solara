import argparse
import os
from pathlib import Path
import platform
import subprocess
import sys

parser = argparse.ArgumentParser()
parser.add_argument('--products')
parser.add_argument('cases', nargs='*')
args = parser.parse_args()
source = Path(__file__).resolve().parents[4]
package = source / 'native/SolaraKit'
here = Path(__file__).resolve().parent
output = Path(os.environ['SOLARA_HOST_TEST_BUILD']).resolve()
output.mkdir(parents=True, exist_ok=True)
environment = dict(os.environ)
environment['CLANG_MODULE_CACHE_PATH'] = str(output / 'clang')
environment['SWIFTPM_MODULECACHE_OVERRIDE'] = str(output / 'clang')
if args.products:
    build = Path(args.products).resolve()
else:
    build_command = ['swift', 'build', '--package-path', str(package), '--scratch-path', str(output / 'SolaraKit')]
    subprocess.run(build_command, env=environment, check=True, timeout=540)
    build = Path(subprocess.check_output(build_command + ['--show-bin-path'], env=environment, text=True, timeout=120).strip())
base = ['swiftc', '-swift-version', '6', '-parse-as-library', '-D', 'DEBUG', '-target', platform.machine() + '-apple-macosx26.0', '-I', str(build)]
objects = [build / (name + '.o') for name in ['SolaraModel', 'SolaraStore', 'SolaraEngine']]
files = [source / 'packages/settings/ios/Bookmarks/NativeBookmarkOwner.swift', here / 'Main.swift']
subprocess.run(base + ['-o', str(output / 'bookmark-owner-tests')] + [str(item) for item in files + objects], env=environment, check=True, timeout=180)
failed = False
for case in args.cases or ['replaceIsDurableBeforeItReturns', 'replaceRunsOnTheCallingThread', 'aRemapRefusesTheOldBindingAndWritesNothing', 'aBindingForAnotherEngineIsRefused', 'aStaleRevisionIsRefused', 'theWakeComesOnlyAfterTheDirectorySync', 'aJournalFailureThrowsAndKeepsTheOldDocument', 'theWriterIsLegacyUntilAnOwnerIsInstalled']:
    try:
        result = subprocess.run([str(output / 'bookmark-owner-tests'), case], env=environment, timeout=20)
        failed = failed or result.returncode != 0
    except subprocess.TimeoutExpired:
        print('FAIL ' + case + ': timed out', flush=True)
        failed = True
sys.exit(1 if failed else 0)
