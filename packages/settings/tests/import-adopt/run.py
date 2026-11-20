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
host = repo / 'packages/settings/ios'
sources = [host / 'SettingsJS.swift', here / 'Main.swift']
subprocess.run(['swiftc', '-swift-version', '5', '-module-cache-path', str(out / 'cache'), '-parse-as-library'] + list(map(str, sources)) + ['-o', str(out / 'probe')], check=True, env=env, timeout=120)
sys.exit(subprocess.run([str(out / 'probe')], env=env, timeout=30).returncode)
