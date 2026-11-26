import argparse
import os
import platform
from pathlib import Path
import subprocess

parser = argparse.ArgumentParser()
parser.add_argument('--products', required=True)
parser.add_argument('--scratch', required=True)
args = parser.parse_args()
here = Path(__file__).resolve().parent
repo = here.parents[3]
out = Path(args.scratch).resolve()
out.mkdir(parents=True, exist_ok=True)
products = Path(args.products).resolve()
objects = [products / (name + '.o') for name in ['SolaraUI', 'SolaraModel', 'SolaraStore', 'SolaraOmnibox', 'SolaraEngine', 'SolaraLive', 'SolaraProbes']]
files = [repo / 'packages/settings/ios/Adapters/ImportRunRouting.swift', here / 'Main.swift']
command = ['swiftc', '-D', 'DEBUG', '-swift-version', '6', '-parse-as-library', '-target', platform.machine() + '-apple-macosx26.0', '-module-cache-path', str(out / 'cache'), '-I', str(products), '-o', str(out / 'import-routing')]
subprocess.run(command + list(map(str, files + objects)), check=True, timeout=120)
subprocess.run([str(out / 'import-routing')], check=True, timeout=10)
