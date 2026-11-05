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
modules = output / 'Modules'
modules.mkdir(exist_ok=True)
environment = dict(os.environ)
environment['CLANG_MODULE_CACHE_PATH'] = str(output / 'clang')
environment['SWIFTPM_MODULECACHE_OVERRIDE'] = str(output / 'clang')
environment['SOLARA_BACKGROUND'] = '1'
if args.products:
    build = Path(args.products).resolve()
else:
    build_command = ['swift', 'build', '--package-path', str(package), '--scratch-path', str(output / 'SolaraKit')]
    subprocess.run(build_command, env=environment, check=True, timeout=540)
    build = Path(subprocess.check_output(build_command + ['--show-bin-path'], env=environment, text=True, timeout=120).strip())
base = ['swiftc', '-swift-version', '6', '-parse-as-library', '-D', 'DEBUG', '-target', platform.machine() + '-apple-macosx26.0', '-I', str(build), '-I', str(modules)]
for name in ['SolaraCore', 'SolaraShell']:
    command = base + ['-emit-module', '-emit-object', '-module-name', name, str(here / (name + '.swift')), '-emit-module-path', str(modules / (name + '.swiftmodule')), '-o', str(output / (name + '.o'))]
    subprocess.run(command, env=environment, check=True, timeout=120)
objects = [build / (name + '.o') for name in ['SolaraUI', 'SolaraModel', 'SolaraStore', 'SolaraOmnibox', 'SolaraEngine', 'SolaraLive', 'SolaraProbes']]
objects += [output / 'SolaraCore.o', output / 'SolaraShell.o']
files = [source / 'packages/settings/ios/SidePanel/NativeExtensionSidePanel.swift', here / 'Stubs.swift', here / 'Main.swift']
subprocess.run(base + ['-o', str(output / 'host-tests')] + [str(item) for item in files + objects], env=environment, check=True, timeout=120)
failed = False
for case in args.cases or ['settleWithoutEchoFinishes', 'staleEchoDoesNotCancelSettle', 'outsideWidthWinsOverDrag', 'droppedEchoFallsBack', 'echoQueueIsBounded', 'keyChangeClearsQueue', 'closeClearsQueue', 'resetWidthEchoes']:
    try:
        result = subprocess.run([str(output / 'host-tests'), case], env=environment, timeout=10)
        failed = failed or result.returncode != 0
    except subprocess.TimeoutExpired:
        print('FAIL ' + case + ': timed out', flush=True)
        failed = True
sys.exit(1 if failed else 0)
