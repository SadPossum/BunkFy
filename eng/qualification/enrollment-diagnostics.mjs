import { createHash } from "node:crypto";
import { readFileSync, realpathSync, writeFileSync } from "node:fs";
import { basename, dirname, resolve } from "node:path";
import { fileURLToPath, pathToFileURL } from "node:url";

const ORIGINAL_SHA256 = "43fa172e0838f891c0762ef06389e0b4bfd625ecbbb168321391de213a99fe46";
const HTTP_STATUSES = [200, 400, 401, 403, 404, 409, 429, 500, 503];
const FAILURE_CODES = new Set([
  "Workspaces.AccessProvisioningFailed",
  "Workspaces.StaffOnboardingMembershipStateConflict",
  "Workspaces.StaffOnboardingProvisioningFailed",
]);

const maybeBoolean = (value) => typeof value === "boolean" ? value : null;
const boundedInteger = (value, maximum) =>
  Number.isSafeInteger(value) && value >= 0 && value <= maximum ? value : null;

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

export async function recordEnrollmentDiagnostic({ page, api, workspaceId, sourceId, accessToken, outputPath }) {
  if (basename(outputPath ?? "") !== "enrollment-diagnostic.json") {
    throw new Error("Diagnostic output must use its fixed evidence filename.");
  }
  const snapshot = {
    schemaVersion: 1,
    result: "observed-failure",
    failureStage: "enrollment-browser-convergence",
    scope: "Read-only failure observations; no response bodies, identities, credentials, URLs or browser artifacts.",
    browser: {},
  };
  try {
    const state = await page.evaluate(() => ({
      visibility: document.visibilityState,
      focused: document.hasFocus(),
      rootPath: window.location.pathname === "/",
      joinPath: window.location.pathname === "/join",
      fragmentCleared: window.location.hash === "",
    }));
    snapshot.browser = {
      visibility: ["visible", "hidden", "prerender"].includes(state.visibility) ? state.visibility : "other",
      focused: maybeBoolean(state.focused),
      rootPath: maybeBoolean(state.rootPath),
      joinPath: maybeBoolean(state.joinPath),
      fragmentCleared: maybeBoolean(state.fragmentCleared),
    };
  } catch { snapshot.browser.collected = false; }
  snapshot.browser.mainNavigationVisible = await visible(page, "navigation", "Main navigation");
  snapshot.browser.requestSentVisible = await visible(page, "heading", "Request sent");
  snapshot.browser.openingWorkspaceVisible = await visible(page, "heading", "Opening workspace");
  snapshot.browser.openWorkspaceButtonVisible = await visible(page, "button", "Open workspace");
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
    (body) => ({ hasItems: Array.isArray(body?.items) && body.items.length > 0 }));
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
    ["const scriptDirectory = dirname(fileURLToPath(import.meta.url));", `const scriptDirectory = ${JSON.stringify(operationsDirectory)};`],
    ["  await waitForDashboard(enrollmentPage, targetWorkspace.name);", `  try {
    await waitForDashboard(enrollmentPage, targetWorkspace.name);
  } catch (error) {
    try {
      await recordEnrollmentDiagnostic({ page: enrollmentPage, api,
        workspaceId: targetWorkspaceId, sourceId: enrollmentSource.sourceId,
        accessToken: enrollmentApplicant.accessToken,
        outputPath: process.env.BUNKFY_ENROLLMENT_DIAGNOSTIC_PATH });
    } catch { /* Diagnostic failure never replaces the original failed acceptance. */ }
    throw error;
  }`],
  ];
  for (const [before, after] of replacements) {
    if (result.split(before).length !== 2) throw new Error("Expected exactly one reviewed onboarding hook binding.");
    result = result.replace(before, after);
  }
  return {
    source: `import { recordEnrollmentDiagnostic } from ${JSON.stringify(helperUrl)};\n` + result,
    originalSha256,
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
    diagnosticHooks: 1,
    originalAcceptanceAndCleanupPreserved: true,
    trackedCandidateFilesChanged: false,
  }) + "\n");
}
