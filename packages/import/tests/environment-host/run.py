import argparse
import os
from pathlib import Path
import subprocess

parser = argparse.ArgumentParser()
parser.add_argument('--scratch', required=True)
args = parser.parse_args()
here = Path(__file__).resolve().parent
repo = here.parents[3]
out = Path(args.scratch).resolve()
out.mkdir(parents=True, exist_ok=True)
base_env = dict(os.environ, SOLARA_IMPORT_SOURCE_DIR='/fixture/Library/Application Support', SOLARA_IMPORT_SAFARI_HOME='/safari-fixture', SOLARA_IMPORT_TEST_SECRET='fixture-secret', SOLARA_IMPORT_DIA_BUNDLE_ID='fixture.dia', SOLARA_IMPORT_DIA_FIXTURE='/fixture/dia.json')
for mode in ['Release', 'Debug']:
    binary = out / mode
    command = ['swiftc', '-swift-version', '5', '-parse-as-library', '-module-cache-path', str(out / 'cache')]
    if mode == 'Debug':
        command += ['-D', 'DEBUG']
    command += [str(repo / 'packages/import/ios/ImportEnvironment.swift'), str(here / 'Providers.swift'), str(here / 'Main.swift'), '-o', str(binary)]
    subprocess.run(command, check=True, timeout=120)
    for data_dir in [None, '', str(out / 'isolated')]:
        env = dict(base_env)
        if data_dir is None:
            env.pop('SOLARA_DATA_DIR', None)
        else:
            env['SOLARA_DATA_DIR'] = data_dir
        subprocess.run([str(binary)], check=True, env=env, timeout=10)
