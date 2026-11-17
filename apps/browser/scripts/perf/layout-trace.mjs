#!/usr/bin/env node
import { readFileSync } from "node:fs";
import { resolve } from "node:path";
import { fileURLToPath } from "node:url";

const finite = Number.isFinite;
const median = values => {
  const sorted = values.filter(finite).sort((a, b) => a - b);
  if (!sorted.length) return null;
  const middle = sorted.length >> 1;
  return sorted.length % 2 ? sorted[middle] : (sorted[middle - 1] + sorted[middle]) / 2;
};

export function intervalUnion(intervals) {
  const sorted = intervals.filter(([start, end]) => finite(start) && finite(end) && end >= start).sort((a, b) => a[0] - b[0]);
  let total = 0;
  let previous;
  for (const [start, end] of sorted) {
    if (!previous || start > previous[1]) {
      if (previous) total += previous[1] - previous[0];
      previous = [start, end];
    } else previous[1] = Math.max(previous[1], end);
  }
  return total + (previous ? previous[1] - previous[0] : 0);
}

function spansOf(events) {
  const pending = new Map();
  const spans = [];
  let orphanEnds = 0;
  for (const event of [...events].sort((a, b) => a.at - b.at)) {
    if (!finite(event.at) || typeof event.stage !== "string") throw new Error("malformed layout trace event");
    const key = `${event.stage}:${event.id}`;
    if (event.phase === "begin") {
      if (pending.has(key)) throw new Error(`duplicate layout trace begin: ${key}`);
      pending.set(key, event);
    } else if (event.phase === "end") {
      const begin = pending.get(key);
      if (!begin) { orphanEnds++; continue; }
      pending.delete(key);
      spans.push({ stage: begin.stage, detail: begin.detail, start: begin.at, end: event.at });
    } else if (event.phase !== "event") throw new Error(`unknown layout trace phase: ${event.phase}`);
  }
  return { spans, openSpans: pending.size, orphanEnds };
}

function reactSpans(marks) {
  const events = marks.flatMap(mark => {
    const found = /^(rnLayout|rnMount|rnContent|painting|paintingDrain)(Begin|End)$/.exec(mark.signpost ?? "");
    return found ? [{ stage: found[1], phase: found[2].toLowerCase(), at: mark.at, id: mark.id, detail: mark.tabId || String(mark.window ?? "") }] : [];
  });
  return spansOf(events);
}

