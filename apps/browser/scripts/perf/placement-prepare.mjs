#!/usr/bin/env node
import assert from "node:assert/strict";
import { readFileSync } from "node:fs";
import { resolve } from "node:path";
import { fileURLToPath } from "node:url";
import { intervalUnion } from "./layout-trace.mjs";

export function placementPreparation(sample) {
  const pending = new Map();
  const spans = [];
  for (const event of [...sample.events].sort((a, b) => a.at - b.at)) {
    const key = `${event.stage}:${event.id}`;
    if (event.phase === "begin") pending.set(key, event);
    if (event.phase !== "end") continue;
    const begin = pending.get(key);
    if (!begin) continue;
    pending.delete(key);
    spans.push({ stage: begin.stage, detail: begin.detail, start: begin.at, end: event.at });
  }
  const stop = sample.action === "switch" ? sample.shownAt : sample.paintAt;
  const relevant = spans.filter(span => span.start >= sample.commandAt && span.end <= stop);
  const prepares = relevant.filter(span => span.stage === "poolPrepareLayouts");
  const layouts = relevant.filter(span => span.stage === "layout");
  const repeated = layouts.filter(layout => prepares.some(prepare => layout.start >= prepare.start && layout.end <= prepare.end
    && layouts.some(previous => previous !== layout && previous.detail === layout.detail && previous.end <= prepare.start)));
  const reappliedPublishedState = relevant.filter(span => span.stage === "layoutState" && prepares.some(prepare => span.start >= prepare.start && span.end <= prepare.end
    && layouts.some(previous => previous.detail === span.detail && previous.end <= prepare.start)));
  const reconcile = relevant.filter(span => span.stage === "reconcile").sort((a, b) => a.start - b.start)[0];
  return {
    action: sample.action,
    queuedBeforeReconcile: reconcile ? reconcile.start - sample.commandAt : null,
    firstReconcileBody: reconcile ? reconcile.end - reconcile.start : null,
    preparationBody: intervalUnion(prepares.map(span => [span.start, span.end])),
    repeatedLayouts: repeated.map(layout => ({ detail: layout.detail, milliseconds: layout.end - layout.start })),
    repeatedLayoutBody: intervalUnion(repeated.map(span => [span.start, span.end])),
    preparationCount: prepares.length,
    reappliedPublishedState: reappliedPublishedState.map(span => span.detail),
  };
}

export function verifyPlacementPreparation(results) {
  const runs = [...(results.session ?? []), ...(results.windows ?? [])];
  const samples = runs.flatMap(run => run.layoutTrace ?? []).filter(sample => !sample.excluded && sample.action === "switch");
  assert.ok(samples.length, "no switch samples to verify");
  for (const [index, sample] of samples.entries()) {
    const summary = placementPreparation(sample);
    assert.ok(summary.preparationCount, `switch ${index}: missing preparation trace`);
    assert.equal(summary.repeatedLayouts.length, 0, `switch ${index}: preparation laid out an already-published revision again: ${JSON.stringify(summary.repeatedLayouts)}`);
  }
  return samples.length;
}

export function verifyNoPublishedStateReapplication(results) {
  const samples = [...(results.session ?? []), ...(results.windows ?? [])].flatMap(run => run.layoutTrace ?? [])
    .filter(sample => !sample.excluded && sample.action === "switch");
  assert.ok(samples.length, "no switch samples to verify");
  for (const [index, sample] of samples.entries()) {
    const summary = placementPreparation(sample);
    assert.ok(summary.preparationCount, `switch ${index}: missing preparation trace`);
    assert.equal(summary.reappliedPublishedState.length, 0, `switch ${index}: preparation reapplied a published revision: ${JSON.stringify(summary.reappliedPublishedState)}`);
  }
  return samples.length;
}

if (process.argv[1] && resolve(process.argv[1]) === fileURLToPath(import.meta.url)) {
  const files = process.argv.slice(2);
  const verify = files[0] === "--verify" || files[0] === "--verify-reapplication" ? files.shift() : null;
  assert.ok(files.length, "usage: placement-prepare.mjs [--verify|--verify-reapplication] <results.json> …");
  for (const file of files) {
    const results = JSON.parse(readFileSync(file, "utf8"));
    if (verify === "--verify") console.log(`PASS ${file}: ${verifyPlacementPreparation(results)} switches reuse published placement`);
    else if (verify === "--verify-reapplication") console.log(`PASS ${file}: ${verifyNoPublishedStateReapplication(results)} switches avoid reapplying published state`);
    else for (const run of [...(results.session ?? []), ...(results.windows ?? [])]) {
      for (const sample of run.layoutTrace ?? []) {
        if (!sample.excluded) console.log(JSON.stringify({ file, ...placementPreparation(sample) }));
      }
    }
  }
}
