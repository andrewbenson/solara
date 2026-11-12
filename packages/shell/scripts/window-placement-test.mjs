import assert from 'node:assert/strict';
import {spawnSync} from 'node:child_process';
import {existsSync, mkdirSync, readFileSync, renameSync, rmSync, writeFileSync} from 'node:fs';
import {join, resolve} from 'node:path';
import {launch, parsePort, session, sleep} from '../../../scripts/lib/instance.mjs';

assert.equal(process.argv.length, 4, 'usage: node packages/shell/scripts/window-placement-test.mjs <Debug app> <scratch>; run under scripts/agent/locked uitest and timeout');
const appPath = resolve(process.argv[2]);
assert.equal(appPath.split('/').at(-2), 'Debug', 'use a Debug build with the development command harness');
const scratch = resolve(process.argv[3]);
mkdirSync(scratch, {recursive: true});
const data = join(scratch, 'data');
assert(!existsSync(data), 'use a fresh scratch directory for isolated app data');
const library = join(scratch, 'window-placement-probe.dylib');
const deadline = Date.now() + 120000;
const operations = [];
const checks = [];
let app;
let sequence = 0;
let windowNumber;
let target;

function remaining(maximum) {
  const left = deadline - Date.now();
  assert(left > 0, 'window placement test exceeded its 120 second internal deadline');
  return Math.min(maximum, left);
}

function save() {
  writeFileSync(join(scratch, 'operations.json'), JSON.stringify(operations, null, 2));
  writeFileSync(join(scratch, 'checks.json'), JSON.stringify(checks, null, 2));
}

function check(name, actual, expected) {
  const matches = Object.keys(expected).every(key => Math.abs(actual[key] - expected[key]) <= 1);
  checks.push({name, status: matches ? 'pass' : 'fail', actual, expected});
  save();
}

function skip(name, reason) {
  checks.push({name, status: 'skip', reason});
  save();
}

async function command(action, extra = {}) {
  const id = String(++sequence);
  const resultPath = join(scratch, 'result.json');
  rmSync(resultPath, {force: true});
  const request = {id, action, target, windowNumber, settleMs: action === 'read' ? 100 : action === 'frame' ? 500 : 900, ...extra};
  const temporary = join(scratch, 'command.tmp');
  writeFileSync(temporary, JSON.stringify(request));
  renameSync(temporary, join(scratch, 'command.json'));
  const end = Date.now() + remaining(8000);
  for (; Date.now() < end; await sleep(50)) {
    assert(app.alive, `app exited during ${action}`);
    if (!existsSync(resultPath)) continue;
    const result = JSON.parse(readFileSync(resultPath, 'utf8'));
    if (result.id !== id) continue;
    operations.push(result);
    save();
    assert(!result.error && !result.exception, JSON.stringify(result));
    windowNumber = result.windowNumber;
    return result;
  }
  operations.push({request, error: 'operation exceeded eight second deadline or internal run deadline'});
  save();
  throw new Error(`probe timed out during ${action}`);
}

const array = frame => [frame.x, frame.y, frame.width, frame.height];

async function frame(name, requested, {assertApplied = false, screenIndex, screenFrame} = {}) {
  const result = await command('frame', {frame: requested, name});
  if (assertApplied && (requested[2] < result.minSize.width || requested[3] < result.minSize.height)) {
    skip(name, `requested ${requested[2]}x${requested[3]} is below the native minimum ${result.minSize.width}x${result.minSize.height}; geometry recorded without shape coverage`);
    return result.settled.frame;
  }
  if (assertApplied) {
    check(`${name}: applies requested bounds`, result.settled.frame, {x: requested[0], y: requested[1], width: requested[2], height: requested[3]});
    const center = {x: requested[0] + requested[2] / 2, y: requested[1] + requested[3] / 2};
    if (screenFrame && center.x >= screenFrame.x && center.x < screenFrame.x + screenFrame.width && center.y >= screenFrame.y && center.y < screenFrame.y + screenFrame.height) {
      checks.push({name: `${name}: belongs to target display`, status: result.screenIndex === screenIndex ? 'pass' : 'fail', expectedScreenIndex: screenIndex, actualScreenIndex: result.screenIndex, actualScreenFrame: result.screenFrame});
      save();
    }
  }
  check(`${name}: frame stays where placed`, result.settled.frame, result.immediate.frame);
  return result.settled.frame;
}

