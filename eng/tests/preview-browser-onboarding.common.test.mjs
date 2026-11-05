import assert from "node:assert/strict";
import { mkdtemp, readFile, stat } from "node:fs/promises";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { setImmediate as settle } from "node:timers/promises";
import test from "node:test";
import {
  ProofFailure,
  createApiClient,
  fingerprint,
  isVerifiedServiceState,
  newSyntheticIdentity,
  optionalBooleanEnvironment,
  optionalIntegerEnvironment,
  parseMailpitOrigin,
  parsePublicOrigin,
  resolvePollDelayMilliseconds,
  sanitizedFailure,
  writeEvidence,
} from "../operations/preview-browser-onboarding.common.mjs";

test("Worker readiness accepts Docker health or running state only", () => {
  assert.equal(isVerifiedServiceState("healthy"), true);
  assert.equal(isVerifiedServiceState("running"), true);
  assert.equal(isVerifiedServiceState("starting"), false);
  assert.equal(isVerifiedServiceState("restarting"), false);
  assert.equal(isVerifiedServiceState(null), false);
});

test("public origins require HTTPS outside explicit loopback fixtures", () => {
  assert.equal(parsePublicOrigin("https://preview.example.test/").origin, "https://preview.example.test");
  assert.equal(parsePublicOrigin("http://127.0.0.1:8080/", true).origin, "http://127.0.0.1:8080");
  assert.throws(() => parsePublicOrigin("http://preview.example.test/"), ProofFailure);
  assert.throws(() => parsePublicOrigin("https://user:secret@preview.example.test/"), ProofFailure);
  assert.throws(() => parsePublicOrigin("https://preview.example.test/path"), ProofFailure);
});

test("Mailpit is restricted to one explicit IPv4 loopback port", () => {
  assert.equal(parseMailpitOrigin("http://127.0.0.1:43210/").origin, "http://127.0.0.1:43210");
  assert.throws(() => parseMailpitOrigin("http://localhost:43210/"), ProofFailure);
  assert.throws(() => parseMailpitOrigin("https://127.0.0.1:43210/"), ProofFailure);
  assert.throws(() => parseMailpitOrigin("http://127.0.0.1/"), ProofFailure);
});

test("environment parsing is closed and bounded", () => {
  assert.equal(optionalBooleanEnvironment("FLAG", false, { FLAG: "true" }), true);
  assert.equal(optionalIntegerEnvironment("COUNT", 2, 1, 5, { COUNT: "4" }), 4);
  assert.throws(
    () => optionalBooleanEnvironment("FLAG", false, { FLAG: "yes" }),
    ProofFailure,
  );
  assert.throws(
    () => optionalIntegerEnvironment("COUNT", 2, 1, 5, { COUNT: "6" }),
    ProofFailure,
  );
});

test("convergence polling honors bounded Retry-After responses", () => {
  const now = Date.parse("2026-08-12T02:00:00Z");
  assert.equal(resolvePollDelayMilliseconds(
    { status: 429, headers: { "retry-after": "7" } },
    500,
    30_000,
    now,
  ), 7_000);
  assert.equal(resolvePollDelayMilliseconds(
    { status: 429, headers: { "retry-after": "Wed, 12 Aug 2026 02:00:12 GMT" } },
    500,
    30_000,
    now,
  ), 12_000);
  assert.equal(resolvePollDelayMilliseconds(
    { status: 429, headers: { "retry-after": "120" } },
    500,
    30_000,
    now,
  ), 30_000);
  assert.equal(resolvePollDelayMilliseconds(
    { status: 429, headers: { "retry-after": "invalid" } },
    500,
    30_000,
    now,
  ), 500);
  assert.equal(resolvePollDelayMilliseconds(
    { status: 200, headers: { "retry-after": "7" } },
    500,
    30_000,
    now,
  ), 500);
});

