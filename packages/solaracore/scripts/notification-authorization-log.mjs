import { readFileSync } from "node:fs";

export class NotificationAuthorizationEvidenceError extends Error {
  constructor(reason) {
    super(`inconclusive notification authorization evidence: ${reason}`);
    this.name = "NotificationAuthorizationEvidenceError";
    this.status = "inconclusive";
  }
}

const requireEvidence = (condition, reason) => {
  if (!condition) throw new NotificationAuthorizationEvidenceError(reason);
};
const identity = (value) => typeof value === "string" && /^[A-Za-z][A-Za-z0-9_-]*(?:\.[A-Za-z0-9_-]+)+$/.test(value);
const digest = (value) => typeof value === "string" && /^[a-f0-9]{64}$/.test(value);
const date = (value) => typeof value === "string" ? Date.parse(value) : NaN;
const formats = [
  ["requestAuthorizationWithOptions", /\brequestAuthorizationWithOptions\s*:/i, "request"],
  ["requestAuthorization", /\brequestAuthorization\s*(?::|\()/i, "request"],
  ["requesting authorization", /\brequesting authori[sz]ation\b/i, "request"],
  ["authorization request", /\bauthori[sz]ation request\b/i, "request"],
  ["authorization completion", /\bauthori[sz]ation (?:result|response|completed)\b/i, "completion"],
];

function classifyCapture(capture, ids, label) {
  requireEvidence(capture && capture.complete === true && capture.droppedRecords === 0 && capture.redacted === false,
    `${label} must attest a complete, lossless, unredacted capture`);
  requireEvidence(capture.predicate === 'process == "usernoted"', `${label} must retain all usernoted records without message filtering`);
  const begin = date(capture.start), end = date(capture.end);
  requireEvidence(Number.isFinite(begin) && Number.isFinite(end) && end > begin && end - begin <= 30 * 60 * 1000,
    `${label} needs an explicit capture window of at most 30 minutes`);
  requireEvidence(Array.isArray(capture.records) && capture.records.length > 0, `${label} has no raw records`);
  const requests = new Map();
  const spellings = new Set();
  for (const row of capture.records) {
    requireEvidence(row && typeof row.eventMessage === "string", `${label} has an incomplete record`);
    const image = row.processImagePath ?? row.process ?? "";
    requireEvidence(/(?:^|\/)usernoted$/.test(image), `${label} contains an unclassified process`);
    const at = date(row.timestamp);
    requireEvidence(Number.isFinite(at) && at >= begin && at <= end, `${label} record falls outside its capture window`);
    const message = row.eventMessage;
    requireEvidence(!/<[^>]*>|\[(?:private|redacted|sensitive|unknown)[^\]]*\]|\*{3,}|•{2,}|…|\b(?:redacted|privacy[- ]masked)\b/i.test(message) && row.redacted !== true,
      `${label} contains redacted evidence`);
    if (!/authori[sz]|notification.*permission|permission.*notification/i.test(message)) continue;
    const matched = formats.filter(([, expression]) => expression.test(message));
    requireEvidence(matched.length === 1, `${label} has an unknown or ambiguous authorization spelling`);
    const [spelling, , stage] = matched[0];
    const attributed = [...new Set([...(row.bundleIdentifier ? [row.bundleIdentifier] : []),
      ...[...message.matchAll(/\bbundle(?:Identifier|ID)\s*[=:]\s*([A-Za-z][A-Za-z0-9_-]*(?:\.[A-Za-z0-9_-]+)+)/gi)].map((match) => match[1])])];
    requireEvidence(attributed.length === 1 && ids.has(attributed[0]), `${label} has unknown, ambiguous or redacted bundle attribution`);
    const bundleID = attributed[0];
    const correlation = row.requestIdentifier ?? /\brequest(?:Identifier|ID)\s*[=:]\s*([A-Za-z0-9_-]+)/i.exec(message)?.[1];
    requireEvidence(typeof correlation === "string" && /^[A-Za-z0-9_-]{1,128}$/.test(correlation),
      `${label} lacks a raw per-call request identifier; line counts cannot establish call counts`);
    const key = `${bundleID}:${correlation}`;
    const entry = requests.get(key) ?? { bundleID, requestID: correlation, request: false, requestRecords: 0, records: 0, stages: new Set(), spellings: new Set() };
    entry.request ||= stage === "request";
    if (stage === "request") entry.requestRecords++;
    entry.records++;
    entry.stages.add(stage);
    entry.spellings.add(spelling);
    requests.set(key, entry);
    spellings.add(spelling);
  }
  requireEvidence([...requests.values()].every((row) => row.request), `${label} has completion records without the initiating request`);
  return { requests, spellings };
}

