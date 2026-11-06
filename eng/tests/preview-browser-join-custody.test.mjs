import assert from "node:assert/strict";
import test from "node:test";
import {
  JOIN_CONTEXT_PREFIX,
  assertJoinCookie,
  assertJoinOperationRequest,
  joinContextFromReceipt,
} from "../operations/preview-browser-join-custody.mjs";
import { ProofFailure } from "../operations/preview-browser-onboarding.common.mjs";

const id = "5887881a-bc13-43f7-b120-dc02e3854751";
const path = JOIN_CONTEXT_PREFIX + id;
const context = { contextId: id, kind: "invitation" };
const origin = new URL("https://preview.example.test/");
const secret = "synthetic-join-credential+not-evidence";
const cookie = {
  name: "bunkfy.workspace-join", value: "protected-envelope", path,
  domain: origin.hostname, expires: -1, httpOnly: true, sameSite: "Strict", secure: true,
};
const header = `bunkfy.workspace-join=protected-envelope; path=${path}; secure; samesite=strict; httponly`;
function request(operation, { body = "", headers = {}, url = origin.origin + path + "/" + operation, method = "POST" } = {}) {
  return {
    url: () => url,
    method: () => method,
    headers: () => ({ "x-bunkfy-join-context": id, ...headers }),
    postData: () => body || null,
  };
}

test("receipt binds both source kinds to the exact public context path", () => {
  for (const [kind, sourceKind] of [["invitation", 1], ["enrollment", 2]]) {
    assert.deepEqual(joinContextFromReceipt({ contextId: id, sourceKind }, path, kind, "fixture"), { contextId: id, kind });
  }
});

test("a changed kind, context, route or secret-bearing receipt cannot qualify", () => {
  const receipt = { contextId: id, sourceKind: 1 };
  for (const [body, route, kind] of [
    [{ ...receipt, contextId: "other-context" }, path, "invitation"],
    [{ ...receipt, token: secret }, path, "invitation"],
    [receipt, path, "enrollment"],
    [receipt, path + "/preview", "invitation"],
    [receipt, "/other/" + id, "invitation"],
    [receipt, path, "unknown"],
  ]) assert.throws(() => joinContextFromReceipt(body, route, kind, "fixture"), ProofFailure);
});

test("same-origin context-bound empty preview and join requests qualify", () => {
  for (const operation of ["preview", "join"]) {
    assert.doesNotThrow(() => assertJoinOperationRequest(request(operation), origin, context, operation, secret, "fixture"));
  }
});

test("profile submission may contain profile fields while authority stays out of the body", () => {
  const profile = { displayName: "Synthetic applicant", legalName: null, workEmail: null, workPhone: null, employeeNumber: null, jobTitle: "Front desk", department: "Operations" };
  assert.doesNotThrow(() => assertJoinOperationRequest(request("applications", { body: JSON.stringify(profile) }), origin, context, "applications", secret, "fixture"));
  for (const field of ["token", "sourceId", "sourceKind", "subjectId", "organizationId", "scopeId", "accessProfileId"]) {
    assert.throws(() => assertJoinOperationRequest(request("applications", { body: JSON.stringify({ ...profile, [field]: "untrusted" }) }), origin, context, "applications", secret, "fixture"), ProofFailure);
  }
});

test("old raw token requests, wrong context headers and changed authorities fail proof", () => {
  for (const changed of [
    { body: JSON.stringify({ token: secret }) },
    { body: JSON.stringify({ token: encodeURIComponent(secret) }) },
    { body: "{}" },
    { headers: { "x-bunkfy-join-context": "other-context" } },
    { method: "GET" },
    { url: "https://other.example.test" + path + "/join" },
    { url: origin.origin + path + "/join?unbound=true" },
    { url: origin.origin + "/api/organization-invitations/accept" },
  ]) assert.throws(() => assertJoinOperationRequest(request("join", changed), origin, context, "join", secret, "fixture"), ProofFailure);
});

test("real retained HttpOnly Strict host/session cookies qualify with HTTPS Secure", () => {
  assert.doesNotThrow(() => assertJoinCookie([cookie], [header], origin, context, secret, "fixture"));
  const loopback = new URL("http://127.0.0.1:8080/");
  assert.doesNotThrow(() => assertJoinCookie([{ ...cookie, domain: loopback.hostname, secure: false }], [header.replace("; secure", "")], loopback, context, secret, "fixture"));
});

test("missing, duplicate, readable, widened, persistent or plaintext cookies fail proof", () => {
  for (const cookies of [
    [], [cookie, cookie],
    [{ ...cookie, httpOnly: false }], [{ ...cookie, sameSite: "Lax" }],
    [{ ...cookie, domain: ".example.test" }], [{ ...cookie, path: "/" }],
    [{ ...cookie, secure: false }], [{ ...cookie, expires: 2_000_000_000 }],
    [{ ...cookie, value: secret }], [{ ...cookie, value: "" }],
  ]) assert.throws(() => assertJoinCookie(cookies, [header], origin, context, secret, "fixture"), ProofFailure);
});

test("wire attributes cannot widen custody even if a cookie snapshot appears valid", () => {
  for (const headers of [
    [], [header, header],
    [header + "; Domain=preview.example.test"],
    [header + "; Max-Age=600"],
    [header + "; Expires=Fri, 06 Nov 2026 20:00:00 GMT"],
    [header.replace("; httponly", "")],
    [header.replace("samesite=strict", "samesite=lax")],
    [header.replace("; secure", "")],
  ]) assert.throws(() => assertJoinCookie([cookie], headers, origin, context, secret, "fixture"), ProofFailure);
});