test("synthetic evidence uses fingerprints and sanitized failures", () => {
  const identity = newSyntheticIdentity("owner", "deadbeef");
  assert.equal(identity.fingerprintSha256, fingerprint(identity.email));
  assert.equal(identity.fingerprintSha256.length, 64);
  const secret = "one-time-secret-that-must-not-escape";
  const failure = sanitizedFailure(new Error(secret), "browser-stage");
  assert.deepEqual(failure, {
    code: "BrowserRehearsal.UnexpectedFailure",
    stage: "browser-stage",
  });
  assert.equal(JSON.stringify(failure).includes(secret), false);
  assert.deepEqual(sanitizedFailure({ name: "TimeoutError" }, "owner-sign-in"), {
    code: "Browser.Timeout",
    stage: "owner-sign-in",
  });
});

test("evidence is atomic, private, and refuses accidental replacement", async () => {
  const directory = await mkdtemp(join(tmpdir(), "bunkfy-browser-evidence-"));
  const path = join(directory, "evidence.json");
  await writeEvidence(path, { result: "passed" }, false);
  assert.deepEqual(JSON.parse(await readFile(path, "utf8")), { result: "passed" });
  if (process.platform !== "win32") {
    assert.equal((await stat(path)).mode & 0o777, 0o600);
  }
  await assert.rejects(() => writeEvidence(path, { result: "replaced" }, false), ProofFailure);
  await writeEvidence(path, { result: "replaced" }, true);
  assert.deepEqual(JSON.parse(await readFile(path, "utf8")), { result: "replaced" });
});

function apiFixture(responses, cleanupOptions = {
  cleanupRateLimitTimeoutMilliseconds: 10_000,
  cleanupPollIntervalMilliseconds: 500,
}, requestTimeoutMilliseconds = 1_000) {
  const calls = [];
  let disposed = 0;
  let bodyReads = 0;
  const context = {
    async fetch(url, options) {
      calls.push({ url, options, at: Date.now() });
      const response = responses.shift();
      assert.ok(response, "An unexpected request was issued.");
      if (response instanceof Error) throw response;
      return {
        status: () => response.status,
        headers: () => response.headers ?? {},
        async body() { bodyReads += 1; return Buffer.from(JSON.stringify(response.body ?? {})); },
        async dispose() { disposed += 1; },
      };
    },
  };
  return {
    api: createApiClient(context, new URL("https://preview.example.test/"), requestTimeoutMilliseconds, cleanupOptions),
    calls,
    get disposed() { return disposed; },
    get bodyReads() { return bodyReads; },
  };
}

test("cleanup reads wait for Retry-After and retain the exact request", async (t) => {
  t.mock.timers.enable({ apis: ["Date", "setTimeout"], now: 0 });
  const fixture = apiFixture([
    { status: 429, headers: { "retry-after": "7" } },
    { status: 200, body: { items: [] } },
  ]);
  const pending = fixture.api("/api/organizations/fixture/members", {
    stage: "cleanup-members", tenantId: "fixture", accessToken: "synthetic-token",
  });
  await settle();
  t.mock.timers.tick(6_999);
  await settle();
  assert.equal(fixture.calls.length, 1);
  t.mock.timers.tick(1);
  assert.deepEqual((await pending).body, { items: [] });
  assert.equal(fixture.calls[1].at, 7_000);
  assert.deepEqual(fixture.calls[0].options, fixture.calls[1].options);
  assert.equal(fixture.calls[0].url, fixture.calls[1].url);
  assert.equal(fixture.disposed, 1);
  assert.equal(fixture.bodyReads, 1, "Throttled response bodies must not be retained.");
});

test("cleanup reads honor HTTP-date Retry-After", async (t) => {
  const now = Date.parse("2026-11-04T00:00:00Z");
  t.mock.timers.enable({ apis: ["Date", "setTimeout"], now });
  const fixture = apiFixture([
    { status: 429, headers: { "retry-after": "Wed, 04 Nov 2026 00:00:07 GMT" } },
    { status: 200 },
  ]);
  const pending = fixture.api("/api/properties/fixture", { stage: "cleanup-property-read" });
  await settle();
  t.mock.timers.tick(6_999);
  await settle();
  assert.equal(fixture.calls.length, 1);
  t.mock.timers.tick(1);
  assert.equal((await pending).status, 200);
  assert.equal(fixture.calls[1].at - now, 7_000);
});