export function assertNotificationAuthorizationLog(evidence) {
  requireEvidence(evidence?.schema === 1, "supply the calibration/treatment evidence envelope, not a raw log array");
  const os = evidence.os;
  requireEvidence(os && typeof os.version === "string" && os.version.length > 0 && typeof os.build === "string" && os.build.length > 0,
    "target macOS version and build are required");
  const inventory = evidence.inventory;
  requireEvidence(inventory?.verified === true && inventory.complete === true && inventory.source === "built-artifact" && digest(inventory.artifactSHA256) && digest(inventory.appExecutableSHA256),
    "a verified complete built-artifact inventory and artifact SHA-256 are required");
  requireEvidence(inventory.appID === "network.benson.solara" && Array.isArray(inventory.helpers) && inventory.helpers.length > 0,
    "inventory must identify the production app and every built Alerts helper");
  const helpers = inventory.helpers;
  requireEvidence(helpers.every((row) => identity(row.bundleID) && row.bundleID !== inventory.appID && ["normal", "alternate"].includes(row.variant) &&
    typeof row.relativePath === "string" && row.relativePath.endsWith(".app") && !row.relativePath.startsWith("/") && !row.relativePath.split("/").includes("..") && digest(row.executableSHA256)),
    "each exact built helper needs its variant, relative bundle path and executable SHA-256");
  requireEvidence(["normal", "alternate"].every((variant) => helpers.some((row) => row.variant === variant)),
    "normal and alternate built Alerts helper inventories are both required");
  const appID = inventory.appID, alertsIDs = helpers.map((row) => row.bundleID);
  requireEvidence(new Set(alertsIDs).size === alertsIDs.length, "helper inventory has duplicate bundle IDs");
  const ids = new Set([appID, ...alertsIDs]);
  const controls = evidence.calibration;
  requireEvidence(Array.isArray(controls) && controls.length >= ids.size, "positive controls are required for the app and every exact helper ID");
  const calibrated = new Map();
  const distinctCalls = new Set();
  const duplicateRequests = new Set();
  const multistage = new Set();
  for (const control of controls) {
    requireEvidence(ids.has(control.bundleID) && control.os?.version === os.version && control.os?.build === os.build,
      "positive controls must use the target OS/build and exact built identities");
    requireEvidence(control.artifactSHA256 === inventory.artifactSHA256 && control.executableSHA256 ===
      (control.bundleID === appID ? inventory.appExecutableSHA256 : helpers.find((row) => row.bundleID === control.bundleID)?.executableSHA256),
      "positive controls must identify the exact inventoried built executable");
    requireEvidence(Number.isInteger(control.expectedCalls) && control.expectedCalls > 0,
      "positive controls need independently recorded nonzero invocation counts");
    const result = classifyCapture(control.capture, ids, `calibration ${control.bundleID}`);
    requireEvidence(result.requests.size === control.expectedCalls && [...result.requests.values()].every((row) => row.bundleID === control.bundleID),
      "calibration does not reproduce the independently recorded invocation count");
    if (control.expectedCalls >= 2) distinctCalls.add(control.bundleID);
    if ([...result.requests.values()].some((row) => row.requestRecords > 1)) duplicateRequests.add(control.bundleID);
    if ([...result.requests.values()].some((row) => row.stages.size > 1)) multistage.add(control.bundleID);
    const known = calibrated.get(control.bundleID) ?? new Set();
    for (const spelling of result.spellings) known.add(spelling);
    calibrated.set(control.bundleID, known);
  }
  requireEvidence([...ids].every((id) => calibrated.has(id)), "missing exact-identity positive control");
  requireEvidence([...ids].every((id) => distinctCalls.has(id)),
    "every exact identity needs a captured control with at least two independently invoked calls and distinct raw request IDs");
  const treatment = classifyCapture(evidence.treatment, ids, "treatment");
  for (const row of treatment.requests.values()) {
    for (const spelling of row.spellings) requireEvidence(calibrated.get(row.bundleID)?.has(spelling),
      `treatment spelling for ${row.bundleID} lacks a captured positive control`);
    requireEvidence(row.requestRecords <= 1 || duplicateRequests.has(row.bundleID),
      `duplicate request logging for ${row.bundleID} lacks a captured deduplication control`);
    requireEvidence(row.stages.size <= 1 || multistage.has(row.bundleID),
      `multistage logging for ${row.bundleID} lacks a captured correlation control`);
  }
  const count = (id) => [...treatment.requests.values()].filter((row) => row.bundleID === id).length;
  const appRequests = count(appID), alertsRequests = Object.fromEntries(alertsIDs.map((id) => [id, count(id)]));
  return { status: appRequests === 1 && Object.values(alertsRequests).every((value) => value === 0) ? "measured-pass" : "measured-fail",
    os, appID, alertsIDs, artifactSHA256: inventory.artifactSHA256, appRequests, alertsRequests,
    window: { start: evidence.treatment.start, end: evidence.treatment.end }, records: evidence.treatment.records.length,
    calls: [...treatment.requests.values()].map((row) => ({ ...row, stages: [...row.stages], spellings: [...row.spellings] })) };
}

if (process.argv[1] && new URL(import.meta.url).pathname === process.argv[1]) {
  try {
    requireEvidence(process.argv.length === 3, "usage: node notification-authorization-log.mjs evidence-envelope.json");
    const result = assertNotificationAuthorizationLog(JSON.parse(readFileSync(process.argv[2], "utf8")));
    console.log(JSON.stringify(result, null, 2));
    if (result.status !== "measured-pass") process.exitCode = 1;
  } catch (error) {
    console.log(JSON.stringify({ status: "inconclusive", reason: error.message }, null, 2));
    process.exitCode = 2;
  }
}
