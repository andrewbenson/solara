# Bookmark scale benchmark

Build a matching dev-identity Release app with the pinned engine. From the repository root:

```sh
SOLARACORE_FRAMEWORK="$(packages/solaracore/scripts/fetch-engine.sh)" timeout 1500 scripts/agent/build-app --as bm3 --force --config Release
```

Then measure into a new scratch directory:

```sh
timeout 540 scripts/agent/locked perflab --as bm3 -- scripts/agent/locked uitest --as bm3 -- node apps/browser/scripts/bookmarks-scale-bench.mjs --app apps/browser/build-bm3/Build/Products/Release/Solara.app --out <new-scratch-directory>
```

The driver generates its HTML export and every bookmark. It launches hidden, blocks external network resolution, leaves native bookmark ownership enabled, records results in `results.json`, and quits its instances. The output directory must be new. `--sample` records the process, including its main and JS threads, during each measured operation. `--check` fails on the reported latency and stall budgets. `--self-test` checks generated fixture counts without launching an app. Debug validation uses `--debug` and a private Metro server on port 8104.

The import uses the HTML parser and the same placement and durable acceptance path as the import UI. The scale fixture contains 300 direct bar links, a folder of 3,000 links and a folder of 1,700 links. It waits for engine readiness before relaunching for the launch measurement.

Elapsed times begin inside the app. Page observations require native model state and a materialized row; bar observations require native snapshot/layout state. Menu timing includes NSMenu construction. These measurements do not certify that the display painted a frame. In particular, a locked display leaves visible-paint latency pending. Relaunch time includes the driver readiness handshake and is an upper bound. Scrolling waits for a changed native offset and materialized rows before returning to the top. Individual edits are measured through durable acceptance and native state propagation.

Main/JS stalls are CFRunLoop busy iterations captured by the existing `acframes.m` probe. The stall budget is 100 ms, page/menu opening 300 ms, and edit state propagation 50 ms. Compare matching baseline and candidate apps in alternating runs under the timing lock. Record display state and machine load; sampled runs are diagnostic, and unsampled runs provide comparison timings.

## 2026-11-11 measurements

Source main is `27b1cdebe537ba584d76d898b4c87223e16309e6`, including receipt expiry `ff5c18f8`. Main contains benchmark instrumentation only. Rebase adds the earlier scale patch; writer adds the serial background journal writer and asynchronous durable bridge/lifecycle changes. Each condition uses its own matching production Hermes bundle and an ad hoc dev-identity Release app, with the same downloaded engine `574046ecf2af`.

All runs hold `scripts/agent/locked perflab` and `uitest`, launch hidden with fresh generated data, and have bounded timeouts. The planned rotating order was interrupted by external compilation. Clean observations, in actual order: main-1, rebase-1, final-1, rebase-2, final-2, rebase-3. Excluded raw runs are retained separately.

Clean sample counts differ: main n=1, rebase n=3, final n=2. Main variability is unmeasured with one clean observation.

Included run start displays: locked 6/6, asleep 6/6. One-minute load at run boundaries ranged 5.58–13.40. Rows report native state/layout and durable edit completion. Visible paint and launch-to-shown remain unverified.

Milliseconds: median [min–max], number of observations.

| Operation | Main with expiry | Rebased scale patch | Background writer |
| --- | ---: | ---: | ---: |
| import-2500 | 2094.43 [2094.43–2094.43], n=1 | 412.50 [398.18–412.66], n=3 | 435.01 [433.34–436.68], n=2 |
| bar-switch | 420.20 [420.20–420.20], n=1 | 72.23 [70.71–198.12], n=3 | 72.84 [72.06–73.61], n=2 |
| bar-resize | 18.55 [18.55–18.55], n=1 | 8.94 [8.55–9.01], n=3 | 8.25 [8.22–8.29], n=2 |
| overflow-menu | 107.12 [107.12–107.12], n=1 | 7.47 [6.91–7.58], n=3 | 7.08 [6.94–7.22], n=2 |
| page-open | 8126.81 [8126.81–8126.81], n=1 | 183.02 [177.25–322.12], n=3 | 168.34 [163.16–173.52], n=2 |
| page-scroll | 398.64 [398.64–398.64], n=1 | 152.11 [147.78–158.15], n=3 | 154.75 [154.10–155.40], n=2 |
| page-search | 7812.63 [7812.63–7812.63], n=1 | 207.50 [205.84–207.81], n=3 | 198.41 [194.97–201.85], n=2 |
| page-select-all | 1182.01 [1182.01–1182.01], n=1 | 13.21 [13.19–13.69], n=3 | 13.28 [12.88–13.67], n=2 |
| page-delete-many | 8939.81 [8939.81–8939.81], n=1 | 3878.84 [3814.29–4122.74], n=3 | 4175.30 [4108.30–4242.30], n=2 |
| page-drag-one | 5341.81 [5341.81–5341.81], n=1 | 3711.28 [3438.35–4097.81], n=3 | 4895.83 [3602.87–6188.80], n=2 |
| edit-add-5000 | 1992.84 [1992.84–1992.84], n=1 | 2549.38 [2403.82–2638.15], n=3 | 1545.92 [1519.06–1572.79], n=2 |
| edit-rename-5000 | 2408.00 [2408.00–2408.00], n=1 | 2855.03 [2776.73–4147.70], n=3 | 3099.07 [2999.28–3198.87], n=2 |
| edit-move-5000 | 3418.64 [3418.64–3418.64], n=1 | 3378.74 [3217.11–3515.41], n=3 | 3410.28 [3398.02–3422.54], n=2 |

