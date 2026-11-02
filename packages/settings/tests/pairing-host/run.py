import argparse
import os
import re
import subprocess
from pathlib import Path

parser = argparse.ArgumentParser()
parser.add_argument('--products', required=True)
parser.add_argument('--scratch', required=True)
args = parser.parse_args()
here = Path(__file__).resolve().parent
repo = here.parents[3]
products = Path(args.products).resolve()
out = Path(args.scratch).resolve()
out.mkdir(parents=True, exist_ok=True)
env = dict(os.environ, CLANG_MODULE_CACHE_PATH=str(out / 'modules'), SWIFTPM_MODULECACHE_OVERRIDE=str(out / 'modules'))
base = ['swiftc', '-DDEBUG', '-swift-version', '5', '-target', 'arm64-apple-macosx26.0', '-I', str(products), '-I', str(out)]
for module in ['SolaraShell', 'SolaraCore']:
    command = base + ['-emit-module', '-emit-object', '-parse-as-library', '-module-name', module, str(here / (module + '.swift')), '-emit-module-path', str(out / (module + '.swiftmodule')), '-o', str(out / (module + '.o'))]
    subprocess.run(command, check=True, env=env, timeout=120)
objects = []
for target in ['SolaraUI', 'SolaraModel', 'SolaraStore', 'SolaraOmnibox', 'SolaraEngine', 'SolaraLive', 'SolaraProbes']:
    objects.append(products / (target + '.o'))
sources = [repo / 'packages/settings/ios/Adapters/SettingsAdapters.swift', repo / 'packages/settings/ios/NativeSettingsWindow.swift', repo / 'packages/settings/ios/SettingsDev.swift', here / 'Stubs.swift', here / 'Probe.swift']
subprocess.run(base + ['-parse-as-library', '-o', str(out / 'probe')] + list(map(str, sources + objects)) + [str(out / 'SolaraShell.o'), str(out / 'SolaraCore.o')], check=True, env=env, timeout=120)
results = []
failed = False
for mode in [[], ['--late-mode']]:
    run_env = dict(env, SOLARA_BACKGROUND='1', SOLARA_SYNC_PAIRING_FIXTURE='1', SOLARA_TEST_REAUTH='granted', SOLARA_DATA_DIR=str(out / ('late-data' if mode else 'data')))
    process = subprocess.run([str(out / 'probe')] + mode, env=run_env, capture_output=True, text=True, timeout=30)
    print(process.stdout, end='')
    print(process.stderr, end='')
    summary = re.findall(r'Completed Settings integration: (\d+) test, (\d+) assertions, (\d+) failures', process.stdout)
    if not summary:
        raise SystemExit('FAIL: Settings integration ended without a completed summary')
    tests, assertions, failures = map(int, summary[-1])
    results.append((tests, assertions, failures))
    if process.returncode != 0 or failures != 0 or tests != 1:
        failed = True
print(f'Completed Settings integration suite: {sum(x[0] for x in results)} tests, {sum(x[1] for x in results)} assertions, {sum(x[2] for x in results)} failures')
raise SystemExit(1 if failed else 0)
