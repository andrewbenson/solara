#!/usr/bin/env python3
"""Moves the history in a copy of packages/import/fixtures/home forward so its newest visit is an hour ago.

    python3 -I shift-fixture-history.py <copied home> [now unix seconds]

Every visit keeps its age relative to the fixture's newest visit (2026-09-01 00:00 UTC), so rows the fixture made
too old to import stay too old. It refuses to run on the fixture itself.
"""

import os
import sqlite3
import sys
import time

FIXTURE_NEWEST = 1788220800

if len(sys.argv) < 2 or sys.argv[1] in ("-h", "--help"):
    print(__doc__.strip())
    sys.exit(0 if len(sys.argv) > 1 else 64)
home = os.path.realpath(sys.argv[1])
if home.endswith(os.path.join("packages", "import", "fixtures", "home")):
    sys.exit("refusing to shift the fixture itself")
now = float(sys.argv[2]) if len(sys.argv) > 2 else time.time()
shift = max(0.0, now - 3600 - FIXTURE_NEWEST)
micro = int(shift * 1_000_000)


def update(path, statements):
    db = sqlite3.connect(path)
    tables = {row[0] for row in db.execute("SELECT name FROM sqlite_master WHERE type = 'table'")}
    for sql, args in statements:
        if sql.split()[1] in tables:
            db.execute(sql, args)
    db.commit()
    db.close()


for root, _, files in os.walk(home):
    for name in files:
        path = os.path.join(root, name)
        if name == "History":
            update(path, [("UPDATE urls SET last_visit_time = last_visit_time + ? WHERE last_visit_time > 0", (micro,)),
                          ("UPDATE visits SET visit_time = visit_time + ?", (micro,))])
        elif name == "places.sqlite":
            update(path, [("UPDATE moz_places SET last_visit_date = last_visit_date + ? WHERE last_visit_date IS NOT NULL", (micro,)),
                          ("UPDATE moz_historyvisits SET visit_date = visit_date + ?", (micro,))])
        elif name == "History.db" and os.path.basename(root) == "Safari":
            update(path, [("UPDATE history_visits SET visit_time = visit_time + ?", (shift,))])
print(int(shift))