test("a retry request cannot outlive the remaining cleanup budget", async (t) => {
  t.mock.timers.enable({ apis: ["Date", "setTimeout"], now: 0 });
  const fixture = apiFixture([
    { status: 429, headers: { "retry-after": "9" } }, { status: 200 },
  ], {
    cleanupRateLimitTimeoutMilliseconds: 10_000, cleanupPollIntervalMilliseconds: 500,
  }, 5_000);
  const pending = fixture.api("/api/properties/fixture", { stage: "cleanup-property-read" });
  await settle();
  t.mock.timers.tick(9_000);
  await pending;
  assert.equal(fixture.calls[0].options.timeout, 5_000);
  assert.equal(fixture.calls[1].options.timeout, 1_000);
});

test("missing or malformed cleanup Retry-After uses the configured polling interval", async (t) => {
  t.mock.timers.enable({ apis: ["Date", "setTimeout"], now: 0 });
  for (const headers of [{}, { "retry-after": "not-a-date" }]) {
    const fixture = apiFixture([{ status: 429, headers }, { status: 200 }]);
    const pending = fixture.api("/api/properties/fixture", { stage: "cleanup-property-read" });
    await settle();
    t.mock.timers.tick(499);
    await settle();
    assert.equal(fixture.calls.length, 1);
    t.mock.timers.tick(1);
    assert.equal((await pending).status, 200);
  }
});

test("the cleanup retry budget is shared between membership and property reads", async (t) => {
  t.mock.timers.enable({ apis: ["Date", "setTimeout"], now: 0 });
  const fixture = apiFixture([
    { status: 429, headers: { "retry-after": "6" } }, { status: 200 },
    { status: 429, headers: { "retry-after": "6" } },
  ]);
  const first = fixture.api("/api/organizations/fixture/members", { stage: "cleanup-members" });
  await settle();
  t.mock.timers.tick(6_000);
  await first;
  await assert.rejects(
    fixture.api("/api/properties/fixture", { stage: "cleanup-property-read" }),
    (error) => error.code === "Cleanup.RateLimitTimeout" && error.stage === "cleanup-property-read",
  );
  assert.equal(fixture.calls.length, 3);
  assert.equal(fixture.disposed, 2);
});

test("Retry-After at the deadline or beyond the numeric range never causes an early retry", async (t) => {
  t.mock.timers.enable({ apis: ["Date", "setTimeout"], now: 0 });
  for (const retryAfter of ["10", "11", "9".repeat(400)]) {
    const fixture = apiFixture([{ status: 429, headers: { "retry-after": retryAfter } }]);
    await assert.rejects(
      fixture.api("/api/properties/fixture", { stage: "cleanup-property-read" }),
      (error) => error.code === "Cleanup.RateLimitTimeout",
    );
    assert.equal(fixture.calls.length, 1);
    assert.equal(fixture.disposed, 1);
  }
});

test("a delayed event loop cannot send another cleanup read after the deadline", async (t) => {
  t.mock.timers.enable({ apis: ["Date", "setTimeout"], now: 0 });
  const fixture = apiFixture([{ status: 429, headers: { "retry-after": "7" } }]);
  const rejected = assert.rejects(
    fixture.api("/api/properties/fixture", { stage: "cleanup-property-read" }),
    (error) => error.code === "Cleanup.RateLimitTimeout",
  );
  await settle();
  t.mock.timers.tick(10_001);
  await rejected;
  assert.equal(fixture.calls.length, 1);
});

test("cleanup mutations and normal product requests are never automatically replayed", async () => {
  for (const options of [
    { method: "POST", stage: "cleanup-staff-departure", data: { operationId: "stable-fixture-id" } },
    { method: "GET", stage: "verify-members" },
  ]) {
    const fixture = apiFixture([{ status: 429 }]);
    await assert.rejects(fixture.api("/api/fixture", options),
      (error) => error.code === "Api.UnexpectedStatus.429");
    assert.equal(fixture.calls.length, 1);
  }
});

