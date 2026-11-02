import argparse
import os
from pathlib import Path
import shutil
import subprocess
import sys

parser = argparse.ArgumentParser()
parser.add_argument('--scratch', required=True)
args = parser.parse_args()
repo = Path(__file__).resolve().parents[4]
here = Path(__file__).resolve().parent
out = Path(args.scratch).resolve()
for path in ['Sources/SolaraUI', 'Sources/SolaraSyncAdapter', 'Sources/Adapter', 'Tests/AdapterTests']:
    (out / path).mkdir(parents=True, exist_ok=True)
(out / 'Package.swift').write_text('''// swift-tools-version:6.0
import PackageDescription
let package = Package(name: "AdapterHarness", platforms: [.macOS(.v14)], targets: [.target(name: "SolaraUI"), .target(name: "SolaraSyncAdapter"), .target(name: "Adapter", dependencies: ["SolaraUI", "SolaraSyncAdapter"]), .testTarget(name: "AdapterTests", dependencies: ["Adapter", "SolaraUI", "SolaraSyncAdapter"])], swiftLanguageModes: [.v5])
''')
shutil.copyfile(repo / 'native/SolaraKit/Sources/SolaraUI/Settings/Panes/SyncTrustedPairing.swift', out / 'Sources/SolaraUI/TrustedPairing.swift')
for source, target in [('Native.swift', 'Sources/SolaraSyncAdapter/Native.swift'), ('Environment.swift', 'Sources/Adapter/Environment.swift'), ('AdapterTests.swift', 'Tests/AdapterTests/AdapterTests.swift')]:
    shutil.copyfile(here / source, out / target)
source = (repo / 'packages/settings/ios/Adapters/PairingAdapter.swift').read_text()
source = source.replace('NSApp.isActive', 'HarnessEnvironment.foreground')
source = source.replace('!NSApp.isHidden', '!HarnessEnvironment.hidden')
(out / 'Sources/Adapter/PairingAdapter.swift').write_text(source)
env = dict(os.environ, CLANG_MODULE_CACHE_PATH=str(out / 'clang-cache'))
sys.exit(subprocess.run(['swift', 'test', '--package-path', str(out), '--disable-sandbox', '--cache-path', str(out / 'swift-cache'), '--config-path', str(out / 'swift-config'), '--security-path', str(out / 'swift-security')], env=env, timeout=180).returncode)
