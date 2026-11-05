import assert from "node:assert/strict";
import { mkdtempSync, readFileSync, rmSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { test } from "node:test";
import { EventEmitter } from "node:events";
import { fileURLToPath } from "node:url";
import { instrumentOnboardingSource, recordEnrollmentDiagnostic, cleanupFailureObservation, observeEnrollmentRequests } from "./enrollment-diagnostics.mjs";

const PRIVATE = "SYNTHETIC_PRIVATE_EMAIL_TOKEN_RESPONSE_ERROR";

test("the exact current cookie operator instruments without losing its three helper bindings", () => {
  const operations = fileURLToPath(new URL("../operations/", import.meta.url));
  const source = readFileSync(new URL("../operations/rehearse-preview-browser-onboarding.mjs", import.meta.url), "utf8");
  const result = instrumentOnboardingSource(source, operations);
  assert.match(result.originalSha256, /^[0-9a-f]{64}$/);
  for (const name of ["preview-browser-onboarding.common.mjs", "preview-browser-workspace-access-administration.mjs", "preview-browser-join-custody.mjs"]) {
    assert.ok(result.source.includes(new URL("../operations/" + name, import.meta.url).href));
    assert.equal(result.source.includes(`"./${name}"`), false);
  }
  assert.ok(result.source.includes("protected-cookie-no-web-storage-credential"));
  assert.ok(result.source.includes("invitation-cookie-survives-anonymous-reload"));
  assert.ok(result.source.includes("enrollment-cookie-and-subject-marker-survive-pending-reload"));
});
function page({ unavailable = false } = {}) {
  return {
    async evaluate() {
      if (unavailable) throw new Error(PRIVATE);
      return { visibility: "visible", focused: true, rootPath: false, joinPath: true,
        fragmentCleared: true, online: true, heldSessionLocks: 1, pendingSessionLocks: 2, token: PRIVATE, body: PRIVATE };
    },
    getByRole() { return { async isVisible() {
      if (unavailable) throw new Error(PRIVATE);
      return false;
    } }; },
  };
}

test("failure probe makes three reads and exports only fixed statuses and booleans", async () => {
  const directory = mkdtempSync(join(tmpdir(), "bunkfy-enrollment-diagnostic-test-"));
  try {
    const calls = [];
    const api = async (path, options) => {
      calls.push({ path, options });
      return { status: 200, body: { status: 5, staffMemberId: PRIVATE, claimId: PRIVATE,
        failureCode: PRIVATE, properties: [{ email: PRIVATE }], verifiedAccountEmail: PRIVATE,
        password: PRIVATE, accessToken: PRIVATE } };
    };
    const outputPath = join(directory, "enrollment-diagnostic.json");
    const result = await recordEnrollmentDiagnostic({ page: page(), api,
      workspaceId: PRIVATE, sourceId: PRIVATE, accessToken: PRIVATE, outputPath });
    assert.equal(calls.length, 3);
    assert.ok(calls.every(({ options }) => options.method === undefined));
    assert.equal(result.application.status, 5);
    assert.equal(result.application.failureCode, "other");
    assert.equal(result.application.hasStaffMember, true);
    assert.equal(result.properties.hasProperties, true);
    assert.equal(result.browser.online, true);
    assert.equal(result.browser.heldSessionLocks, 1);
    assert.equal(result.browser.pendingSessionLocks, 2);
    assert.equal(readFileSync(outputPath, "utf8").includes(PRIVATE), false);
    await assert.rejects(recordEnrollmentDiagnostic({ page: page(), api,
      workspaceId: PRIVATE, sourceId: PRIVATE, accessToken: PRIVATE, outputPath }), /EEXIST/);
  } finally { rmSync(directory, { recursive: true }); }
});

test("unavailable UI and API never export private exceptions", async () => {
  const directory = mkdtempSync(join(tmpdir(), "bunkfy-enrollment-diagnostic-test-"));
  try {
    const outputPath = join(directory, "enrollment-diagnostic.json");
    const result = await recordEnrollmentDiagnostic({ page: page({ unavailable: true }),
      api: async () => { throw new Error(PRIVATE); }, workspaceId: PRIVATE,
      sourceId: PRIVATE, accessToken: PRIVATE, outputPath });
    assert.equal(result.application.collected, false);
    assert.equal(result.staff.collected, false);
    assert.equal(result.properties.collected, false);
    assert.equal(result.browser.collected, false);
    assert.equal(readFileSync(outputPath, "utf8").includes(PRIVATE), false);
  } finally { rmSync(directory, { recursive: true }); }
});

test("unreviewed source and arbitrary evidence filenames are rejected", async () => {
  assert.throws(() => instrumentOnboardingSource("changed source", "/unreviewed"), /changed/);
  await assert.rejects(recordEnrollmentDiagnostic({ outputPath: "/tmp/arbitrary.json" }), /fixed evidence/);
});

test("bounded cleanup rate-limit failure keeps only its reviewed code and stage", () => {
  const observed = cleanupFailureObservation("properties", {
    code: "Cleanup.RateLimitTimeout", stage: "cleanup-property-read",
    message: PRIVATE, headers: PRIVATE, body: PRIVATE,
  });
  assert.deepEqual(observed, { key: "properties", code: "Cleanup.RateLimitTimeout", stage: "cleanup-property-read" });
  assert.equal(JSON.stringify(observed).includes(PRIVATE), false);
});

test("cleanup observations retain only known keys, API statuses and stages", () => {
  assert.deepEqual(cleanupFailureObservation("properties", {
    code: "Api.UnexpectedStatus.409", stage: "cleanup-property-retire", message: PRIVATE,
  }), { key: "properties", code: "Api.UnexpectedStatus.409", stage: "cleanup-property-retire" });
  const unknown = cleanupFailureObservation(PRIVATE, { code: PRIVATE, stage: PRIVATE, message: PRIVATE });
  assert.equal(JSON.stringify(unknown).includes(PRIVATE), false);
  assert.deepEqual(unknown, { key: "other", code: "other", stage: "other" });
});

test("successful convergence observations keep the same private-field exclusion", async () => {
  const directory = mkdtempSync(join(tmpdir(), "bunkfy-enrollment-diagnostic-test-"));
  try {
    const outputPath = join(directory, "enrollment-diagnostic.json");
    const result = await recordEnrollmentDiagnostic({ page: page(),
      api: async () => ({ status: 200, body: { status: 5, token: PRIVATE } }),
      workspaceId: PRIVATE, sourceId: PRIVATE, accessToken: PRIVATE, outputPath, phase: "converged" });
    assert.equal(result.result, "observed-convergence");
    assert.equal(result.failureStage, null);
    assert.equal(readFileSync(outputPath, "utf8").includes(PRIVATE), false);
  } finally { rmSync(directory, { recursive: true }); }
});

test("actual workflow retains both minimized diagnostics through its explicit file list", () => {
  const workflow = readFileSync(new URL("../../.github/workflows/validate.yml", import.meta.url), "utf8");
  for (const path of ["evidence/onboarding.json", "evidence/onboarding-instrumentation.json", "evidence/enrollment-diagnostic.json"]) {
    assert.ok(workflow.includes(path), `Missing explicit artifact: ${path}`);
  }
  assert.equal(workflow.includes("evidence/*.json"), false);
});

test("passive request observations bound counters and discard URL/header/body/error secrets", () => {
  const events = new EventEmitter();
  const observer = observeEnrollmentRequests(events, { workspaceId: "target", homeWorkspaceId: "home" });
  const request = { url: () => `https://${PRIVATE}.invalid/api/properties?secret=${PRIVATE}`,
    headers: () => ({ "x-tenant-id": "target", authorization: PRIVATE }), method: () => "GET" };
  events.emit("request", request);
  events.emit("response", { request: () => request, status: () => 429, body: () => PRIVATE });
  assert.deepEqual(observer.snapshot(), [{ category: "visible-properties", tenant: "target", method: "GET",
    started: 1, finished: 0, failed: 0, inFlight: 1, lastHttpStatus: 429 }]);
  events.emit("requestfailed", request);
  const unknown = { ...request, url: () => `https://example.invalid/${PRIVATE}` };
  events.emit("request", unknown);
  const privateScope = { ...request, headers: () => ({ "x-tenant-id": PRIVATE }), method: () => PRIVATE };
  events.emit("request", privateScope); events.emit("requestfinished", privateScope);
  for (let index = 0; index < 10_005; index++) {
    events.emit("request", request); events.emit("requestfinished", request);
  }
  const snapshot = observer.snapshot();
  assert.equal(snapshot[0].started, 10_000);
  assert.equal(snapshot[0].failed, 1);
  assert.equal(snapshot[0].inFlight, 0);
  assert.equal(snapshot[1].tenant, "other");
  assert.equal(snapshot[1].method, "other");
  assert.equal(JSON.stringify(snapshot).includes(PRIVATE), false);
});

test("property observation uses the actual properties collection rather than a generic items field", async () => {
  const directory = mkdtempSync(join(tmpdir(), "bunkfy-enrollment-diagnostic-test-"));
  try {
    const result = await recordEnrollmentDiagnostic({ page: page(),
      api: async () => ({ status: 200, body: { items: [{ token: PRIVATE }], properties: [] } }),
      workspaceId: PRIVATE, sourceId: PRIVATE, accessToken: PRIVATE,
      outputPath: join(directory, "enrollment-diagnostic.json") });
    assert.equal(result.properties.hasProperties, false);
    assert.equal(JSON.stringify(result).includes(PRIVATE), false);
  } finally { rmSync(directory, { recursive: true }); }
});
