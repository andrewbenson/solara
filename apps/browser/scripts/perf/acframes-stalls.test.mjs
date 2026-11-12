import assert from "node:assert/strict";
import { execFileSync } from "node:child_process";
import { mkdtempSync, readFileSync, rmSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { after, test } from "node:test";

const source = readFileSync(new URL("./acframes.m", import.meta.url), "utf8");
const start = source.indexOf("typedef struct {\n  char th;");
const end = source.indexOf("static void LoopActivity(", start);
assert.ok(start >= 0 && end > start);
const scratch = mkdtempSync(join(tmpdir(), "acframes-stalls-"));
const program = join(scratch, "stalls.c");
const binary = join(scratch, "stalls");
writeFileSync(program, `#include <assert.h>
#include <math.h>
#include <pthread.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
typedef int BOOL;
#define YES 1
#define NO 0
${source.slice(start, end)}
static void begin(double now) {
  pthread_mutex_lock(&gStallLock);
  StallBeginLocked(now);
  pthread_mutex_unlock(&gStallLock);
}
static void end(double now) {
  pthread_mutex_lock(&gStallLock);
  StallEndLocked(now);
  pthread_mutex_unlock(&gStallLock);
}
static void *sleepJS(void *unused) {
  StallBeforeWaiting(&gJSLoop, 300);
  return NULL;
}
int main(int argc, char **argv) {
  gStallsOn = YES;
  switch (atoi(argv[1])) {
  case 1:
    StallAfterWaiting(&gMainLoop, 100);
    begin(120);
    StallBeforeWaiting(&gMainLoop, 270);
    end(300);
    assert(gStallMain.n == 1 && gStallMain.busy == 150 && gStallMain.worst == 150);
    assert(gStallMain.buckets[4] == 1 && gStallMain.longCount == 1);
    assert(gStallMain.longs[0][0] == 120 && gStallMain.longs[0][1] == 150);
    break;
  case 2:
    StallAfterWaiting(&gMainLoop, 100);
    begin(120);
    end(270);
    assert(gStallMain.n == 1 && gStallMain.busy == 150 && gStallMain.worst == 150);
    StallBeforeWaiting(&gMainLoop, 400);
    assert(gStallMain.n == 1 && gStallMain.busy == 150);
    break;
  case 3:
    StallAfterWaiting(&gMainLoop, 100);
    begin(120);
    end(270);
    begin(300);
    end(450);
    StallBeforeWaiting(&gMainLoop, 500);
    assert(gStallMain.n == 1 && gStallMain.busy == 150 && gStallMain.worst == 150);
    assert(gStallMain.longs[0][0] == 300);
    break;
  case 4:
    StallAfterWaiting(&gMainLoop, 100);
    StallBeforeWaiting(&gMainLoop, 150);
    begin(200);
    StallAfterWaiting(&gMainLoop, 210);
    StallBeforeWaiting(&gMainLoop, 230);
    StallAfterWaiting(&gMainLoop, 250);
    end(280);
    assert(gStallMain.n == 2 && gStallMain.busy == 50 && gStallMain.worst == 30);
    break;
  case 5:
    StallAfterWaiting(&gMainLoop, 100);
    StallAfterWaiting(&gJSLoop, 110);
    begin(120);
    StallBeforeWaiting(&gMainLoop, 170);
    end(300);
    assert(gStallMain.n == 1 && gStallMain.busy == 50);
    assert(gStallJS.n == 1 && gStallJS.busy == 180 && gStallJS.worst == 180);
    StallBeforeWaiting(&gJSLoop, 330);
    assert(gStallJS.n == 1 && gStallJS.busy == 180);
    break;
  case 6:
    for (int i = 0; i < 1000; i++) {
      StallAfterWaiting(&gJSLoop, 100);
      begin(120);
      pthread_t thread;
      assert(pthread_create(&thread, NULL, sleepJS, NULL) == 0);
      end(300);
      assert(pthread_join(thread, NULL) == 0);
      assert(gStallJS.n == 1 && gStallJS.busy == 180 && gStallJS.worst == 180);
    }
    break;
  case 7:
    begin(100);
    StallAfterWaiting(&gMainLoop, 100);
    end(100);
    assert(gStallMain.n == 0 && gStallMain.busy == 0);
    break;
  default: return 2;
  }
  puts("passed");
  return 0;
}
`);
execFileSync("clang", ["-std=c11", "-pthread", program, "-o", binary], { timeout: 30000, stdio: "pipe" });
after(() => rmSync(scratch, { recursive: true, force: true }));
const cases = [
  "clips a completed iteration that began before the measurement",
  "counts an in-flight iteration at end without counting it again",
  "keeps active iterations across adjacent windows and clips each window",
  "excludes outside work and accumulates completed and active spans",
  "accounts for main and JS active intervals independently",
  "serializes JS completion racing with end without double counting",
  "does not invent a busy iteration for a zero-length span",
];
for (const [index, name] of cases.entries()) test(name, () => {
  assert.equal(execFileSync(binary, [String(index + 1)], { timeout: 10000, encoding: "utf8" }).trim(), "passed");
});