export function analyzeSample(sample, { nativeLayout = true } = {}) {
  if (!sample || !["switch", "newtab", "newwindow"].includes(sample.action) || !finite(sample.commandAt)) throw new Error("missing action/command timestamp");
  if (typeof sample.tabId !== "string" || !sample.tabId || typeof sample.windowId !== "string" || !sample.windowId) throw new Error("missing target tab/window correlation");
  if (!Array.isArray(sample.events) || !sample.events.length) throw new Error("missing layout trace events");
  const command = sample.events.find(event => event.stage === "command" && event.phase === "event" && event.at >= sample.commandAt && String(event.detail).includes(`${sample.action}:`));
  if (!command) throw new Error("missing correlated command mark");
  const endpoint = sample.action === "switch" ? sample.shownAt : sample.paintAt;
  const stop = finite(endpoint) ? endpoint : sample.action === "newwindow" ? sample.shownAt : null;
  if (!finite(stop) || stop < sample.commandAt) throw new Error("missing or reversed action endpoint");
  const native = spansOf(sample.events);
  const react = reactSpans(sample.marks ?? []);
  const spans = [...native.spans, ...react.spans];
  const first = events => [...events].sort((a, b) => a.at - b.at)[0]?.at ?? null;
  const expected = { switch: "activate", newtab: "newTab", newwindow: "createWindow" }[sample.action];
  const dispatch = native.spans.find(span => span.stage === "storeDispatch" && span.start >= command.at && span.detail.split(",").includes(expected));
  if (!dispatch) throw new Error(`missing correlated ${expected} dispatch`);
  const committed = first(sample.events.filter(event => event.stage === "storeCommit" && event.phase === "event" && event.at >= dispatch.start && event.at <= dispatch.end));
  if (!finite(committed)) throw new Error("missing store commit inside action dispatch");
  const stageEnd = (stage, matches = () => true) => first(spans.filter(span => span.stage === stage && span.start >= sample.commandAt && span.end <= stop && matches(span)).map(span => ({ at: span.end })));
  const commitRevision = Number(sample.events.find(event => event.stage === "storeCommit" && event.at === committed)?.detail);
  const nativeLayoutEnd = stageEnd("layout", span => span.end >= committed && span.detail.split(" ")[0] === sample.windowId && Number(span.detail.split(" ")[1]) >= commitRevision);
  const rnLayout = stageEnd("rnLayout", span => span.start >= committed);
  const layout = nativeLayout === true ? nativeLayoutEnd : nativeLayout === false && sample.action !== "newwindow" ? rnLayout : null;
  const attach = stageEnd("paneAttach", span => span.detail === sample.tabId);
  const reconcile = stageEnd("reconcile", span => span.end >= committed);
  const initialPainting = stageEnd("painting", span => span.detail === sample.tabId);
  const visibility = (sample.marks ?? []).filter(mark => ["visibleOn", "visibleOff"].includes(mark.signpost) && mark.tabId === sample.tabId && mark.at >= Math.max(sample.commandAt, attach ?? sample.commandAt) && mark.at <= stop).sort((a, b) => a.at - b.at);
  const visibleOn = first(visibility.filter(mark => mark.signpost === "visibleOn"));
  const painting = stageEnd("painting", span => span.detail === sample.tabId && visibility.findLast(mark => mark.at <= span.start)?.signpost === "visibleOn");
  const rnMount = stageEnd("rnMount", span => span.start >= committed);
  const delta = (end, start) => finite(end) && finite(start) ? end - start : null;
  const metrics = {
    "command → store commit": committed - sample.commandAt,
    "command → shell layout/projection end": delta(nativeLayoutEnd, sample.commandAt),
    "command → global RN shadow layout end": delta(rnLayout, sample.commandAt),
    "command → global RN mount end": delta(rnMount, sample.commandAt),
    "command → reconcile end": delta(reconcile, sample.commandAt),
    "command → target attach end": delta(attach, sample.commandAt),
    "command → initial target painting end": delta(initialPainting, sample.commandAt),
    "command → target visibleOn request": delta(visibleOn, sample.commandAt),
    "command → target visible painting end": delta(painting, sample.commandAt),
    "target attach end → target visible painting end": delta(painting, attach),
    "store commit → active layout end": delta(layout, committed),
    "active layout end → reconcile end (signed)": delta(reconcile, layout),
    "active layout end → target attach end (signed)": delta(attach, layout),
    "target attach end → shown/paint": delta(endpoint, attach),
    "command → shown/paint": delta(endpoint, sample.commandAt),
    "command → on screen": sample.action === "newwindow" ? delta(sample.shownAt, sample.commandAt) : null,
  };
  if (sample.action === "newwindow") {
    const targetSpans = native.spans.filter(span => span.detail === sample.windowId && span.start >= sample.commandAt);
    const targetEvents = sample.events.filter(event => event.phase === "event" && event.detail === sample.windowId && event.at >= sample.commandAt);
    const rootEnd = first(targetSpans.filter(span => span.stage === "windowRoot").map(span => ({ at: span.end })));
    const shellEnd = first(targetSpans.filter(span => span.stage === "windowShell").map(span => ({ at: span.end })));
    const awaiting = first(targetEvents.filter(event => event.stage === "windowAwaitReady"));
    const ready = first(targetEvents.filter(event => event.stage === "windowReady" && (!finite(awaiting) || event.at >= awaiting)));
    metrics["command → target windowRoot end"] = delta(rootEnd, sample.commandAt);
    metrics["command → target windowShell end"] = delta(shellEnd, sample.commandAt);
    metrics["command → target windowAwaitReady"] = delta(awaiting, sample.commandAt);
    metrics["command → target windowReady"] = delta(ready, sample.commandAt);
    metrics["target windowAwaitReady → windowReady (wall)"] = delta(ready, awaiting);
  }
  const clipped = span => [Math.max(sample.commandAt, span.start), Math.min(stop, span.end)];
  const overlapping = spans.filter(span => span.end >= sample.commandAt && span.start <= stop);
  for (const stage of new Set(overlapping.map(span => span.stage))) metrics[stage === "firstDraw" ? "delayed firstDraw callback (wall)" : `scoped ${stage.startsWith("rn") ? "global " : ""}${stage} (inclusive union)`] = intervalUnion(overlapping.filter(span => span.stage === stage).map(clipped));
  const work = overlapping.filter(span => span.stage !== "firstDraw");
  metrics["all instrumented scopes (union, excluding delayed draw)"] = intervalUnion(work.map(clipped));
  metrics["outside instrumented scopes"] = stop - sample.commandAt - metrics["all instrumented scopes (union, excluding delayed draw)"];
  return { action: sample.action, commandAt: sample.commandAt, metrics, openSpans: native.openSpans + react.openSpans, orphanEnds: native.orphanEnds + react.orphanEnds, commandMarkOffset: command.at - sample.commandAt };
}