function seam(screens) {
  for (const left of screens) for (const right of screens) {
    if (left === right || Math.abs(left.frame.x + left.frame.width - right.frame.x) > 1) continue;
    const bottom = Math.max(left.visible.y, right.visible.y);
    const top = Math.min(left.visible.y + left.visible.height, right.visible.y + right.visible.height);
    if (top - bottom >= 800 && Math.min(left.visible.width, right.visible.width) >= 1200) return {left, right, bottom, top, x: right.frame.x};
  }
  return null;
}

async function drags(name, screens) {
  if (screens.length < 2) return skip(`${name}: display seam drag`, 'single display; no cross-display seam');
  const boundary = seam(screens);
  if (!boundary) return skip(`${name}: display seam drag`, 'no horizontally adjacent displays with 800 points of shared usable height and 1200 points of width');
  for (const direction of ['left', 'right']) {
    const x = direction === 'left' ? boundary.x + 80 : boundary.x - 1180;
    const before = await frame(`${name}: prepare ${direction} drag`, [x, boundary.bottom + 40, 1100, 700]);
    const from = [before.x + before.width / 2, before.y + before.height - 40];
    if (from[1] >= boundary.top - 10 || from[1] <= boundary.bottom + 10 || before.width > 1180) {
      skip(`${name}: ${direction} seam drag`, 'settled window dimensions do not fit the shared usable seam');
      continue;
    }
    const to = [boundary.x + (direction === 'left' ? -10 : 10), from[1]];
    const expected = {...before, x: before.x + to[0] - from[0]};
    const result = await command('drag', {name: `${name}: ${direction} seam drag`, from, to});
    check(`${name}: ${direction} drag keeps pointer offset`, result.immediate.frame, expected);
    check(`${name}: ${direction} drop stays placed`, result.settled.frame, expected);
  }
}

