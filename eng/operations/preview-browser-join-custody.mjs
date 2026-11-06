import { fail } from "./preview-browser-onboarding.common.mjs";

export const JOIN_CONTEXT_PREFIX = "/api/workspace-join/";
const UUID = /^[0-9a-f]{8}-[0-9a-f]{4}-[1-5][0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$/;
const PROFILE_FIELDS = new Set([
  "displayName", "legalName", "workEmail", "workPhone",
  "employeeNumber", "jobTitle", "department",
]);

export function joinContextFromReceipt(receipt, path, kind, stage) {
  const contextId = path.slice(JOIN_CONTEXT_PREFIX.length);
  if (!path.startsWith(JOIN_CONTEXT_PREFIX) || !UUID.test(contextId) ||
      receipt?.contextId !== contextId ||
      receipt?.sourceKind !== (kind === "invitation" ? 1 : kind === "enrollment" ? 2 : null) ||
      Object.keys(receipt).some((key) => key !== "contextId" && key !== "sourceKind")) {
    fail("Browser.InvalidJoinContextReceipt", stage);
  }
  return { contextId, kind };
}

export function assertJoinOperationRequest(request, origin, context, operation, secret, stage) {
  const url = new URL(request.url());
  const body = request.postData() ?? "";
  if (url.origin !== origin.origin || url.search || url.hash ||
      url.pathname !== `${JOIN_CONTEXT_PREFIX}${context.contextId}/${operation}` ||
      request.method() !== "POST" ||
      request.headers()["x-bunkfy-join-context"] !== context.contextId ||
      body.includes(secret) || body.includes(encodeURIComponent(secret))) {
    fail("Browser.InvalidJoinContextRequest", stage);
  }
  if (operation === "applications") {
    let profile;
    try { profile = JSON.parse(body); } catch { /* Refuse below without exposing input. */ }
    if (!profile || typeof profile !== "object" || Array.isArray(profile) ||
        Object.keys(profile).some((key) => !PROFILE_FIELDS.has(key)) ||
        typeof profile.displayName !== "string") {
      fail("Browser.JoinProfileContainsNonProfileInput", stage);
    }
  } else if ((operation !== "join" && operation !== "preview") || body !== "") {
    fail("Browser.JoinCredentialRepeatedInBody", stage);
  }
}

export function assertJoinCookie(cookies, setCookieHeaders, origin, context, secret, stage) {
  const path = JOIN_CONTEXT_PREFIX + context.contextId;
  const matching = cookies.filter((cookie) => cookie.name === "bunkfy.workspace-join" && cookie.path === path);
  const headers = setCookieHeaders.filter((value) => value.startsWith("bunkfy.workspace-join="));
  if (matching.length !== 1 || headers.length !== 1) {
    fail("Browser.JoinCookieMissingOrAmbiguous", stage);
  }
  const cookie = matching[0];
  const attributes = headers[0].split(";").slice(1).map((value) => value.trim().toLowerCase());
  if (!cookie.httpOnly || cookie.sameSite !== "Strict" || cookie.expires !== -1 ||
      cookie.domain !== origin.hostname || !cookie.value || cookie.value.includes(secret) ||
      cookie.value.length > 2048 || (origin.protocol === "https:" && !cookie.secure) ||
      !attributes.includes("httponly") || !attributes.includes("samesite=strict") ||
      !attributes.includes(`path=${path}`) ||
      (origin.protocol === "https:" && !attributes.includes("secure")) ||
      attributes.some((value) => /^(domain|expires|max-age)=/.test(value))) {
    fail("Browser.JoinCookieCustodyInvalid", stage);
  }
}
