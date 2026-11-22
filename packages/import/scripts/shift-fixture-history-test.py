import os
import shutil
import sqlite3
import subprocess
import sys
import tempfile

HERE = os.path.dirname(os.path.abspath(__file__))
FIXTURE = os.path.realpath(os.path.join(HERE, "..", "fixtures", "home")) if len(sys.argv) < 2 else os.path.realpath(sys.argv[1])
SHIFT = os.path.join(HERE, "shift-fixture-history.py")
DAY = 86_400
NOW = 1_800_000_000

work = tempfile.mkdtemp()
home = os.path.join(work, "home")
shutil.copytree(FIXTURE, home)
subprocess.run([sys.executable, "-I", SHIFT, home, str(NOW)], check=True, stdout=subprocess.DEVNULL)


def ages(path, sql, to_unix):
    db = sqlite3.connect(path)
    rows = {key: (NOW - to_unix(at)) / DAY for key, at in db.execute(sql)}
    db.close()
    return rows


support = os.path.join(home, "Library", "Application Support")
chrome = ages(os.path.join(support, "Google", "Chrome", "Default", "History"),
              "SELECT url, last_visit_time FROM urls", lambda t: t / 1e6 - 11_644_473_600)
assert chrome["https://no-title.example/"] > 90, chrome["https://no-title.example/"]
assert 0 < chrome["https://newest.example/"] < 1, chrome["https://newest.example/"]
recent = [age for url, age in chrome.items() if url != "https://no-title.example/"]
assert recent and max(recent) < 90, max(recent)
firefox = ages(os.path.join(support, "Firefox", "Profiles", "abcd1234.default-release", "places.sqlite"),
               "SELECT url, last_visit_date FROM moz_places WHERE last_visit_date IS NOT NULL", lambda t: t / 1e6)
assert firefox and all(0 < age < 90 for age in firefox.values()), firefox
assert "https://in-wal.example/" in firefox, sorted(firefox)
safari = ages(os.path.join(home, "Library", "Safari", "History.db"),
              "SELECT id, visit_time FROM history_visits", lambda t: t + 978_307_200)
assert safari and all(0 < age < 90 for age in safari.values()), safari
refused = subprocess.run([sys.executable, "-I", SHIFT, FIXTURE, str(NOW)], capture_output=True)
assert refused.returncode != 0
shutil.rmtree(work)
print("ok", len(chrome), len(firefox), len(safari))
