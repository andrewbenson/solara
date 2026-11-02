import assert from "node:assert/strict";
import test from "node:test";
import { assertNotificationAuthorizationLog, NotificationAuthorizationEvidenceError } from "./notification-authorization-log.mjs";

const appID = "network.benson.solara";
const normal = "network.benson.solara.helper.Alerts";
const alternate = "network.benson.solara.helper.AperitifAlerts";
const os = { version: "fixture-version", build: "fixture-build" };
const sha256 = "a".repeat(64);
const raw = (bundleID, message, requestID = "call-1") => ({ process: "usernoted", timestamp: "2026-11-01T12:00:01Z",
  eventMessage: `${message} bundleID=${bundleID} requestID=${requestID}` });
const capture = (records) => ({ start: "2026-11-01T12:00:00Z", end: "2026-11-01T12:00:10Z",
  complete: true, redacted: false, droppedRecords: 0, predicate: 'process == "usernoted"', records });
const invocation = (bundleID, requestID = "call-1") => [raw(bundleID, "requestAuthorizationWithOptions:", requestID),
  raw(bundleID, "requestAuthorizationWithOptions:", requestID), raw(bundleID, "authorization completed", requestID)];
function fixture() {
  return { schema: 1, os, inventory: { verified: true, complete: true, source: "built-artifact", artifactSHA256: sha256,
    appExecutableSHA256: sha256, appID, helpers: [
      { bundleID: normal, variant: "normal", relativePath: "Helpers/Solara Helper (Alerts).app", executableSHA256: sha256 },
      { bundleID: alternate, variant: "alternate", relativePath: "Helpers/Solara Helper (Aperitif Alerts).app", executableSHA256: sha256 },
    ] }, calibration: [appID, normal, alternate].map((bundleID) => ({ bundleID, os, artifactSHA256: sha256, executableSHA256: sha256,
      expectedCalls: 2, capture: capture([...invocation(bundleID, "call-1"), ...invocation(bundleID, "call-2")]) })), treatment: capture(invocation(appID)) };
}
const inconclusive = (evidence) => assert.throws(() => assertNotificationAuthorizationLog(evidence), (error) =>
  error instanceof NotificationAuthorizationEvidenceError && error.status === "inconclusive" && !Object.hasOwn(error, "alertsRequests"));

test("synthetic calibrated duplicate and multistage records count one call", () => {
  const result = assertNotificationAuthorizationLog(fixture());
  assert.equal(result.status, "measured-pass");
  assert.equal(result.appRequests, 1);
  assert.deepEqual(result.alertsRequests, { [normal]: 0, [alternate]: 0 });
});
test("requestAuthorizationWithOptions helper request is measured failure", () => {
  const evidence = fixture();
  evidence.treatment.records.push(...invocation(normal));
  const result = assertNotificationAuthorizationLog(evidence);
  assert.equal(result.status, "measured-fail");
  assert.equal(result.alertsRequests[normal], 1);
});
test("captured variant spellings are calibrated before treatment counting", () => {
  const evidence = fixture();
  for (const spelling of ["requestAuthorization:", "requesting authorization", "authorization request"]) {
    evidence.calibration.push({ bundleID: appID, os, artifactSHA256: sha256, executableSHA256: sha256, expectedCalls: 1,
      capture: capture([raw(appID, spelling)]) });
    evidence.treatment = capture([raw(appID, spelling)]);
    assert.equal(assertNotificationAuthorizationLog(evidence).status, "measured-pass");
  }
});
test("incomplete, redacted and uncalibrated evidence has no zero-count result", () => {
  inconclusive(fixture().treatment.records);
  for (const mutate of [
    (value) => { value.treatment.complete = false; },
    (value) => { value.treatment.droppedRecords = 1; },
    (value) => { value.treatment.redacted = true; },
    (value) => { value.treatment.records.push(raw("<private>", "requestAuthorizationWithOptions:")); },
    (value) => { value.treatment.records.push(raw("<redacted>", "requestAuthorizationWithOptions:")); },
    (value) => { value.treatment.records.push(raw(normal, "newAuthorizationAttempt")); },
    (value) => { value.treatment.records.push(raw("unknown.helper.Alerts", "requestAuthorizationWithOptions:")); },
    (value) => { value.treatment.records = [raw(appID, "requestAuthorization:")]; },
    (value) => { value.treatment.records[0].eventMessage = `requestAuthorizationWithOptions: bundleID=${appID}`; },
    (value) => { value.treatment.records[0].timestamp = "2026-11-01T13:00:00Z"; },
    (value) => { value.calibration.pop(); },
    (value) => { value.calibration[0].os = { ...os, build: "other" }; },
    (value) => { value.calibration[0].expectedCalls = 1; },
    (value) => { value.calibration[0].capture = capture(invocation(appID)); value.calibration[0].expectedCalls = 1; },
    (value) => { value.calibration[0].capture = capture([...invocation(appID), ...invocation(appID)]); },
    (value) => { value.calibration[0].capture = capture([raw(appID, "requestAuthorizationWithOptions:", "one"), raw(appID, "requestAuthorizationWithOptions:", "two")]); },
    (value) => { value.calibration[0].capture.records = value.calibration[0].capture.records.filter((row) => !row.eventMessage.startsWith("authorization completed")); },
    (value) => { value.inventory.verified = false; },
    (value) => { value.inventory.helpers.pop(); },
  ]) {
    const evidence = fixture();
    mutate(evidence);
    inconclusive(evidence);
  }
});