test("explicit 429 observers and clients without cleanup retry opt-in retain existing behavior", async () => {
  const observer = apiFixture([{ status: 429, body: { retry: true } }]);
  const response = await observer.api("/api/fixture", {
    stage: "cleanup-members", expectedStatus: [200, 429],
  });
  assert.equal(response.status, 429);
  assert.equal(observer.calls.length, 1);
  assert.equal(observer.disposed, 0);
  const original = apiFixture([{ status: 429 }], {});
  await assert.rejects(original.api("/api/fixture", { stage: "cleanup-members" }),
    (error) => error.code === "Api.UnexpectedStatus.429");
  assert.equal(original.calls.length, 1);
});

test("cleanup authorization, server and transport failures remain terminal", async () => {
  for (const response of [{ status: 403 }, { status: 500 }, new Error("synthetic transport failure")]) {
    const fixture = apiFixture([response]);
    await assert.rejects(fixture.api("/api/fixture", { stage: "cleanup-members" }));
    assert.equal(fixture.calls.length, 1);
  }
});

test("cleanup retry configuration rejects unbounded or invalid budgets", () => {
  for (const options of [
    { cleanupRateLimitTimeoutMilliseconds: -1 },
    { cleanupRateLimitTimeoutMilliseconds: 600_001 },
    { cleanupRateLimitTimeoutMilliseconds: Infinity },
    { cleanupPollIntervalMilliseconds: 0 },
    { cleanupPollIntervalMilliseconds: 5_001 },
  ]) {
    assert.throws(() => apiFixture([], options), (error) =>
      error.code === "Configuration.InvalidCleanupRetryBudget");
  }
});

const cleanupOperationId = "a3974c4b-7180-4e71-9d0b-e74779b6c059";
const admittedLater = (seconds = "7", body = { title: "Http.RateLimitExceeded", status: 429 }) =>
  ({ status: 429, headers: { "retry-after": seconds }, body });
const cleanupWrite = (extra = {}) => ({
  method: "POST", stage: "cleanup-staff-departure", retryRateLimitedCleanupWrite: true,
  tenantId: "synthetic-owned-tenant", accessToken: "synthetic-private-token",
  data: { operationId: cleanupOperationId, expectedVersion: 3, reason: "Synthetic cleanup." }, ...extra,
});

test("explicit cleanup operation waits for definite admission rejection and preserves the exact write", async (t) => {
  t.mock.timers.enable({ apis: ["Date", "setTimeout"], now: 0 });
  const fixture = apiFixture([admittedLater(), { status: 200, body: { status: 3 } }]);
  const pending = fixture.api("/api/staff/members/fixture/depart", cleanupWrite());
  void pending.catch(() => {});
  await settle();
  assert.equal(fixture.calls.length, 1);
  t.mock.timers.tick(6_999); await settle();
  assert.equal(fixture.calls.length, 1);
  t.mock.timers.tick(1); await settle();
  assert.equal((await pending).status, 200);
  assert.equal(fixture.calls.length, 2);
  assert.deepEqual(fixture.calls[0].options, fixture.calls[1].options);
  assert.equal(fixture.calls[1].options.data.operationId, cleanupOperationId);
  assert.equal(fixture.disposed, 1);
});

test("unclassified or mismatched write throttles remain terminal", async () => {
  for (const body of [{}, { title: "Different.Rejection", status: 429 },
    { title: "Http.RateLimitExceeded", status: 503 },
    { title: "Http.RateLimitExceeded", status: "429" }]) {
    const fixture = apiFixture([admittedLater("1", body)]);
    await assert.rejects(fixture.api("/api/staff/members/fixture/depart", cleanupWrite()),
      error => error.code === "Api.UnexpectedStatus.429");
    assert.equal(fixture.calls.length, 1);
  }
});

