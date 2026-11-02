import argparse
import os
from pathlib import Path
import subprocess
import sys

parser = argparse.ArgumentParser()
parser.add_argument('--scratch', required=True)
parser.add_argument('--mutation')
parser.add_argument('--baseline')
args = parser.parse_args()
repo = Path(__file__).resolve().parents[4]
out = Path(args.scratch).resolve()
out.mkdir(parents=True, exist_ok=True)
panes = repo / 'native/SolaraKit/Sources/SolaraUI/Settings/Panes'
model = out / 'SyncPaneModel.swift'
def pane_source(name):
    if args.baseline:
        path = 'native/SolaraKit/Sources/SolaraUI/Settings/Panes/' + name
        return subprocess.check_output(['git', '-C', str(repo), 'show', args.baseline + ':' + path], text=True)
    return (panes / name).read_text()

model_source = pane_source('SyncPane.swift').split('\nenum SyncText {')[0]
mutations = {
    'state-transition': ('    if let previous, (previous.enabled && !next.enabled) ||\n        (next.status == .locked && previous.status != .locked) || previous.folder != next.folder {', '    if !next.enabled || next.status == .locked || previous?.folder != next.folder {'),
    'sheet': ('        if case .trustedPairing = oldValue { services.invalidatePairing("reload") }\n', ''),
    'dispatch-helper': ('  func invalidatePairing(_ reason: String) { services.invalidatePairing(reason) }', '  func invalidatePairing(_ reason: String) {}'),
    'confirm': ('    services.invalidatePairing("rekey")\n    turningOn = true\n    await creation.confirmSeparateSync()', '    turningOn = true\n    await creation.confirmSeparateSync()'),
    'stop': ('  func stop(deleteData: Bool) async {\n    services.invalidatePairing("stop")', '  func stop(deleteData: Bool) async {'),
    'folder': ('  func chooseFolder() async {\n    services.invalidatePairing("folder")', '  func chooseFolder() async {'),
    'phrase-folder': ('  func changeFolderForPhrase() async {\n    services.invalidatePairing("folder")', '  func changeFolderForPhrase() async {'),
    'phrase': ('  func submitPhrase(_ text: String) async -> String? {\n    services.invalidatePairing("rekey")', '  func submitPhrase(_ text: String) async -> String? {'),
    'turn-on': ('  func turnOn() async {\n    services.invalidatePairing("rekey")', '  func turnOn() async {'),
    'surface': ('  public func pairingSurfaceRemoved() {\n    services.invalidatePairing("reload")', '  public func pairingSurfaceRemoved() {'),
    'state': ('      services.invalidatePairing("reload")\n      pairing?.surfaceChanged(.removed)', '      pairing?.surfaceChanged(.removed)'),
}
if args.mutation in mutations:
    before, after = mutations[args.mutation]
    assert before in model_source
    model_source = model_source.replace(before, after, 1)
if args.baseline and '  func invalidatePairing(_ reason: String) {' not in model_source:
    model_source += '\nextension SyncPaneModel { func invalidatePairing(_ reason: String) {} }\n'
model.write_text(model_source)
name = out / 'SyncPairingName.swift'
name.write_text((panes / 'SyncPairingControls.swift').read_text().split('\n@MainActor\npublic final class SyncAllowNativeButton')[0])
binary = out / 'probe'
creation = out / 'SyncCreationModel.swift'
creation_source = pane_source('SyncCreationModel.swift')
if args.mutation == 'creation-idle':
    before = '    guard state != .idle || currentInspection != nil else { return }\n'
    assert before in creation_source
    creation_source = creation_source.replace(before, '', 1)
if args.mutation == 'creation':
    before = '    services.invalidatePairing("reload")'
    assert before in creation_source
    creation_source = creation_source.replace(before, '', 1)
creation.write_text(creation_source)
sources = [model, name, creation] + [panes / p for p in ['SyncTrustedPairing.swift', 'SyncTrustedPairingModel.swift']] + [Path(__file__).with_name('Probe.swift')]
command = ['swiftc', '-disable-sandbox', '-swift-version', '5', '-parse-as-library', '-module-cache-path', str(out / 'cache')] + list(map(str, sources)) + ['-o', str(binary)]
subprocess.run(command, check=True, timeout=120)
env = dict(os.environ, PAIRING_MODEL_ENTRY_BINARY=str(binary))
sys.exit(subprocess.run(['node', '--test', str(Path(__file__).with_name('entries.test.mjs'))], env=env).returncode)
