import argparse
import hashlib
import os
from pathlib import Path
import subprocess
import sys

parser = argparse.ArgumentParser()
parser.add_argument('--products', required=True)
parser.add_argument('--scratch', required=True)
parser.add_argument('--phase', choices=['red', 'green'], default='green')
parser.add_argument('--baseline', default='HEAD')
parser.add_argument('--mutation', choices=['outer'])
args = parser.parse_args()
repo = Path(__file__).resolve().parents[4]
phase = args.phase
out = Path(args.scratch).resolve()
out.mkdir(exist_ok=True)
products = Path(args.products).resolve()
env = dict(os.environ, CLANG_MODULE_CACHE_PATH=str(out / 'cache'), SWIFTPM_MODULECACHE_OVERRIDE=str(out / 'cache'))
base = ['swiftc', '-swift-version', '5', '-target', 'arm64-apple-macosx26.0', '-module-cache-path', str(out / 'cache'), '-I', str(products), '-I', str(out)]
core = sorted((repo / 'packages/sync/ios/Core').rglob('*.swift'))
core += [repo / 'packages/sync/ios' / name for name in ['PairingCoordinator.swift', 'PairingInstallationHost.swift', 'PairingService.swift']]
fingerprint = hashlib.sha256(b''.join(path.read_bytes() for path in core)).hexdigest()
marker = out / 'native-source.sha256'
if not marker.exists() or marker.read_text() != fingerprint:
    subprocess.run(base + ['-enable-testing', '-parse-as-library', '-emit-library', '-emit-module', '-module-name', 'SolaraSyncAdapter', '-emit-module-path', str(out / 'SolaraSyncAdapter.swiftmodule'), '-o', str(out / 'libSolaraSyncAdapter.dylib')] + list(map(str, core)), check=True, env=env)
    marker.write_text(fingerprint)
source = repo / 'packages/settings/ios/Adapters/SyncAdapter.swift'
if args.mutation == 'outer':
    mutated = out / 'SyncAdapter-mutant.swift'
    text = source.read_text()
    before = '  func invalidatePairing(_ reason: String) { PairingServices.shared.invalidate(reason) }'
    assert before in text
    mutated.write_text(text.replace(before, '  func invalidatePairing(_ reason: String) {}', 1))
    source = mutated
if phase == 'red':
    source = out / 'SyncAdapter-base.swift'
    baseline_source = subprocess.check_output(['git', '-C', str(repo), 'show', args.baseline + ':packages/settings/ios/Adapters/SyncAdapter.swift']).decode()
    if 'func invalidatePairing(' not in baseline_source:
        baseline_source += '\nextension SyncAdapter { func invalidatePairing(_ reason: String) {} }\n'
    source.write_text(baseline_source)
print('Native Settings entry source SHA256 ' + hashlib.sha256(source.read_bytes()).hexdigest() + ' phase=' + phase, flush=True)
objects = [products / (name + '.o') for name in ['SolaraUI', 'SolaraModel', 'SolaraStore', 'SolaraOmnibox', 'SolaraEngine', 'SolaraLive', 'SolaraProbes']]
binary = out / ('entries-' + phase)
subprocess.run(base + ['-parse-as-library', '-L', str(out), '-lSolaraSyncAdapter', str(source), str(repo / 'packages/settings/tests/pairing-service/SettingsEntries.swift')] + list(map(str, objects)) + ['-o', str(binary)], env=env, check=True)
env.update(PAIRING_SETTINGS_ENTRY_BINARY=str(binary), PAIRING_SETTINGS_ENTRY_SCRATCH=str(out / 'data'))
result = subprocess.run(['node', '--test', str(repo / 'packages/settings/tests/pairing-service/entries.test.mjs')], env=env)
sys.exit(result.returncode)