function displayReady(run) {
  return [run.display?.before, run.display?.after].every(state => state && state.locked === false && state.asleep === false);
}

export function analyzeResults(results) {
  const runs = [...(results.session ?? []), ...(results.windows ?? [])];
  if (!runs.length || !runs.some(run => run.layoutTrace?.length)) throw new Error("results contain no layout traces");
  const groups = new Map();
  const layoutOverride = [...(results.meta?.env ?? []), ...(results.meta?.sideEnv ?? [])].filter(entry => entry.startsWith("SOLARA_NATIVE_WINDOW_LAYOUT=")).at(-1);
  const nativeLayout = layoutOverride === "SOLARA_NATIVE_WINDOW_LAYOUT=1" ? true : layoutOverride === "SOLARA_NATIVE_WINDOW_LAYOUT=0" ? false : null;
  const excluded = { displayRuns: 0, throttledSamples: 0 };
  const diagnostics = { openSpans: 0, orphanEnds: 0 };
  for (const run of runs) {
    if (!Array.isArray(run.layoutTrace)) throw new Error("measured run is missing layoutTrace");
    if (!displayReady(run)) { excluded.displayRuns++; continue; }
    const perRun = new Map();
    for (const sample of run.layoutTrace) {
      if (sample.excluded) { excluded.throttledSamples++; continue; }
      const analyzed = analyzeSample(sample, { nativeLayout });
      diagnostics.openSpans += analyzed.openSpans;
      diagnostics.orphanEnds += analyzed.orphanEnds;
      if (!perRun.has(sample.action)) perRun.set(sample.action, []);
      perRun.get(sample.action).push(analyzed);
    }
    for (const [action, samples] of perRun) {
      if (!groups.has(action)) groups.set(action, []);
      groups.get(action).push(samples);
    }
  }
  const rows = [];
  for (const [action, actionRuns] of groups) {
    const names = new Set(actionRuns.flatMap(samples => samples.flatMap(sample => Object.keys(sample.metrics))));
    for (const metric of names) {
      const runMedians = actionRuns.map(samples => median(samples.map(sample => sample.metrics[metric]))).filter(finite);
      rows.push({ action, metric, median: median(runMedians), min: runMedians.length ? Math.min(...runMedians) : null, max: runMedians.length ? Math.max(...runMedians) : null, n: runMedians.length, samples: actionRuns.flat().filter(sample => finite(sample.metrics[metric])).length });
    }
  }
  return { label: results.meta?.label ?? "results", layoutMode: nativeLayout === true ? "native" : nativeLayout === false ? "RN" : "unknown", excluded, diagnostics, rows };
}

export function formatAnalysis(analysis) {
  const lines = [`${analysis.label}: medians of per-run medians; scopes overlap and are not additive. Signed deltas can be negative. Missing stages are unavailable.`, `Excluded: ${analysis.excluded.displayRuns} locked/asleep/unknown-display runs, ${analysis.excluded.throttledSamples} throttled samples.`, `Active layout boundary: ${analysis.layoutMode === "native" ? "native shell layout pass" : analysis.layoutMode === "RN" ? "global RN shadow pass for tab actions only; target new-window boundary unavailable; shell layout/projection is a separate target-window anchor projection" : "unknown; active-layout deltas unavailable"}. RN shadow/mount scopes are global UIManager work, not target-window completion. Visible painting means applyPainting after the target visibleOn request and attach, not a compositor paint.`, `Incomplete callbacks/spans: ${analysis.diagnostics.openSpans} open, ${analysis.diagnostics.orphanEnds} orphan ends. Delayed firstDraw spans are wall waits, excluded from the combined scoped union.`, "", "| Action | Stage | ms | Range | n runs | n samples |", "|---|---|---:|---:|---:|---:|"];
  const f = value => finite(value) ? value.toFixed(2) : "unavailable";
  for (const row of analysis.rows) lines.push(`| ${row.action} | ${row.metric} | ${f(row.median)} | ${row.n ? `${f(row.min)}–${f(row.max)}` : "—"} | ${row.n} | ${row.samples} |`);
  return lines.join("\n");
}

if (process.argv[1] && resolve(process.argv[1]) === fileURLToPath(import.meta.url)) {
  const files = process.argv.slice(2);
  if (!files.length) { console.error("usage: layout-trace.mjs <results.json> [results.json …]"); process.exitCode = 64; }
  else for (const file of files) console.log(formatAnalysis(analyzeResults(JSON.parse(readFileSync(file, "utf8")))) + "\n");
}
