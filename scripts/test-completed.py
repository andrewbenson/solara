import argparse
import json
import os
import re
import subprocess
import sys
import time
from pathlib import Path


def summarize(output, kind):
    if kind in ['swift', 'xctest']:
        all_suites = re.findall(r"^Test Suite 'All tests' (passed|failed)[^\n]*\n\s*Executed (\d+) tests?, with (\d+) failures?", output, re.MULTILINE)
        selected = re.findall(r"^Test Suite 'Selected tests' (passed|failed)[^\n]*\n\s*Executed (\d+) tests?, with (\d+) failures?", output, re.MULTILINE)
        suites = all_suites or selected
        all_started = len(re.findall(r"^Test Suite 'All tests' started", output, re.MULTILINE))
        selected_started = len(re.findall(r"^Test Suite 'Selected tests' started", output, re.MULTILINE))
        if (all_started and all_started != len(all_suites)) or (not all_started and selected_started != len(selected)):
            raise ValueError('XCTest started suite did not complete')
        xctests = sum(int(x[1]) for x in suites)
        xcfailures = sum(int(x[2]) for x in suites)
        xcpassed = all(x[0] == 'passed' and int(x[2]) == 0 for x in suites)
        if kind == 'xctest':
            if not suites or xctests == 0:
                raise ValueError('XCTest completed suite summary missing or empty')
            return {'tests': xctests, 'failures': xcfailures, 'passed': xcpassed}
        found = re.findall(r'[✔✘] Test run with (\d+) tests?(?: in \d+ suites?)? (passed|failed)', output)
        started = len(re.findall(r'◇ Test run started\.', output))
        if len(found) != started or (not found and not suites):
            raise ValueError(f'Swift Testing completed summaries missing: {started} started, {len(found)} completed')
        if "Test Suite '" in output and not suites:
            raise ValueError('XCTest completed suite summary missing')
        count = sum(int(x[0]) for x in found)
        if count + xctests == 0:
            raise ValueError('Test run completed zero tests')
        return {'tests': count + xctests, 'swift_testing': count, 'xctest': xctests, 'passed': all(x[1] == 'passed' for x in found) and xcpassed}
    if kind == 'node':
        values = {}
        for name in ['tests', 'pass', 'fail', 'skipped', 'todo', 'suites']:
            matches = re.findall(r'(?:#|ℹ) ' + name + r' (\d+)', output)
            if matches:
                values[name] = int(matches[-1])
        if not all(key in values for key in ['tests', 'pass', 'fail']):
            raise ValueError('Node completed summary missing')
        if not re.search(r'(?:#|ℹ) duration_ms ', output) or values['tests'] == 0:
            raise ValueError('Node completed duration summary missing or zero tests')
        return {**values, 'passed': values['fail'] == 0}
    return {'passed': True}


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument('--kind', choices=['swift', 'node', 'xctest', 'command'], required=True)
    parser.add_argument('--log', required=True)
    parser.add_argument('--cwd')
    parser.add_argument('--timeout', type=int, default=540)
    parser.add_argument('command', nargs=argparse.REMAINDER)
    args = parser.parse_args()
    command = args.command[1:] if args.command[:1] == ['--'] else args.command
    started = time.monotonic()
    log = Path(args.log).resolve()
    log.parent.mkdir(parents=True, exist_ok=True)
    with log.open('w') as stream:
        stream.write('$ ' + repr(command) + '\n')
        stream.flush()
        process = subprocess.Popen(command, cwd=args.cwd, stdout=stream, stderr=subprocess.STDOUT, start_new_session=True)
        try:
            result = process.wait(timeout=args.timeout)
        except subprocess.TimeoutExpired:
            import signal
            os.killpg(process.pid, signal.SIGTERM)
            result = 124
            stream.write('\nDEADLINE EXCEEDED\n')
    output = log.read_text(errors='replace').partition('\n')[2]
    metadata = {'command': command, 'cwd': args.cwd or os.getcwd(), 'exit': result, 'seconds': round(time.monotonic() - started, 3), 'log': str(log)}
    try:
        metadata.update(summarize(output, args.kind))
        metadata['passed'] = metadata['passed'] and result == 0
    except ValueError as error:
        metadata.update(passed=False, error=str(error))
    log.with_suffix(log.suffix + '.json').write_text(json.dumps(metadata, indent=2) + '\n')
    print(json.dumps(metadata))
    return 0 if metadata['passed'] else (result or 1)


if __name__ == '__main__':
    sys.exit(main())
