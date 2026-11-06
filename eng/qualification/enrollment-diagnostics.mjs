import { createHash } from "node:crypto";
import { readFileSync, realpathSync, writeFileSync } from "node:fs";
import { basename, dirname, resolve } from "node:path";
import { fileURLToPath, pathToFileURL } from "node:url";

const ORIGINAL_SHA256 = "3b6ef435987db8486c618b86667ef215bb9cc67d19dd5d6f694d9d3c42112c73";
const HTTP_STATUSES = [200, 400, 401, 403, 404, 409, 429, 500, 503];
const FAILURE_CODES = new Set([
  "Workspaces.AccessProvisioningFailed",
  "Workspaces.StaffOnboardingMembershipStateConflict",
  "Workspaces.StaffOnboardingProvisioningFailed",
]);

const maybeBoolean = (value) => typeof value === "boolean" ? value : null;
const boundedInteger = (value, maximum) =>
  Number.isSafeInteger(value) && value >= 0 && value <= maximum ? value : null;

// Passive Playwright events only. Never retain URLs, headers, bodies or errors.
export function observeEnrollmentRequests(page, { workspaceId, homeWorkspaceId }) {
  const requests = new WeakMap();
  const buckets = new Map();
  const route = (request) => {
    let path;
    try { path = new URL(request.url()).pathname; } catch { return null; }
    const known = new Map([
      ["/api/organizations", "workspace-catalogue"],
      ["/api/properties", "visible-properties"],
      ["/api/organization-enrollment/preview", "enrollment-preview"],
      [`/api/workspace-staff-enrollment/${workspaceId}/applications/current`, "enrollment-application"],
      ["/api/auth/browser/refresh", "browser-refresh"],
      ["/api/staff/me", "current-staff"],
      ["/api/access/permissions/evaluate", "permission-evaluation"],
    ]);
    return known.get(path) ?? null;
  };
  const increment = (bucket, field) => { bucket[field] = Math.min(10_000, bucket[field] + 1); };
  page.on("request", request => {
    const category = route(request);
    if (!category) return;
    const header = request.headers()["x-tenant-id"];
    const tenant = header === workspaceId ? "target" : header === homeWorkspaceId ? "home"
      : header === "global" ? "global" : header ? "other" : "missing";
    const method = ["GET", "POST"].includes(request.method()) ? request.method() : "other";
    const key = `${category}:${tenant}:${method}`;
    if (!buckets.has(key)) buckets.set(key, { category, tenant, method,
      started: 0, finished: 0, failed: 0, inFlight: 0, lastHttpStatus: null });
    const bucket = buckets.get(key);
    increment(bucket, "started"); increment(bucket, "inFlight");
    requests.set(request, bucket);
  });
  page.on("response", response => {
    const bucket = requests.get(response.request());
    if (bucket) bucket.lastHttpStatus = boundedInteger(response.status(), 599);
  });
  for (const [event, field] of [["requestfinished", "finished"], ["requestfailed", "failed"]]) {
    page.on(event, request => {
      const bucket = requests.get(request);
      if (!bucket) return;
      increment(bucket, field); bucket.inFlight = Math.max(0, bucket.inFlight - 1);
      requests.delete(request);
    });
  }
  return { snapshot: () => [...buckets.values()].map(bucket => ({ ...bucket })) };
}

async function apiObservation(api, path, options, select) {
  try {
    const response = await api(path, { ...options, expectedStatus: HTTP_STATUSES });
    return { collected: true, httpStatus: boundedInteger(response.status, 599), ...select(response.body) };
  } catch {
    return { collected: false, httpStatus: null };
  }
}

async function visible(page, role, name) {
  try { return maybeBoolean(await page.getByRole(role, { name, exact: true }).isVisible()); }
  catch { return null; }
}

export function cleanupFailureObservation(key, error) {
  const keys = new Set(["nonOwnerMemberships", "properties"]);
  const stages = new Set(["cleanup-members", "cleanup-staff-list", "cleanup-staff-profile",
    "cleanup-staff-departure", "cleanup-property-read", "cleanup-property-retire"]);
  const codes = new Set(["Cleanup.StaffProfileMismatch", "Cleanup.DuplicateStaff",
    "Cleanup.InvalidDepartureReceipt", "Cleanup.UnsupportedStaffStatus", "Cleanup.MembershipTimeout",
    "Cleanup.UnsupportedPropertyStatus", "Cleanup.InvalidPropertyRetirement", "Cleanup.RateLimitTimeout",
    ...HTTP_STATUSES.map((status) => `Api.UnexpectedStatus.${status}`)]);
  return { key: keys.has(key) ? key : "other",
    code: codes.has(error?.code) ? error.code : "other",
    stage: stages.has(error?.stage) ? error.stage : "other" };
}

