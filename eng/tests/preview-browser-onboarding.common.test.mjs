import assert from "node:assert/strict";
import { mkdtemp, readFile, stat } from "node:fs/promises";
import { tmpdir } from "node:os";
import { join } from "node:path";
import test from "node:test";
import {
  ProofFailure,
  fingerprint,
  isVerifiedServiceState,
  newSyntheticIdentity,
  optionalBooleanEnvironment,
  optionalIntegerEnvironment,
  parseMailpitOrigin,
  parsePublicOrigin,
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
