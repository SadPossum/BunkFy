import assert from "node:assert/strict";
import { mkdtempSync, readFileSync, rmSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { test } from "node:test";
import { instrumentOnboardingSource, recordEnrollmentDiagnostic } from "./enrollment-diagnostics.mjs";

const PRIVATE = "SYNTHETIC_PRIVATE_EMAIL_TOKEN_RESPONSE_ERROR";
function page({ unavailable = false } = {}) {
  return {
    async evaluate() {
      if (unavailable) throw new Error(PRIVATE);
      return { visibility: "visible", focused: true, rootPath: false, joinPath: true,
        fragmentCleared: true, token: PRIVATE, body: PRIVATE };
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
        failureCode: PRIVATE, items: [{ email: PRIVATE }], verifiedAccountEmail: PRIVATE,
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
    assert.equal(result.properties.hasItems, true);
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
