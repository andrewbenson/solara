import os
import sys
import tempfile
import unittest

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import series  # noqa: E402

BASE_TEXT = "".join(f"line {n}\n" for n in range(1, 21))

THROTTLE = """--- a/cc/state.h
+++ b/cc/state.h
@@ -9,6 +9,7 @@
 line 9
 line 10
 line 11
+  bool pending_ = true;
 line 12
 line 13
 line 14
"""

FULL_RATE = """--- a/cc/state.h
+++ b/cc/state.h
@@ -9,7 +9,8 @@
 line 9
 line 10
 line 11
-  bool pending_ = true;
+  bool pending_ = false;
+  int rate_ = 120;
 line 12
 line 13
 line 14
"""

THIRD = """--- a/cc/state.h
+++ b/cc/state.h
@@ -10,8 +10,9 @@
 line 10
 line 11
   bool pending_ = false;
   int rate_ = 120;
+  int grace_ = 1;
 line 12
 line 13
 line 14
"""

UNRELATED = """--- a/other.cc
+++ b/other.cc
@@ -1,3 +1,4 @@
 line 1
+added
 line 2
 line 3
"""


class OverlappingPatches(unittest.TestCase):
    def setUp(self):
        self.patches = tempfile.TemporaryDirectory()
        self.tree = tempfile.TemporaryDirectory()
        self.here = series.HERE
        series.HERE = self.patches.name
        for name, text in (("throttle.patch", THROTTLE), ("full-rate.patch", FULL_RATE), ("unrelated.patch", UNRELATED),
                           ("third.patch", THIRD)):
            with open(os.path.join(self.patches.name, name), "w") as f:
                f.write(text)
        self.steps = [series.Step("chromium", name, n) for n, name in
                      enumerate(("throttle.patch", "full-rate.patch", "unrelated.patch"), 1)]
        os.makedirs(os.path.join(self.tree.name, "cc"))
        for path in ("cc/state.h", "other.cc"):
            with open(os.path.join(self.tree.name, path), "w") as f:
                f.write(BASE_TEXT)

    def tearDown(self):
        series.HERE = self.here
        self.patches.cleanup()
        self.tree.cleanup()

    def apply(self, *indexes):
        for index in indexes:
            self.assertIsNone(series.apply_step(self.steps[index], self.tree.name))

    def applied(self, index):
        return series.is_applied(self.steps[index], self.tree.name) or \
            series.applied_under_later(self.steps, index, self.tree.name)

    def test_an_earlier_patch_a_later_one_rewrote_counts_as_applied(self):
        self.apply(0, 1, 2)
        self.assertFalse(series.is_applied(self.steps[0], self.tree.name))
        self.assertTrue(self.applied(0))
        self.assertTrue(self.applied(1))
        self.assertTrue(self.applied(2))

    def test_a_partly_applied_series_reports_each_step_as_it_is(self):
        self.apply(0)
        self.assertTrue(self.applied(0))
        self.assertFalse(self.applied(1))
        self.assertFalse(self.applied(2))

    def test_a_series_stopped_before_a_third_overlapping_patch_still_finds_the_first(self):
        steps = self.steps[:2] + [series.Step("chromium", "third.patch", 4)]
        self.apply(0, 1)
        self.assertTrue(series.applied_under_later(steps, 0, self.tree.name))
        self.assertFalse(series.is_applied(steps[2], self.tree.name))
        self.assertFalse(series.applied_under_later(steps, 2, self.tree.name))

    def test_a_fresh_tree_has_nothing_applied(self):
        for index in range(3):
            self.assertFalse(self.applied(index))

    def test_the_check_leaves_the_tree_unchanged(self):
        self.apply(0, 1)
        before = open(os.path.join(self.tree.name, "cc/state.h")).read()
        self.applied(0)
        self.assertEqual(open(os.path.join(self.tree.name, "cc/state.h")).read(), before)


if __name__ == "__main__":
    unittest.main()