export async function recordEnrollmentDiagnostic({ page, api, workspaceId, sourceId, accessToken, outputPath, phase = "failure", enrollmentRequests = null }) {
  if (!["failure", "converged"].includes(phase)) throw new Error("Unknown diagnostic observation phase.");
  if (basename(outputPath ?? "") !== "enrollment-diagnostic.json") {
    throw new Error("Diagnostic output must use its fixed evidence filename.");
  }
  const snapshot = {
    schemaVersion: 1,
    result: phase === "failure" ? "observed-failure" : "observed-convergence",
    failureStage: phase === "failure" ? "enrollment-browser-convergence" : null,
    scope: "Read-only failure observations; no response bodies, identities, credentials, URLs or browser artifacts.",
    browser: {},
  };
  try {
    const state = await page.evaluate(async () => {
      let heldSessionLocks = null;
      let pendingSessionLocks = null;
      try {
        const locks = await navigator.locks?.query();
        if (locks) {
          heldSessionLocks = locks.held.filter(lock => lock.name === "bunkfy.browser-session.cookies").length;
          pendingSessionLocks = locks.pending.filter(lock => lock.name === "bunkfy.browser-session.cookies").length;
        }
      } catch { /* Browser support is an observation, never acceptance. */ }
      return { visibility: document.visibilityState, focused: document.hasFocus(),
        rootPath: window.location.pathname === "/", joinPath: window.location.pathname === "/join",
        fragmentCleared: window.location.hash === "", online: navigator.onLine,
        heldSessionLocks, pendingSessionLocks };
    });
    snapshot.browser = {
      visibility: ["visible", "hidden", "prerender"].includes(state.visibility) ? state.visibility : "other",
      focused: maybeBoolean(state.focused),
      rootPath: maybeBoolean(state.rootPath),
      joinPath: maybeBoolean(state.joinPath),
      fragmentCleared: maybeBoolean(state.fragmentCleared),
      online: maybeBoolean(state.online),
      heldSessionLocks: boundedInteger(state.heldSessionLocks, 100),
      pendingSessionLocks: boundedInteger(state.pendingSessionLocks, 100),
    };
  } catch { snapshot.browser.collected = false; }
  snapshot.browser.mainNavigationVisible = await visible(page, "navigation", "Main navigation");
  snapshot.browser.requestSentVisible = await visible(page, "heading", "Request sent");
  snapshot.browser.openingWorkspaceVisible = await visible(page, "heading", "Opening workspace");
  snapshot.browser.openWorkspaceButtonVisible = await visible(page, "button", "Open workspace");
  if (enrollmentRequests) snapshot.requests = enrollmentRequests.snapshot();
  snapshot.application = await apiObservation(api,
    `/api/workspace-staff-enrollment/${workspaceId}/applications/current?sourceKind=2&sourceId=${sourceId}`,
    { accessToken, stage: "diagnostic-current-enrollment" },
    (body) => ({
      status: boundedInteger(body?.status, 10),
      hasStaffMember: typeof body?.staffMemberId === "string" && body.staffMemberId.length > 0,
      hasClaim: typeof body?.claimId === "string" && body.claimId.length > 0,
      failureCode: body?.failureCode == null ? null : FAILURE_CODES.has(body.failureCode) ? body.failureCode : "other",
    }));
  snapshot.staff = await apiObservation(api, "/api/staff/me",
    { tenantId: workspaceId, accessToken, stage: "diagnostic-current-staff" },
    (body) => ({ hasStaffMember: typeof body?.staffMemberId === "string" && body.staffMemberId.length > 0 }));
  snapshot.properties = await apiObservation(api, "/api/properties?page=1&pageSize=1",
    { tenantId: workspaceId, accessToken, stage: "diagnostic-visible-properties" },
    (body) => ({ hasProperties: Array.isArray(body?.properties) && body.properties.length > 0 }));
  writeFileSync(outputPath, JSON.stringify(snapshot, null, 2) + "\n", { mode: 0o600, flag: "wx" });
  return snapshot;
}