try {
  const compilation = spawnSync('xcrun', ['clang', '-fobjc-arc', '-dynamiclib', '-framework', 'AppKit', '-o', library, join(import.meta.dirname, 'window-placement-probe.m')], {encoding: 'utf8', timeout: remaining(20000)});
  writeFileSync(join(scratch, 'compile.json'), JSON.stringify({status: compilation.status, stdout: compilation.stdout, stderr: compilation.stderr, error: compilation.error?.message}, null, 2));
  assert.equal(compilation.status, 0, `probe compilation failed: ${compilation.stderr || compilation.error}`);
  app = await launch(appPath, {data, keepData: true, metroPort: parsePort(process.env.METRO_PORT ?? '8081'), startTimeout: remaining(20000), ready: {timeout: remaining(20000)}, onboarded: true, session: session({windows: [{id: 'w1', frame: [80, 80, 1100, 700]}], tabs: [{id: 't1', windowId: 'w1', url: 'about:blank'}]}), env: {DYLD_INSERT_LIBRARIES: library, SOLARA_FRAME_PROBE: scratch}});
  const initial = await command('read');
  const original = initial.settled.frame;
  const areas = [['left half', 0, 0, .5, 1], ['right half', .5, 0, .5, 1], ['top half', 0, .5, 1, .5], ['bottom half', 0, 0, 1, .5], ['top left quarter', 0, .5, .5, .5], ['top right quarter', .5, .5, .5, .5], ['bottom left quarter', 0, 0, .5, .5], ['bottom right quarter', .5, 0, .5, .5], ['fill', 0, 0, 1, 1]];
  for (const [index, screen] of initial.screens.entries()) {
    const visible = screen.visible;
    for (const [name, x, y, width, height] of areas) await frame(`screen ${index}: ${name}`, [visible.x + x * visible.width, visible.y + y * visible.height, width * visible.width, height * visible.height], {assertApplied: true, screenIndex: index, screenFrame: screen.frame});
    const restored = await frame(`screen ${index}: restore`, array(original));
    check(`screen ${index}: restore original bounds`, restored, original);
  }
  const zoomBefore = (await command('read')).settled;
  const zoomFirst = await command('zoom', {name: 'performZoom first press'});
  checks.push({name: 'performZoom first press changes zoom state', status: zoomFirst.settled.zoomed !== zoomBefore.zoomed ? 'pass' : 'fail', before: zoomBefore.zoomed, after: zoomFirst.settled.zoomed});
  save();
  const zoomBack = await command('zoom', {name: 'performZoom second press'});
  check('performZoom roundtrip restores bounds', zoomBack.settled.frame, zoomBefore.frame);
  checks.push({name: 'performZoom roundtrip restores zoom state', status: zoomBack.settled.zoomed === zoomBefore.zoomed ? 'pass' : 'fail', before: zoomBefore.zoomed, after: zoomBack.settled.zoomed});
  save();
  await command('fullscreen', {name: 'toggleFullScreen first call'});
  await command('fullscreen', {name: 'toggleFullScreen second call'});
  const axBefore = (await command('read')).settled;
  const axFirst = await command('axZoom', {name: 'zoom-button accessibility first press'});
  assert(axFirst.axButtonPresent, 'zoom button is missing');
  const axBack = await command('axZoom', {name: 'zoom-button accessibility second press'});
  check('accessibility press roundtrip restores bounds', axBack.settled.frame, axBefore.frame);
  checks.push({name: 'accessibility press roundtrip restores zoom state', status: axBack.settled.zoomed === axBefore.zoomed ? 'pass' : 'fail', before: axBefore.zoomed, after: axBack.settled.zoomed});
  if (!axFirst.axAccepted || !axBack.axAccepted) skip('accessibility acceptance', 'public accessibilityPerformPress returned false; state changes and roundtrip recorded without acceptance coverage');
  save();
  await frame('restore after window button actions', array(original));
  await drags('browser', initial.screens);
  await frame('restore browser before Settings', array(original));
  const settingsCommand = await app.eval('return ac.runCommand({command:"openSettings",arg:null,windowId:"w1"})', {timeout: remaining(8000)});
  operations.push({action: 'openSettings', result: settingsCommand ?? null});
  save();
  await sleep(Math.min(1000, remaining(1000)));
  target = 'NSWindow';
  windowNumber = undefined;
  const settings = await command('read', {name: 'Settings window'});
  assert.equal(settings.class, 'NSWindow', 'Settings must exercise the ordinary AppKit window class');
  await drags('Settings', settings.screens);
  const failed = checks.filter(item => item.status === 'fail');
  writeFileSync(join(scratch, 'summary.json'), JSON.stringify({status: failed.length ? 'fail' : 'pass', displays: initial.screens.length, operations: operations.length, checks: checks.length, failed: failed.map(item => item.name), realSpaceTransitionExercised: false}, null, 2));
  assert.equal(failed.length, 0, failed.map(item => item.name).join('; '));
  console.log(`PASS window placement: ${checks.filter(item => item.status === 'pass').length} checks, ${checks.filter(item => item.status === 'skip').length} skipped; evidence ${scratch}; real Space transitions not exercised`);
} catch (error) {
  save();
  writeFileSync(join(scratch, 'failure.json'), JSON.stringify({error: error.stack ?? String(error), appAlive: app?.alive ?? null}, null, 2));
  throw error;
} finally {
  if (app) await app.quit({timeout: 3000});
}