test("write retry requires explicit cleanup POST intent and a stable nonempty operation UUID", async () => {
  for (const extra of [{ method: "GET" }, { method: "DELETE" }, { stage: "ordinary-product-write" },
    { retryRateLimitedCleanupWrite: "true" }, { data: {} }, { data: { operationId: "unstable" } },
    { data: { operationId: "00000000-0000-0000-0000-000000000000" } }]) {
    const fixture = apiFixture([]);
    await assert.rejects(fixture.api("/api/staff/members/fixture/depart", cleanupWrite(extra)),
      error => error.code === "Configuration.InvalidCleanupWriteRetry");
    assert.equal(fixture.calls.length, 0);
  }
});

test("cleanup reads and opted writes share the original deadline", async (t) => {
  t.mock.timers.enable({ apis: ["Date", "setTimeout"], now: 0 });
  const fixture = apiFixture([{ status: 429, headers: { "retry-after": "6" } },
    { status: 200 }, admittedLater("6")]);
  const first = fixture.api("/api/staff/members", { stage: "cleanup-staff-list" });
  await settle(); t.mock.timers.tick(6_000); await settle(); await first;
  await assert.rejects(fixture.api("/api/staff/members/fixture/depart", cleanupWrite()),
    error => error.code === "Cleanup.RateLimitTimeout");
  assert.equal(fixture.calls.length, 3);
  assert.equal(fixture.disposed, 2);
  assert.equal(fixture.calls[2].options.timeout, 1_000);
});

test("caller mutation while throttled cannot change the private retained operation payload", async (t) => {
  t.mock.timers.enable({ apis: ["Date", "setTimeout"], now: 0 });
  const fixture = apiFixture([admittedLater("1"), { status: 200 }]);
  const input = cleanupWrite();
  const pending = fixture.api("/api/staff/members/fixture/depart", input);
  void pending.catch(() => {}); await settle();
  input.data.operationId = "ba746c90-9949-4d84-8d3c-a31353636698";
  input.data.reason = "Changed caller input.";
  t.mock.timers.tick(1_000); await settle(); await pending;
  assert.equal(fixture.calls[1].options.data.operationId, cleanupOperationId);
  assert.equal(fixture.calls[1].options.data.reason, "Synthetic cleanup.");
});

test("opted cleanup writes never replay authorization, conflict, server or transport failures", async () => {
  for (const response of [{ status: 401 }, { status: 403 }, { status: 409 },
    { status: 500 }, { status: 503 }, new Error("Synthetic transport failure.")]) {
    const fixture = apiFixture([response]);
    await assert.rejects(fixture.api("/api/staff/members/fixture/depart", cleanupWrite()));
    assert.equal(fixture.calls.length, 1);
  }
});

test("explicit status observers and clients without cleanup budget never replay writes", async () => {
  const observer = apiFixture([admittedLater()]);
  const response = await observer.api("/api/staff/members/fixture/depart", cleanupWrite({ expectedStatus: [200, 429] }));
  assert.equal(response.status, 429); assert.equal(observer.calls.length, 1);
  const noBudget = apiFixture([admittedLater()], {});
  await assert.rejects(noBudget.api("/api/staff/members/fixture/depart", cleanupWrite()),
    error => error.code === "Api.UnexpectedStatus.429");
  assert.equal(noBudget.calls.length, 1);
});

test("oversized rejection bodies and delays beyond the cleanup budget cannot trigger another write", async () => {
  const oversized = apiFixture([admittedLater("1", {
    title: "Http.RateLimitExceeded", status: 429, detail: "private".repeat(50_000),
  })]);
  await assert.rejects(oversized.api("/api/staff/members/fixture/depart", cleanupWrite()),
    error => error.code === "Api.ResponseTooLarge");
  assert.equal(oversized.calls.length, 1);
  const tooLate = apiFixture([admittedLater("120")]);
  await assert.rejects(tooLate.api("/api/staff/members/fixture/depart", cleanupWrite()),
    error => error.code === "Cleanup.RateLimitTimeout");
  assert.equal(tooLate.calls.length, 1); assert.equal(tooLate.disposed, 1);
});
