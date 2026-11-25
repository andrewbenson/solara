import argparse
import os
from pathlib import Path
import platform
import subprocess

parser = argparse.ArgumentParser()
parser.add_argument('--products', required=True)
args = parser.parse_args()
source = Path(__file__).resolve().parents[4]
here = Path(__file__).resolve().parent
out = Path(os.environ['SOLARA_HOST_TEST_BUILD']).resolve()
out.mkdir(parents=True, exist_ok=True)
products = Path(args.products).resolve()
env = dict(os.environ, CLANG_MODULE_CACHE_PATH=str(out / 'clang'), DYLD_LIBRARY_PATH=str(out))
base = ['swiftc', '-D', 'DEBUG', '-swift-version', '6', '-parse-as-library', '-target', platform.machine() + '-apple-macosx26.0', '-module-cache-path', str(out / 'clang')]
core = source / 'packages/import/ios'
module = [str(path) for path in sorted((core / 'Core').glob('*.swift'))] + [str(core / 'ImportRead.swift'), str(here / 'ServiceStub.swift')]
core_base = base.copy()
core_base[core_base.index('-swift-version') + 1] = '5'
subprocess.run(core_base + ['-enable-testing', '-emit-library', '-emit-module', '-module-name', 'SolaraImportAdapter', '-emit-module-path', str(out / 'SolaraImportAdapter.swiftmodule'), '-o', str(out / 'libSolaraImportAdapter.dylib')] + module + ['-lsqlite3'], env=env, check=True, timeout=120)
objects = [products / (name + '.o') for name in ['SolaraUI', 'SolaraModel', 'SolaraStore', 'SolaraOmnibox', 'SolaraEngine', 'SolaraLive', 'SolaraProbes']]
files = [source / 'packages/settings/ios/Adapters/ImportRunConversion.swift', here / 'EngineStub.swift', here / 'Main.swift']
subprocess.run(base + ['-I', str(products), '-I', str(out), '-L', str(out), '-lSolaraImportAdapter', '-o', str(out / 'import-transport')] + list(map(str, files + objects)), env=env, check=True, timeout=120)
subprocess.run([str(out / 'import-transport'), str(source / 'packages/import/fixtures/home/Library/Application Support')], env=env, check=True, timeout=30)
