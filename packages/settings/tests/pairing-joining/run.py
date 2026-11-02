import argparse
import os
from pathlib import Path
import subprocess
import sys

parser = argparse.ArgumentParser()
parser.add_argument('--scratch', required=True)
args = parser.parse_args()
repo = Path(__file__).resolve().parents[4]
here = Path(__file__).resolve().parent
out = Path(args.scratch).resolve()
out.mkdir(parents=True, exist_ok=True)
env = dict(os.environ, CLANG_MODULE_CACHE_PATH=str(out / 'cache'))
native = out / 'Native.swift'
native.write_text((repo / 'packages/sync/ios/PairingCoordinator.swift').read_text().split('\nprotocol PairingCoordinatingMailbox:')[0] + (here / 'Native.swift').read_text())
ui = repo / 'native/SolaraKit/Sources/SolaraUI/Onboarding/OnboardingPairing.swift'
base = ['swiftc', '-swift-version', '5', '-module-cache-path', str(out / 'cache'), '-I', str(out)]
for name, source in [('SolaraUI', ui), ('SolaraSyncAdapter', native)]:
    subprocess.run(base + ['-emit-library', '-emit-module', '-parse-as-library', '-module-name', name, str(source), '-o', str(out / ('lib' + name + '.dylib'))], check=True, env=env, timeout=120, cwd=out)
sources = [repo / 'packages/settings/ios/Adapters/PairingJoiningAdapter.swift', repo / 'packages/settings/ios/Onboarding/OnboardingDiscoveryAdapter.swift', here / 'Main.swift']
subprocess.run(base + ['-parse-as-library', '-L', str(out), '-lSolaraUI', '-lSolaraSyncAdapter', '-Xlinker', '-rpath', '-Xlinker', str(out)] + list(map(str, sources)) + ['-o', str(out / 'probe')], check=True, env=env, timeout=120)
env['PAIRING_JOINING_BINARY'] = str(out / 'probe')
sys.exit(subprocess.run(['node', '--test', str(here / 'entries.test.mjs')], env=env, timeout=30).returncode)