Worst main-thread busy iteration per operation, milliseconds: median [min–max], n. These are run-loop intervals, not painted frames.

| Operation | Main with expiry | Rebased scale patch | Background writer |
| --- | ---: | ---: | ---: |
| edit-add-5000 | 743.32 [743.32–743.32], n=1 | 190.46 [140.02–205.65], n=3 | 116.61 [102.94–130.28], n=2 |
| edit-rename-5000 | 83.52 [83.52–83.52], n=1 | 199.80 [95.35–230.31], n=3 | 60.64 [60.52–60.76], n=2 |
| edit-move-5000 | 472.23 [472.23–472.23], n=1 | 125.53 [107.07–134.22], n=3 | 193.40 [189.72–197.08], n=2 |
| page-drag-one | 2474.24 [2474.24–2474.24], n=1 | 95.05 [94.15–195.33], n=3 | 93.84 [82.52–105.17], n=2 |
| page-delete-many | 4406.13 [4406.13–4406.13], n=1 | 683.94 [106.15–716.84], n=3 | 133.04 [130.25–135.84], n=2 |

The scale changes retain large reductions in import, page opening, search and select-all. Durable edits remain measured in seconds; the 50 ms edit and 100 ms main-stall budgets are not met. The writer retains full checkpoints while moving their I/O to the serial background queue. These timings do not isolate the cost of each checkpoint stage or establish a general edit-latency improvement from the writer.

Every inspected fixture journal retained eight requests, zero expired IDs and zero settled receipts at quit. Clean journal sizes were about 21.19–22.68 MB. This fixture is below the newest-32 retention floor and includes no five-minute idle grace, so it does not exercise receipt pruning. The comparison measures current main with expiry; it cannot isolate expiry’s benefit or attribute differences from the earlier b33 session to expiry.

Excluded timing runs:

| Run | Reason |
| --- | --- |
| main-2 | External edg33 Debug Xcode build started 2026-11-11 22:21:44 PST and overlapped this run; excluded from clean timing summary. |
| final-3 | External edg33 Debug Xcode build started 2026-11-11 22:21:44 PST and overlapped this run; excluded from clean timing summary. |
| main-3 | An unattributed twelve-Swift-frontend wave was observed before the owned Python parent resumed at 22:27:58. Its PIDs/source paths were not retained before it vanished; this run setup had not yet spawned. Conservatively omitted from clean timing; raw observation retained. |
| main-4 | Overlapped external th33/codex/hints Swift-test PID30366 (started 22:55:11, first monitor observation 22:55:13) and concurrent compiler activity documented in bench-process-monitor.jsonl; omitted from clean timing. |
| final-4 | Overlapped external th33/codex/hints Swift-test PID30366 (started 22:55:11, first monitor observation 22:55:13) and concurrent compiler activity documented in bench-process-monitor.jsonl; omitted from clean timing. |
| main-5 | Overlapped external th33/codex/hints Swift-test PID30366 (started 22:55:11, first monitor observation 22:55:13) and concurrent compiler activity documented in bench-process-monitor.jsonl; omitted from clean timing. |

No operation failures occurred in the completed runs. Excluded runs completed but are omitted from the tables because of overlapping compiler work. The raw per-run timings, stalls, load, display state and exclusion evidence remain in the task artifacts.
