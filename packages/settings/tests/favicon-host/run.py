import argparse
import os
from pathlib import Path
import subprocess

parser = argparse.ArgumentParser()
parser.add_argument('--products')
args = parser.parse_args()
source = Path(__file__).resolve().parents[4]
here = Path(__file__).resolve().parent
output = Path(os.environ['SOLARA_HOST_TEST_BUILD']).resolve()
output.mkdir(parents=True, exist_ok=True)
environment = dict(os.environ)
environment['CLANG_MODULE_CACHE_PATH'] = str(output / 'clang')
environment['SWIFTPM_MODULECACHE_OVERRIDE'] = str(output / 'clang')
environment['SOLARA_BACKGROUND'] = '1'
if args.products:
    build = Path(args.products).resolve()
else:
    command = ['swift', 'build', '--package-path', str(source / 'native/SolaraKit'), '--scratch-path', str(output / 'SolaraKit')]
    subprocess.run(command, env=environment, check=True, timeout=540)
    build = Path(subprocess.check_output(command + ['--show-bin-path'], env=environment, text=True, timeout=60).strip())
objects = [build / (name + '.o') for name in ['SolaraUI', 'SolaraModel', 'SolaraStore', 'SolaraOmnibox', 'SolaraEngine', 'SolaraLive', 'SolaraProbes']]
files = [source / 'packages/settings/ios/Hosted/HostedViews.swift', source / 'packages/settings/ios/Primitives/HostedFavicon.swift', here / 'Stubs.swift', here / 'Main.swift']
subprocess.run(['swiftc', '-D', 'DEBUG', '-swift-version', '6', '-parse-as-library', '-I', str(build), '-o', str(output / 'host-tests')] + [str(path) for path in files + objects], env=environment, check=True, timeout=120)
subprocess.run([str(output / 'host-tests')], env=environment, check=True, timeout=10)