export function instrumentOnboardingSource(source, operationsDirectory, helperUrl = import.meta.url) {
  const originalSha256 = createHash("sha256").update(source).digest("hex");
  if (originalSha256 !== ORIGINAL_SHA256) {
    throw new Error("Original onboarding operator changed; review diagnostics before executing it.");
  }
  let result = source;
  const replacements = [
    ["\"./preview-browser-onboarding.common.mjs\"", JSON.stringify(pathToFileURL(resolve(operationsDirectory, "preview-browser-onboarding.common.mjs")).href)],
    ["\"./preview-browser-workspace-access-administration.mjs\"", JSON.stringify(pathToFileURL(resolve(operationsDirectory, "preview-browser-workspace-access-administration.mjs")).href)],
    ["\"./preview-browser-join-custody.mjs\"", JSON.stringify(pathToFileURL(resolve(operationsDirectory, "preview-browser-join-custody.mjs")).href)],
    ["const scriptDirectory = dirname(fileURLToPath(import.meta.url));", `const scriptDirectory = ${JSON.stringify(operationsDirectory)};`],
    ["  const enrollmentPage = await enrollmentContext.newPage();", `  const enrollmentPage = await enrollmentContext.newPage();
  const enrollmentRequests = observeEnrollmentRequests(enrollmentPage,
    { workspaceId: targetWorkspaceId, homeWorkspaceId: applicantHomeWorkspaceId });`],
    ["  await waitForDashboard(enrollmentPage, targetWorkspace.name);", `  try {
    await waitForDashboard(enrollmentPage, targetWorkspace.name);
  } catch (error) {
    try {
      await recordEnrollmentDiagnostic({ page: enrollmentPage, api,
        workspaceId: targetWorkspaceId, sourceId: enrollmentSource.sourceId,
        accessToken: enrollmentApplicant.accessToken, enrollmentRequests,
        outputPath: process.env.BUNKFY_ENROLLMENT_DIAGNOSTIC_PATH });
    } catch { /* Diagnostic failure never replaces the original failed acceptance. */ }
    throw error;
  }
  try {
    await recordEnrollmentDiagnostic({ page: enrollmentPage, api,
      workspaceId: targetWorkspaceId, sourceId: enrollmentSource.sourceId,
      accessToken: enrollmentApplicant.accessToken, phase: "converged", enrollmentRequests,
      outputPath: process.env.BUNKFY_ENROLLMENT_DIAGNOSTIC_PATH });
  } catch { /* Read-only observation cannot change the original acceptance. */ }`],
    [`async function attemptCleanup(key, action) {
  try {
    cleanup[key] = await action();
  } catch {
    cleanup[key] = "failed";
    addCleanupFailure(key);
  }
}`, `async function attemptCleanup(key, action) {
  try {
    cleanup[key] = await action();
  } catch (error) {
    if (["nonOwnerMemberships", "properties"].includes(key)) {
      browserChecks.cleanupFailureObservations ??= [];
      browserChecks.cleanupFailureObservations.push(cleanupFailureObservation(key, error));
    }
    cleanup[key] = "failed";
    addCleanupFailure(key);
  }
}`],
  ];
  for (const [before, after] of replacements) {
    if (result.split(before).length !== 2) throw new Error("Expected exactly one reviewed onboarding hook binding.");
    result = result.replace(before, after);
  }
  return {
    source: `import { recordEnrollmentDiagnostic, cleanupFailureObservation, observeEnrollmentRequests } from ${JSON.stringify(helperUrl)};\n` + result,
    originalSha256,
    reviewedDiagnosticBindings: replacements.length,
  };
}

if (process.argv[1] && resolve(process.argv[1]) === fileURLToPath(import.meta.url)) {
  const [operationsArgument, outputArgument] = process.argv.slice(2);
  if (!operationsArgument || !outputArgument || process.argv.length !== 4) {
    throw new Error("Expected only original operations directory and private instrumented output.");
  }
  const operations = realpathSync(operationsArgument);
  const output = resolve(outputArgument);
  if (basename(operations) !== "operations" || basename(dirname(operations)) !== "eng" ||
      realpathSync(dirname(output)) !== realpathSync(resolve(operations, "../../.tmp"))) {
    throw new Error("Onboarding hook must stay in this exact candidate's ignored private workspace.");
  }
  const source = readFileSync(resolve(operations, "rehearse-preview-browser-onboarding.mjs"), "utf8");
  const instrumented = instrumentOnboardingSource(source, operations);
  writeFileSync(output, instrumented.source, { mode: 0o600, flag: "wx" });
  process.stdout.write(JSON.stringify({
    originalSha256: instrumented.originalSha256,
    instrumentedSha256: createHash("sha256").update(instrumented.source).digest("hex"),
    diagnosticHooks: 3,
    enrollmentObservationHooks: 1,
    cleanupObservationHooks: 1,
    requestObservationHooks: 1,
    safeGetProbeHooks: 0,
    canonicalSafeGetProbeCalls: 1,
    reviewedDiagnosticBindings: instrumented.reviewedDiagnosticBindings,
    denial403AssertionPreserved: true,
    rateLimitDoesNotSatisfyAuthorizationProof: true,
    originalAcceptanceAndCleanupPreserved: true,
    trackedCandidateFilesChanged: false,
  }) + "\n");
}
