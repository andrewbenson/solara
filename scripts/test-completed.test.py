import importlib.util
from pathlib import Path
import tempfile
import subprocess
import sys
import unittest

runner = Path(__file__).with_name('test-completed.py')
spec = importlib.util.spec_from_file_location('completed', runner)
module = importlib.util.module_from_spec(spec)
spec.loader.exec_module(module)

class CompletedSummaryTests(unittest.TestCase):
    def test_summary_in_command_header_does_not_count_as_child_output(self):
        with tempfile.TemporaryDirectory() as directory:
            result = subprocess.run([sys.executable, str(runner), '--kind', 'swift', '--log', str(Path(directory) / 'header.log'), '--', sys.executable, '-c', "import sys; sys.exit(0); print('◇ Test run started.'); print('✔ Test run with 3 tests passed')"], capture_output=True, text=True)
        self.assertEqual(result.returncode, 1)
        self.assertIn('completed summaries missing', result.stdout)

    def test_zero_exit_without_summary_is_failure(self):
        with tempfile.TemporaryDirectory() as directory:
            result = subprocess.run([sys.executable, str(runner), '--kind', 'swift', '--log', str(Path(directory) / 'early.log'), '--', sys.executable, '-c', 'print("◇ Test run started.")'], capture_output=True, text=True)
        self.assertEqual(result.returncode, 1)
        self.assertIn('completed summaries missing', result.stdout)

    def test_each_started_swift_target_must_complete(self):
        with self.assertRaises(ValueError):
            module.summarize('◇ Test run started.\n✔ Test run with 3 tests passed\n◇ Test run started.', 'swift')

    def test_failed_swift_target_cannot_hide_behind_later_pass(self):
        summary = module.summarize('◇ Test run started.\n✘ Test run with 3 tests failed\n◇ Test run started.\n✔ Test run with 2 tests passed', 'swift')
        self.assertFalse(summary['passed'])
        self.assertEqual(summary['tests'], 5)

    def test_outer_xctest_summary_precedes_nested_subprocess_output(self):
        summary = module.summarize("Test Suite 'All tests' started\nTest Suite 'All tests' failed at time.\n Executed 281 tests, with 23 failures\nTest Suite 'Selected tests' started\nTest Suite 'Selected tests' passed at time.\n Executed 1 test, with 0 failures\n◇ Test run started.\n✔ Test run with 0 tests in 0 suites passed", 'swift')
        self.assertEqual(summary['tests'], 281)
        self.assertFalse(summary['passed'])

    def test_each_started_xctest_target_must_complete(self):
        with self.assertRaises(ValueError):
            module.summarize("Test Suite 'All tests' started\nTest Suite 'All tests' passed at time.\n Executed 3 tests, with 0 failures\nTest Suite 'All tests' started", 'xctest')

    def test_complete_node_summary_is_required(self):
        with self.assertRaises(ValueError):
            module.summarize('ok 1 - partial', 'node')
        self.assertEqual(module.summarize('# tests 4\n# pass 4\n# fail 0\n# duration_ms 1', 'node')['tests'], 4)

if __name__ == '__main__':
    unittest.main()
