import { createRequire } from "node:module";
import { dirname, resolve } from "node:path";
import { fileURLToPath } from "node:url";
import {
  assertPreviewCompose,
  assertRegularFile,
  assertReleaseIdentity,
  createApiClient,
  fail,
  fingerprint,
  newSyntheticIdentity,
  optionalBooleanEnvironment,
  optionalIntegerEnvironment,
  parseMailpitOrigin,
  parsePublicOrigin,
  parseReleaseId,
  pollUntil,
  readBoundedJson,
  requireEnvironment,
  sanitizedFailure,
  startPreviewWorker,
  stopPreviewWorker,
  waitForVerificationCode,
  writeEvidence,
} from "./preview-browser-onboarding.common.mjs";
import {
  ensureWorkspaceAccessProfileArchived,
  runPreviewWorkspaceAccessAdministration,
} from "./preview-browser-workspace-access-administration.mjs";

const scriptDirectory = dirname(fileURLToPath(import.meta.url));
const repositoryRoot = resolve(scriptDirectory, "../..");
const webPackagePath = resolve(repositoryRoot, "apps/web/package.json");
const webRequire = createRequire(webPackagePath);
const { chromium, request } = webRequire("@playwright/test");
const RETRYABLE_JOIN_SOURCE_CODES = new Set([
  "Workspaces.StaffAccessProfileUnavailable",
  "Workspaces.StaffAccessPropertyUnavailable",
]);

const configuration = await readConfiguration();
const checks = [];
const cleanupFailures = [];
const cleanup = {
  worker: configuration.exerciseWorkerRestart ? "not-stopped" : "not-requested",
  nonOwnerMemberships: "not-created",
  properties: "not-created",
  targetWorkspace: "not-created",
  applicantHomeWorkspace: "not-created",
  ownerSessions: "not-created",
  invitationApplicantSessions: "not-created",
  enrollmentApplicantSessions: "not-created",
  browserContexts: "not-opened",
  capturedMail: "managed-by-parent",
  globalIdentities: "not-created",
  customProfile: configuration.includeCustomProfileAdministration
    ? "not-created"
    : "not-requested",
};
const identifiers = {
  targetWorkspaceId: null,
  applicantHomeWorkspaceId: null,
  propertyIds: [],
  invitationSourceId: null,
  invitationApplicationId: null,
  invitationMembershipId: null,
  invitationStaffMemberId: null,
  enrollmentSourceId: null,
  enrollmentApplicationId: null,
  enrollmentClaimId: null,
  enrollmentMembershipId: null,
  enrollmentStaffMemberId: null,
  customProfileId: null,
};
const browserChecks = {
  automaticArtifacts: "disabled",
  browserName: "chromium",
  browserVersion: null,
  viewport: "1440x960",
};
const identityEvidence = [];
let proofStage = "configuration";
let proofError = null;
let failedStage = null;
let browser = null;
let apiContext = null;
let mailpitContext = null;
let api = null;
let ownerContext = null;
let invitationContext = null;
let enrollmentContext = null;
let owner = null;
let invitationApplicant = null;
let enrollmentApplicant = null;
let targetWorkspaceId = null;
let applicantHomeWorkspaceId = null;
let allowedPropertyId = null;
let deniedPropertyId = null;
let workerStopped = false;
let observedReleaseId = null;
let registrationAdapters = [];
let workspaceAccessAdministrationResult = configuration.includeCustomProfileAdministration
  ? "not-completed"
  : "not-requested";

try {
  proofStage = "runtime-start";
  apiContext = await request.newContext({
    extraHTTPHeaders: { "User-Agent": "BunkFy-Preview-Browser-Onboarding/1" },
  });
  mailpitContext = await request.newContext({
    extraHTTPHeaders: { "User-Agent": "BunkFy-Preview-Browser-Mail-Capture/1" },
  });
  api = createApiClient(
    apiContext,
    configuration.publicOrigin,
    configuration.requestTimeoutMilliseconds,
  );
  observedReleaseId = await assertReleaseIdentity(
    api,
    configuration.expectedReleaseId,
    "release-preflight",
  );
  addCheck("exact-release-preflight");

  const providers = await api("/api/auth/external/providers", {
    stage: "registration-adapter-preflight",
  });
  const providerCodes = Array.isArray(providers.body?.providers)
    ? providers.body.providers
    : [];
  if (providerCodes.length > 0) {
    fail("RegistrationAdapter.EnabledButUnverified", "registration-adapter-preflight");
  }
  const selfRegistration = await api("/api/auth/self-registration", {
    stage: "password-registration-preflight",
  });
  if (selfRegistration.body?.passwordEnabled !== true) {
    fail("RegistrationAdapter.PasswordDisabled", "password-registration-preflight");
  }
  registrationAdapters = [
    { adapter: "password", result: "passed-captured-preview-delivery" },
    { adapter: "external", result: "disabled" },
  ];
  addCheck("registration-adapter-contract-closed");

  browser = await chromium.launch({ headless: configuration.headless });
  browserChecks.browserVersion = browser.version();
  addCheck("chromium-runtime-started");

  const batchId = crypto.randomUUID().replaceAll("-", "").slice(0, 8);
  owner = newSyntheticIdentity("owner", batchId);
  invitationApplicant = newSyntheticIdentity("invite", batchId);
  enrollmentApplicant = newSyntheticIdentity("enroll", batchId);
  cleanup.globalIdentities = "retained-signed-out-after-proof";

  proofStage = "fixture-identities";
  await registerAndVerifyIdentity(owner);
  cleanup.ownerSessions = "active";
  await registerAndVerifyIdentity(enrollmentApplicant);
  cleanup.enrollmentApplicantSessions = "active";
  addCheck("api-fixture-identities-verified");

  proofStage = "fixture-workspaces";
  const targetWorkspace = await createWorkspace(
    owner,
    `BunkFy browser target ${batchId}`,
    `bunkfy-browser-target-${batchId}`,
  );
  targetWorkspaceId = targetWorkspace.workspaceId;
  identifiers.targetWorkspaceId = targetWorkspaceId;
  cleanup.targetWorkspace = "active";
  cleanup.nonOwnerMemberships = "pending";

  const homeWorkspace = await createWorkspace(
    enrollmentApplicant,
    `BunkFy browser applicant home ${batchId}`,
    `bunkfy-browser-home-${batchId}`,
  );
  applicantHomeWorkspaceId = homeWorkspace.workspaceId;
  identifiers.applicantHomeWorkspaceId = applicantHomeWorkspaceId;
  cleanup.applicantHomeWorkspace = "active";
  addCheck("target-and-existing-applicant-workspaces-created");

  proofStage = "fixture-properties";
  const allowedPropertyName = `Preview browser A ${batchId}`;
  const deniedPropertyName = `Preview browser B ${batchId}`;
  allowedPropertyId = await createProperty(
    owner,
    targetWorkspaceId,
    allowedPropertyName,
    `browser-a-${batchId}`,
  );
  deniedPropertyId = await createProperty(
    owner,
    targetWorkspaceId,
    deniedPropertyName,
    `browser-b-${batchId}`,
  );
  targetWorkspace.allowedPropertyName = allowedPropertyName;
  identifiers.propertyIds = [allowedPropertyId, deniedPropertyId];
  cleanup.properties = "active-2";
  addCheck("two-active-properties-created");

  proofStage = "owner-browser-context";
  ownerContext = await newBrowserContext();
  cleanup.browserContexts = "open";
  const ownerPage = await ownerContext.newPage();
  proofStage = "owner-browser-sign-in";
  await signIn(ownerPage, owner);
  proofStage = "owner-browser-workspace-invites";
  await openWorkspaceInvites(ownerPage, targetWorkspace.name, "owner-invitation");
  addCheck("owner-browser-session-opened");

  proofStage = "invitation-source-browser";
  const invitationSource = await issueInvitationInBrowser(
    ownerPage,
    invitationApplicant.email,
    targetWorkspace.allowedPropertyName,
  );
  identifiers.invitationSourceId = invitationSource.sourceId;
  addCheck("recipient-invitation-and-qr-rendered");

  proofStage = "invitation-browser-journey";
  invitationContext = await newBrowserContext();
  const invitationPage = await invitationContext.newPage();
  const invitationOutcome = await completeInvitationBrowserJourney(
    invitationPage,
    invitationSource,
    invitationApplicant,
    targetWorkspace,
  );
  identifiers.invitationApplicationId = invitationOutcome.applicationId;
  identifiers.invitationMembershipId = invitationOutcome.membershipId;
  identifiers.invitationStaffMemberId = invitationOutcome.staffMemberId;
  cleanup.invitationApplicantSessions = "active";
  addCheck("recipient-browser-registration-and-continuation");
  addCheck("recipient-invitation-least-privilege-access");

  proofStage = "invitation-terminal-replay";
  await replayInvitationInBrowser(
    invitationPage,
    invitationSource,
    invitationApplicant,
    invitationOutcome,
  );
  addCheck("recipient-invitation-terminal-replay-stable");

  if (configuration.includeCustomProfileAdministration) {
    proofStage = "workspace-access-administration";
    const administration = await runPreviewWorkspaceAccessAdministration({
      ownerPage,
      memberPage: invitationPage,
      api,
      ownerAccessToken: owner.accessToken,
      memberAccessToken: invitationApplicant.accessToken,
      memberSubjectId: invitationOutcome.subjectId,
      workspaceId: targetWorkspaceId,
      workspaceName: targetWorkspace.name,
      allowedPropertyId,
      allowedPropertyName,
      deniedPropertyId,
      batchId,
      configuration,
      setStage: (stage) => { proofStage = stage; },
      setProfileId: (profileId) => {
        identifiers.customProfileId = profileId;
        cleanup.customProfile = "active";
      },
    });
    cleanup.customProfile = "archived-by-proof";
    workspaceAccessAdministrationResult = "passed";
    for (const name of administration.checks) addCheck(name);
  }

  proofStage = "enrollment-source-browser";
  await openWorkspaceInvites(ownerPage, targetWorkspace.name, "owner-enrollment");
  const enrollmentSource = await issueEnrollmentInBrowser(
    ownerPage,
    targetWorkspace.allowedPropertyName,
  );
  identifiers.enrollmentSourceId = enrollmentSource.sourceId;
  addCheck("team-qr-rendered");

  proofStage = "enrollment-existing-account-sign-in";
  enrollmentContext = await newBrowserContext();
  const enrollmentPage = await enrollmentContext.newPage();
  const enrollmentLogin = await signIn(enrollmentPage, enrollmentApplicant);
  enrollmentApplicant.accessToken = enrollmentLogin.accessToken;
  proofStage = "enrollment-existing-account-back-navigation";
  await openAndBackOutOfEnrollment(
    enrollmentPage,
    enrollmentSource,
    homeWorkspace.name,
  );
  proofStage = "enrollment-existing-account-submit";
  const pendingEnrollment = await submitEnrollmentInBrowser(
    enrollmentPage,
    enrollmentSource,
    enrollmentApplicant,
    targetWorkspace,
  );
  identifiers.enrollmentApplicationId = pendingEnrollment.applicationId;
  identifiers.enrollmentClaimId = pendingEnrollment.claimId;
  await assertPendingAccessDenied(enrollmentApplicant, targetWorkspaceId, allowedPropertyId);
  addCheck("existing-account-back-and-pending-denial");

  proofStage = "enrollment-worker-interruption";
  await openWorkspaceInvites(ownerPage, targetWorkspace.name, "owner-approval");
  await waitForJoinRequest(ownerPage, enrollmentApplicant.displayName);
  if (configuration.exerciseWorkerRestart) {
    stopPreviewWorker(configuration.composePath, configuration.environmentPath);
    workerStopped = true;
    cleanup.worker = "stopped-for-approval";
  }
  const approval = await approveJoinRequest(ownerPage, enrollmentApplicant.displayName);
  identifiers.enrollmentMembershipId = approval.membershipId;
  await assertPendingAccessDenied(enrollmentApplicant, targetWorkspaceId, allowedPropertyId);
  if (configuration.exerciseWorkerRestart) {
    const restartStartedAt = Date.now();
    const workerState = await startPreviewWorker(
      configuration.composePath,
      configuration.environmentPath,
      configuration.convergenceTimeoutMilliseconds,
      configuration.pollIntervalMilliseconds,
    );
    workerStopped = false;
    cleanup.worker = `restored-${workerState}`;
    browserChecks.workerRestartConvergenceMilliseconds = Date.now() - restartStartedAt;
  }
  addCheck(configuration.exerciseWorkerRestart
    ? "worker-stopped-approval-remained-denied"
    : "running-worker-approval-remained-denied");

  proofStage = "enrollment-browser-convergence";
  await waitForDashboard(enrollmentPage, targetWorkspace.name);

  proofStage = "enrollment-api-convergence";
  const enrollmentOutcome = await waitForProvisionedAccess(
    enrollmentApplicant,
    targetWorkspaceId,
    allowedPropertyId,
    deniedPropertyId,
    2,
    enrollmentSource.sourceId,
    approval.membershipId,
  );
  identifiers.enrollmentStaffMemberId = enrollmentOutcome.staffMemberId;
  addCheck(configuration.exerciseWorkerRestart
    ? "worker-restart-converged-once"
    : "running-worker-converged-once");

  proofStage = "enrollment-terminal-replay";
  await replayEnrollmentInBrowser(
    enrollmentPage,
    enrollmentSource,
    enrollmentApplicant,
    enrollmentOutcome,
  );
  addCheck("one-use-team-qr-terminal-replay-stable");

  proofStage = "release-continuity";
  observedReleaseId = await assertReleaseIdentity(
    api,
    configuration.expectedReleaseId,
    "release-continuity",
  );
  addCheck("exact-release-continuous");
  proofStage = "proof-complete";
} catch (error) {
  failedStage = proofStage;
  proofError = error;
} finally {
  proofStage = "cleanup";
  if (configuration.exerciseWorkerRestart && workerStopped) {
    try {
      const workerState = await startPreviewWorker(
        configuration.composePath,
        configuration.environmentPath,
        configuration.convergenceTimeoutMilliseconds,
        configuration.pollIntervalMilliseconds,
      );
      workerStopped = false;
      cleanup.worker = `restored-${workerState}-after-failure`;
    } catch {
      cleanup.worker = "failed";
      addCleanupFailure("worker-restoration");
    }
  }

  if (targetWorkspaceId && owner?.accessToken) {
    await attemptCleanup("nonOwnerMemberships", async () => {
      const removed = await removeNonOwnerMembers(owner, targetWorkspaceId);
      return `removed-${removed}`;
    });
    if (identifiers.customProfileId) {
      await attemptCleanup("customProfile", () => ensureWorkspaceAccessProfileArchived({
        api,
        ownerAccessToken: owner.accessToken,
        workspaceId: targetWorkspaceId,
        profileId: identifiers.customProfileId,
        configuration,
      }));
    }
    await attemptCleanup("properties", async () => {
      const retired = await retireProperties(owner, targetWorkspaceId, [allowedPropertyId, deniedPropertyId]);
      return `retired-${retired}`;
    });
    await attemptCleanup("targetWorkspace", async () => {
      await archiveWorkspace(owner, targetWorkspaceId);
      return "archived";
    });
  }
  if (applicantHomeWorkspaceId && enrollmentApplicant?.accessToken) {
    await attemptCleanup("applicantHomeWorkspace", async () => {
      await archiveWorkspace(enrollmentApplicant, applicantHomeWorkspaceId);
      return "archived";
    });
  }

  for (const [key, identity] of [
    ["invitationApplicantSessions", invitationApplicant],
    ["enrollmentApplicantSessions", enrollmentApplicant],
    ["ownerSessions", owner],
  ]) {
    if (!identity?.accessToken) continue;
    await attemptCleanup(key, async () => revokeIdentitySessions(identity));
  }

  for (const context of [invitationContext, enrollmentContext, ownerContext]) {
    if (!context) continue;
    try {
      await context.close();
    } catch {
      addCleanupFailure("browser-context-close");
    }
  }
  if (browser) {
    try {
      await browser.close();
    } catch {
      addCleanupFailure("browser-close");
    }
  }
  cleanup.browserContexts = cleanupFailures.some((name) => name.startsWith("browser"))
    ? "failed"
    : "closed-no-artifacts";

  await apiContext?.dispose().catch(() => addCleanupFailure("api-context-close"));
  await mailpitContext?.dispose().catch(() => addCleanupFailure("mailpit-context-close"));

  for (const identity of [owner, invitationApplicant, enrollmentApplicant]) {
    if (!identity) continue;
    identityEvidence.push({
      role: identity.role,
      fingerprintSha256: identity.fingerprintSha256,
      capturedMessageCount: identity.capturedMessageCount,
    });
    identity.email = null;
    identity.password = null;
    identity.accessToken = null;
  }
  cleanup.globalIdentities = cleanupFailures.some((name) => name.endsWith("Sessions"))
    ? "retained-session-cleanup-partial"
    : "retained-signed-out-no-public-delete-contract";
}

const result = proofError
  ? "proof-failed"
  : cleanupFailures.length > 0
    ? "proof-passed-cleanup-partial"
    : "passed";
const evidence = {
  schemaVersion: 1,
  evidenceKind: "bunkfy-preview-browser-onboarding-rehearsal",
  generatedAtUtc: new Date().toISOString(),
  origin: configuration.publicOrigin.origin,
  releaseId: observedReleaseId ?? configuration.expectedReleaseId,
  transport: configuration.publicOrigin.protocol === "https:"
    ? "trusted-https"
    : "loopback-http-preview",
  result,
  failure: proofError ? sanitizedFailure(proofError, failedStage ?? proofStage) : null,
  registrationAdapters,
  workspaceAccessAdministration: {
    requested: configuration.includeCustomProfileAdministration,
    result: workspaceAccessAdministrationResult,
  },
  browser: browserChecks,
  identities: identityEvidence,
  identifiers,
  cleanup,
  cleanupFailures,
  checks,
  limitations: [
    "mailpit-capture-is-not-real-provider-delivery-or-inbox-placement-proof",
    "external-identity-providers-disabled-and-not-exercised",
    "preview-compose-worker-control-is-not-hosted-orchestrator-proof",
    "synthetic-global-identities-retained-signed-out-no-public-delete-contract",
    "archived-workspaces-and-identifiers-retained-for-audit",
    ...(configuration.includeCustomProfileAdministration
      ? []
      : ["custom-profile-administration-not-exercised"]),
  ],
};

try {
  await writeEvidence(configuration.outputPath, evidence, configuration.force);
} catch {
  process.exitCode = 1;
}
if (proofError || cleanupFailures.length > 0) process.exitCode = 1;

async function readConfiguration() {
  const allowLoopbackHttp = optionalBooleanEnvironment(
    "BUNKFY_BROWSER_ALLOW_LOOPBACK_HTTP",
    false,
  );
  const publicOrigin = parsePublicOrigin(
    requireEnvironment("BUNKFY_BROWSER_PUBLIC_ORIGIN"),
    allowLoopbackHttp,
  );
  const expectedReleaseId = parseReleaseId(
    requireEnvironment("BUNKFY_BROWSER_EXPECTED_RELEASE_ID"),
  );
  const mailpitOrigin = parseMailpitOrigin(
    requireEnvironment("BUNKFY_BROWSER_MAILPIT_ORIGIN"),
  );
  const composePath = await assertRegularFile(
    requireEnvironment("BUNKFY_BROWSER_COMPOSE_PATH"),
    "compose-path",
  );
  const environmentPath = await assertRegularFile(
    requireEnvironment("BUNKFY_BROWSER_ENVIRONMENT_PATH"),
    "environment-path",
  );
  const outputPath = resolve(requireEnvironment("BUNKFY_BROWSER_RESULT_PATH"));
  const composeProjectName = requireEnvironment("BUNKFY_BROWSER_COMPOSE_PROJECT_NAME");
  if (!/^[a-z0-9][a-z0-9_-]{2,62}$/.test(composeProjectName)) {
    fail("Configuration.InvalidComposeProject", "configuration");
  }
  assertPreviewCompose(composePath, environmentPath, composeProjectName);
  return {
    allowLoopbackHttp,
    publicOrigin,
    expectedReleaseId,
    mailpitOrigin,
    composePath,
    environmentPath,
    outputPath,
    composeProjectName,
    force: optionalBooleanEnvironment("BUNKFY_BROWSER_FORCE", false),
    headless: optionalBooleanEnvironment("BUNKFY_BROWSER_HEADLESS", true),
    exerciseWorkerRestart: optionalBooleanEnvironment(
      "BUNKFY_BROWSER_EXERCISE_WORKER_RESTART",
      true,
    ),
    includeCustomProfileAdministration: optionalBooleanEnvironment(
      "BUNKFY_BROWSER_INCLUDE_CUSTOM_PROFILE_ADMINISTRATION",
      false,
    ),
    requestTimeoutMilliseconds: optionalIntegerEnvironment(
      "BUNKFY_BROWSER_REQUEST_TIMEOUT_MS",
      15_000,
      1_000,
      60_000,
    ),
    convergenceTimeoutMilliseconds: optionalIntegerEnvironment(
      "BUNKFY_BROWSER_CONVERGENCE_TIMEOUT_MS",
      180_000,
      30_000,
      600_000,
    ),
    pollIntervalMilliseconds: optionalIntegerEnvironment(
      "BUNKFY_BROWSER_POLL_INTERVAL_MS",
      2_000,
      500,
      5_000,
    ),
  };
}

function addCheck(name) {
  checks.push({ name, status: "passed" });
}

function addCleanupFailure(name) {
  if (!cleanupFailures.includes(name)) cleanupFailures.push(name);
}

async function attemptCleanup(key, action) {
  try {
    cleanup[key] = await action();
  } catch {
    cleanup[key] = "failed";
    addCleanupFailure(key);
  }
}

async function newBrowserContext() {
  return browser.newContext({
    viewport: { width: 1440, height: 960 },
    acceptDownloads: false,
    serviceWorkers: "block",
  });
}

async function registerAndVerifyIdentity(identity) {
  const registration = await api("/api/auth/browser/register", {
    method: "POST",
    data: {
      username: identity.email,
      usernameType: "email",
      password: identity.password,
    },
    stage: `register-${identity.role}`,
  });
  identity.accessToken = requiredAccessToken(registration.body, `register-${identity.role}`);
  const methods = await api("/api/auth/methods", {
    accessToken: identity.accessToken,
    stage: `read-auth-methods-${identity.role}`,
  });
  const activeEmail = oneActiveEmail(methods.body, identity.email, false, identity.role);
  await api("/api/auth/email-verification", {
    method: "POST",
    accessToken: identity.accessToken,
    data: { emailId: activeEmail.id },
    expectedStatus: 202,
    stage: `request-email-verification-${identity.role}`,
  });
  const capture = await waitForVerificationCode(
    mailpitContext,
    configuration.mailpitOrigin,
    identity.email,
    configuration.convergenceTimeoutMilliseconds,
    configuration.pollIntervalMilliseconds,
  );
  try {
    await api("/api/auth/email-verification/confirm", {
      method: "POST",
      accessToken: identity.accessToken,
      data: { code: capture.code },
      expectedStatus: 204,
      stage: `confirm-email-verification-${identity.role}`,
    });
  } finally {
    capture.code = null;
  }
  await pollUntil(
    () => api("/api/auth/methods", {
      accessToken: identity.accessToken,
      expectedStatus: [200, 429],
      stage: `wait-verified-email-${identity.role}`,
    }),
    (response) => {
      try {
        oneActiveEmail(response.body, identity.email, true, identity.role);
        return true;
      } catch {
        return false;
      }
    },
    pollOptions("Auth.EmailVerificationTimeout", `wait-verified-email-${identity.role}`),
  );
  identity.capturedMessageCount = capture.capturedMessageCount;
}

function requiredAccessToken(payload, stage) {
  if (typeof payload?.accessToken !== "string" || payload.accessToken.length < 32) {
    fail("Auth.AccessTokenMissing", stage);
  }
  return payload.accessToken;
}

function oneActiveEmail(payload, email, expectedVerified, role) {
  const matches = Array.isArray(payload?.emails)
    ? payload.emails.filter((candidate) =>
      candidate?.isActive === true &&
      candidate?.isVerified === expectedVerified &&
      typeof candidate?.email === "string" &&
      candidate.email.toLowerCase() === email.toLowerCase())
    : [];
  if (matches.length !== 1 || typeof matches[0].id !== "string") {
    fail("Auth.ActiveEmailMismatch", `email-method-${role}`);
  }
  return matches[0];
}

async function createWorkspace(identity, name, slug) {
  const response = await api("/api/organizations", {
    method: "POST",
    accessToken: identity.accessToken,
    data: { operationId: crypto.randomUUID(), name, slug },
    stage: `create-workspace-${identity.role}`,
  });
  const workspaceId = response.body?.organization?.organizationId;
  if (!isUuid(workspaceId) || response.body?.organization?.status !== "active" ||
      response.body?.membership?.role !== "owner") {
    fail("Workspace.InvalidCreationReceipt", `create-workspace-${identity.role}`);
  }
  await waitForWorkspace(identity, workspaceId, "active");
  const staff = await waitForCurrentStaff(identity, workspaceId);
  await api("/api/staff/me", {
    method: "PUT",
    tenantId: workspaceId,
    accessToken: identity.accessToken,
    data: {
      operationId: crypto.randomUUID(),
      displayName: identity.role === "owner" ? "Preview browser owner" : "Preview browser applicant owner",
      legalName: null,
      workEmail: null,
      workPhone: null,
      employeeNumber: null,
      jobTitle: "Operations verification",
      department: "Preview",
      expectedVersion: staff.version,
    },
    stage: `update-owner-staff-${identity.role}`,
  });
  return {
    workspaceId,
    name,
    slug,
    allowedPropertyName: null,
  };
}

async function createProperty(identity, workspaceId, name, code) {
  const response = await api("/api/properties", {
    method: "POST",
    tenantId: workspaceId,
    accessToken: identity.accessToken,
    data: {
      operationId: crypto.randomUUID(),
      name,
      code,
      timeZoneId: "UTC",
    },
    stage: `create-property-${code}`,
  });
  const propertyId = response.body?.propertyId;
  if (!isUuid(propertyId)) fail("Property.InvalidCreationReceipt", `create-property-${code}`);
  await pollUntil(
    () => api(`/api/properties/${propertyId}`, {
      tenantId: workspaceId,
      accessToken: identity.accessToken,
      expectedStatus: [200, 404, 429],
      stage: `wait-property-${code}`,
    }),
    (candidate) => candidate.status === 200 &&
      candidate.body?.propertyId === propertyId &&
      candidate.body?.status === "active",
    pollOptions("Property.ActivationTimeout", `wait-property-${code}`),
  );
  return propertyId;
}

async function waitForWorkspace(identity, workspaceId, expectedStatus) {
  return pollUntil(
    async () => {
      const items = await listAll(
        (page) => api(`/api/organizations?page=${page}&pageSize=100`, {
          accessToken: identity.accessToken,
          expectedStatus: [200, 429],
          stage: `list-workspaces-${identity.role}`,
        }),
        `list-workspaces-${identity.role}`,
        true,
      );
      if (items === null) return null;
      return items.find((item) => item?.organization?.organizationId === workspaceId) ?? null;
    },
    (candidate) => candidate?.organization?.status === expectedStatus,
    pollOptions("Workspace.ConvergenceTimeout", `wait-workspace-${identity.role}`),
  );
}

async function waitForCurrentStaff(identity, workspaceId) {
  const response = await pollUntil(
    () => api("/api/staff/me", {
      tenantId: workspaceId,
      accessToken: identity.accessToken,
      expectedStatus: [200, 404, 429],
      stage: `wait-current-staff-${identity.role}`,
    }),
    (candidate) => candidate.status === 200 && isUuid(candidate.body?.staffMemberId),
    pollOptions("Staff.ConvergenceTimeout", `wait-current-staff-${identity.role}`),
  );
  return response.body;
}

function pollOptions(code, stage) {
  return {
    timeoutMilliseconds: configuration.convergenceTimeoutMilliseconds,
    pollIntervalMilliseconds: configuration.pollIntervalMilliseconds,
    code,
    stage,
  };
}

function isUuid(value) {
  return typeof value === "string" &&
    /^[0-9a-f]{8}-[0-9a-f]{4}-[1-5][0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$/i.test(value);
}

async function listAll(loadPage, stage, allowRateLimited = false) {
  const items = [];
  for (let page = 1; page <= 100; page += 1) {
    const response = await loadPage(page);
    if (allowRateLimited && response.status === 429) return null;
    if (!Array.isArray(response.body?.items)) fail("Api.InvalidPage", stage);
    items.push(...response.body.items);
    if (response.body.hasMore !== true) return items;
  }
  fail("Api.PaginationLimit", stage);
}

async function signIn(page, identity) {
  await navigateToPublicPage(page, "/", "sign-in-navigation");
  await page.getByLabel("Email", { exact: true }).fill(identity.email);
  await page.getByLabel("Password", { exact: true }).fill(identity.password);
  const response = await waitForBrowserJsonResponse(
    page,
    "/api/auth/browser/login",
    "POST",
    200,
    () => page.getByRole("button", { name: "Sign in", exact: true }).click(),
    "browser-sign-in",
  );
  const accessToken = requiredAccessToken(response, "browser-sign-in");
  await page.getByRole("navigation", { name: "Main navigation" }).waitFor({
    timeout: configuration.convergenceTimeoutMilliseconds,
  });
  await assertPageHasNoRawCredential(page, identity.password, "browser-sign-in");
  return { accessToken };
}

async function openWorkspaceInvites(page, workspaceName, stagePrefix) {
  proofStage = `${stagePrefix}-workspace-navigation`;
  await navigateToPublicPage(page, "/workspace", proofStage);
  proofStage = `${stagePrefix}-workspace-heading`;
  await page.getByRole("heading", { name: workspaceName, exact: true }).waitFor({
    timeout: configuration.convergenceTimeoutMilliseconds,
  });
  proofStage = `${stagePrefix}-invites-tab`;
  const invites = page.getByRole("tab", { name: "Invites", exact: true });
  await invites.click();
  proofStage = `${stagePrefix}-invite-form`;
  await page.getByRole("heading", { name: "Invite one person", exact: true }).waitFor({
    timeout: configuration.convergenceTimeoutMilliseconds,
  });
}

async function issueInvitationInBrowser(page, recipientEmail, propertyName) {
  const form = page.locator("form").filter({ hasText: "Invite one person" });
  await form.getByLabel("Recipient email (optional)", { exact: true }).fill(recipientEmail);
  await chooseFrontDeskRole(page, form);
  await choosePropertyScope(form, propertyName);
  const issuance = await waitForJoinSourceIssuance(
    page,
    "/api/workspace-staff-enrollment/sources/invitations",
    () => form.getByRole("button", { name: "Create invite", exact: true }).click(),
    "issue-invitation-browser",
  );
  const source = validateIssuedSource(issuance, "invitation", propertyName);
  await validateIssuedJoinDialog(page, source);
  await page.getByRole("dialog").getByRole("button", { name: "Close", exact: true }).click();
  return source;
}

async function issueEnrollmentInBrowser(page, propertyName) {
  const form = page.locator("form").filter({ hasText: "Create a team QR" });
  await chooseFrontDeskRole(page, form);
  await choosePropertyScope(form, propertyName);
  await form.getByLabel("Maximum joins", { exact: true }).fill("1");
  const issuance = await waitForJoinSourceIssuance(
    page,
    "/api/workspace-staff-enrollment/sources/enrollment-links",
    () => form.getByRole("button", { name: "Create QR", exact: true }).click(),
    "issue-enrollment-browser",
  );
  const source = validateIssuedSource(issuance, "enrollment", propertyName);
  await validateIssuedJoinDialog(page, source);
  await page.getByRole("dialog").getByRole("button", { name: "Close", exact: true }).click();
  return source;
}

async function chooseFrontDeskRole(page, form) {
  await form.getByRole("combobox", { name: "Role", exact: true }).click();
  await page.getByRole("option", { name: /^Front desk\b/i }).click();
}

async function choosePropertyScope(form, propertyName) {
  await form.getByRole("button", { name: /^Selected properties\b/ }).click();
  const checkbox = form.getByRole("checkbox", {
    name: new RegExp(`^${escapeRegularExpression(propertyName)}\\b`),
  });
  if (!(await checkbox.isChecked())) await checkbox.check();
  const checked = await form.getByRole("checkbox").evaluateAll((items) =>
    items.filter((item) => item.checked).length,
  );
  if (checked !== 1) fail("Browser.PropertyScopeAmbiguous", "join-source-form");
}

function validateIssuedSource(payload, kind, propertyName) {
  const sourceId = payload?.plan?.sourceId;
  const token = payload?.token;
  const propertyIds = payload?.plan?.propertyIds;
  if (!isUuid(sourceId) || typeof token !== "string" || token.length < 32 ||
      payload?.alreadyIssued === true || payload?.plan?.profileKey !== "front-desk" ||
      !Array.isArray(propertyIds) || propertyIds.length !== 1 ||
      propertyIds[0] !== allowedPropertyId) {
    fail("Browser.InvalidJoinSourceReceipt", `issue-${kind}-browser`);
  }
  return {
    kind,
    sourceId,
    token,
    propertyName,
    url: buildJoinUrl(kind, token),
  };
}

async function validateIssuedJoinDialog(page, source) {
  const title = source.kind === "invitation" ? "Invitation ready" : "Team QR ready";
  const dialog = page.getByRole("dialog", { name: title });
  await dialog.waitFor({ timeout: configuration.requestTimeoutMilliseconds });
  const qr = dialog.locator('svg[role="img"]').first();
  const qrShape = await qr.evaluate((element) => {
    const bounds = element.getBoundingClientRect();
    const paths = [...element.querySelectorAll("path")];
    return {
      width: Math.round(bounds.width),
      height: Math.round(bounds.height),
      pathCount: paths.length,
      pathDataLength: paths.reduce((sum, path) => sum + (path.getAttribute("d")?.length ?? 0), 0),
    };
  });
  if (qrShape.width < 180 || qrShape.height < 180 ||
      qrShape.pathCount < 2 || qrShape.pathDataLength < 256) {
    fail("Browser.QrDidNotRender", `render-${source.kind}-qr`);
  }
  const visibleLink = await dialog.locator("p.font-mono").textContent();
  if (visibleLink?.trim() !== source.url) {
    fail("Browser.JoinLinkMismatch", `render-${source.kind}-qr`);
  }
}

async function completeInvitationBrowserJourney(page, source, identity, targetWorkspace) {
  proofStage = "invitation-link-capture";
  await openJoinLink(page, source, "invitation-link-capture");
  await page.getByRole("heading", { name: "Join your team", exact: true }).waitFor({
    timeout: configuration.requestTimeoutMilliseconds,
  });
  await page.getByLabel("Email", { exact: true }).fill(identity.email);
  await page.getByLabel("Password", { exact: true }).fill(identity.password);
  await page.getByLabel("Confirm password", { exact: true }).fill(identity.password);
  identity.displayName = "Preview invitation browser applicant";
  await page.getByLabel("Display name", { exact: true }).fill(identity.displayName);
  await page.getByLabel("Work email (optional)", { exact: true }).fill(identity.email);
  proofStage = "invitation-browser-registration";
  const registration = await waitForBrowserJsonResponse(
    page,
    "/api/auth/browser/register",
    "POST",
    200,
    () => page.getByRole("button", { name: "Create account", exact: true }).click(),
    "invitation-browser-registration",
  );
  identity.accessToken = requiredAccessToken(registration, "invitation-browser-registration");
  proofStage = "invitation-browser-profile";
  await page.getByRole("heading", { name: `Join ${targetWorkspace.name}`, exact: true }).waitFor({
    timeout: configuration.convergenceTimeoutMilliseconds,
  });
  await page.getByLabel("Display name", { exact: true }).fill(identity.displayName);
  await page.getByLabel("Job title (optional)", { exact: true }).fill("Preview invitation browser");
  await page.getByLabel("Department (optional)", { exact: true }).fill("Operations verification");
  await page.getByRole("button", { name: "Join workspace", exact: true }).click();
  proofStage = "invitation-browser-verification-form";
  await page.getByRole("heading", { name: "Verify your invited email", exact: true }).waitFor({
    timeout: configuration.convergenceTimeoutMilliseconds,
  });
  await waitForBrowserResponse(
    page,
    "/api/auth/email-verification",
    "POST",
    202,
    () => page.getByRole("button", { name: /^Send code to / }).click(),
    "invitation-browser-email-request",
  );
  proofStage = "invitation-browser-email-capture";
  const capture = await waitForVerificationCode(
    mailpitContext,
    configuration.mailpitOrigin,
    identity.email,
    configuration.convergenceTimeoutMilliseconds,
    configuration.pollIntervalMilliseconds,
  );
  identity.capturedMessageCount = capture.capturedMessageCount;
  await page.getByLabel("Verification code", { exact: true }).fill(capture.code);
  const acceptancePromise = waitForBrowserResponseOnly(
    page,
    "/api/organization-invitations/accept",
    "POST",
    200,
    "invitation-browser-acceptance",
    configuration.convergenceTimeoutMilliseconds,
  );
  const confirmationPromise = waitForBrowserResponseOnly(
    page,
    "/api/auth/email-verification/confirm",
    "POST",
    204,
    "invitation-browser-email-confirmation",
    configuration.convergenceTimeoutMilliseconds,
  );
  try {
    proofStage = "invitation-browser-acceptance";
    await page.getByRole("button", { name: "Verify and continue", exact: true }).click();
    const [acceptanceResponse] = await Promise.all([acceptancePromise, confirmationPromise]);
    const acceptance = await readBoundedJson(
      acceptanceResponse,
      256 * 1024,
      "Browser.ResponseTooLarge",
      "invitation-browser-acceptance",
    );
    const membership = acceptance?.membership?.membership;
    if (!isUuid(membership?.membershipId) || typeof membership?.subjectId !== "string" ||
        acceptance?.membership?.organization?.organizationId !== targetWorkspaceId) {
      fail("Browser.InvalidInvitationAcceptance", "invitation-browser-acceptance");
    }
    proofStage = "invitation-browser-dashboard";
    await waitForDashboard(page, targetWorkspace.name);
    await assertSecretCleared(page, source.token, "invitation-browser-complete");
    proofStage = "invitation-browser-provisioned-access";
    const outcome = await waitForProvisionedAccess(
      identity,
      targetWorkspaceId,
      allowedPropertyId,
      deniedPropertyId,
      1,
      source.sourceId,
      membership.membershipId,
    );
    return {
      ...outcome,
      membershipId: membership.membershipId,
      subjectId: membership.subjectId,
    };
  } finally {
    capture.code = null;
  }
}

async function replayInvitationInBrowser(page, source, identity, original) {
  await page.getByRole("button", { name: "Sign out", exact: true }).click();
  await page.getByRole("heading", { name: "Welcome back", exact: true }).waitFor({
    timeout: configuration.requestTimeoutMilliseconds,
  });
  await openJoinLink(page, source, "invitation-replay-link-capture");
  await page.getByRole("button", { name: "Sign in", exact: true }).click();
  await page.getByLabel("Email", { exact: true }).fill(identity.email);
  await page.getByLabel("Password", { exact: true }).fill(identity.password);
  const login = await waitForBrowserJsonResponse(
    page,
    "/api/auth/browser/login",
    "POST",
    200,
    () => page.getByRole("button", { name: "Sign in", exact: true }).click(),
    "invitation-replay-sign-in",
  );
  identity.accessToken = requiredAccessToken(login, "invitation-replay-sign-in");
  await page.getByRole("button", { name: "Join workspace", exact: true }).waitFor({
    timeout: configuration.convergenceTimeoutMilliseconds,
  });
  const replay = await waitForBrowserJsonResponse(
    page,
    "/api/organization-invitations/accept",
    "POST",
    200,
    () => page.getByRole("button", { name: "Join workspace", exact: true }).click(),
    "invitation-terminal-replay",
  );
  if (replay?.membership?.membership?.membershipId !== original.membershipId) {
    fail("Browser.InvitationReplayDuplicatedMembership", "invitation-terminal-replay");
  }
  await waitForDashboard(page);
  await assertSecretCleared(page, source.token, "invitation-terminal-replay");
  const current = await waitForProvisionedAccess(
    identity,
    targetWorkspaceId,
    allowedPropertyId,
    deniedPropertyId,
    1,
    source.sourceId,
    original.membershipId,
  );
  if (current.applicationId !== original.applicationId ||
      current.staffMemberId !== original.staffMemberId) {
    fail("Browser.InvitationReplayDuplicatedProjection", "invitation-terminal-replay");
  }
}

async function openAndBackOutOfEnrollment(page, source, homeWorkspaceName) {
  proofStage = "enrollment-back-link-capture";
  await openJoinLink(page, source, "enrollment-back-link-capture");
  proofStage = "enrollment-back-heading";
  await page.getByRole("heading", { name: /^Join / }).waitFor({
    timeout: configuration.requestTimeoutMilliseconds,
  });
  proofStage = "enrollment-back-control";
  const backControls = page.locator('button[aria-label="Back to BunkFy"]');
  const backControlCount = await backControls.count();
  if (backControlCount === 0) {
    fail("Browser.BackControlMissing", proofStage);
  }
  if (backControlCount !== 1) {
    fail("Browser.BackControlAmbiguous", proofStage);
  }
  try {
    await backControls.click();
  } catch (error) {
    if (error?.name === "TimeoutError") throw error;
    fail("Browser.BackControlActivationFailed", proofStage);
  }
  proofStage = "enrollment-back-url";
  await page.waitForURL(
    (url) => url.origin === configuration.publicOrigin.origin && url.pathname === "/" && !url.hash,
    { timeout: configuration.requestTimeoutMilliseconds },
  );
  proofStage = "enrollment-back-workspace-selector";
  const workspaceSelector = page.getByRole("combobox", {
    name: "Current workspace",
    exact: true,
  }).first();
  await workspaceSelector.waitFor({
    timeout: configuration.convergenceTimeoutMilliseconds,
  });
  const selectedWorkspace = await workspaceSelector.textContent();
  if (!selectedWorkspace?.includes(homeWorkspaceName)) {
    fail("Browser.BackDidNotReturnToExistingWorkspace", "enrollment-back-navigation");
  }
  proofStage = "enrollment-back-secret-clearance";
  await assertSecretCleared(page, source.token, "enrollment-back-navigation");
}

async function submitEnrollmentInBrowser(page, source, identity, targetWorkspace) {
  proofStage = "enrollment-submit-link-capture";
  await openJoinLink(page, source, "enrollment-link-capture");
  proofStage = "enrollment-submit-heading";
  await page.getByRole("heading", { name: `Join ${targetWorkspace.name}`, exact: true }).waitFor({
    timeout: configuration.requestTimeoutMilliseconds,
  });
  proofStage = "enrollment-submit-profile";
  identity.displayName = "Preview enrollment browser applicant";
  await page.getByLabel("Display name", { exact: true }).fill(identity.displayName);
  await page.getByLabel("Work email (optional)", { exact: true }).fill(identity.email);
  await page.getByLabel("Job title (optional)", { exact: true }).fill("Preview enrollment browser");
  await page.getByLabel("Department (optional)", { exact: true }).fill("Operations verification");
  const applicationPromise = waitForBrowserResponseOnly(
    page,
    "/api/workspace-staff-enrollment/applications",
    "POST",
    200,
    "enrollment-browser-application",
    configuration.convergenceTimeoutMilliseconds,
  );
  const claimPromise = waitForBrowserResponseOnly(
    page,
    "/api/organization-enrollment/claim",
    "POST",
    200,
    "enrollment-browser-claim",
    configuration.convergenceTimeoutMilliseconds,
  );
  proofStage = "enrollment-submit-request";
  await page.getByRole("button", { name: "Request access", exact: true }).click();
  const [applicationResponse, claimResponse] = await Promise.all([applicationPromise, claimPromise]);
  const application = await readBoundedJson(
    applicationResponse,
    256 * 1024,
    "Browser.ResponseTooLarge",
    "enrollment-browser-application",
  );
  const claim = await readBoundedJson(
    claimResponse,
    256 * 1024,
    "Browser.ResponseTooLarge",
    "enrollment-browser-claim",
  );
  if (!isUuid(application?.applicationId) || application?.sourceId !== source.sourceId ||
      !isUuid(claim?.claim?.claimId) || claim?.claim?.status !== "pending" || claim?.membership !== null) {
    fail("Browser.InvalidPendingEnrollment", "enrollment-browser-claim");
  }
  proofStage = "enrollment-submit-confirmation";
  await page.getByRole("heading", { name: "Request sent", exact: true }).waitFor({
    timeout: configuration.requestTimeoutMilliseconds,
  });
  return {
    applicationId: application.applicationId,
    claimId: claim.claim.claimId,
  };
}

async function waitForJoinRequest(page, applicantDisplayName) {
  await page.reload({
    waitUntil: "domcontentloaded",
    timeout: configuration.requestTimeoutMilliseconds,
  });
  await page.getByRole("tab", { name: "Invites", exact: true }).click();
  return pollUntil(
    async () => {
      const row = page.locator("article").filter({ hasText: applicantDisplayName });
      if (await row.count() === 1 && await row.getByRole("button", { name: "Approve", exact: true }).isEnabled()) {
        return row;
      }
      await page.waitForTimeout(configuration.pollIntervalMilliseconds);
      await page.reload({ waitUntil: "domcontentloaded" });
      await page.getByRole("tab", { name: "Invites", exact: true }).click();
      return null;
    },
    (candidate) => candidate !== null,
    pollOptions("Browser.JoinRequestTimeout", "owner-join-request"),
  );
}

async function approveJoinRequest(page, applicantDisplayName) {
  const row = page.locator("article").filter({ hasText: applicantDisplayName });
  const response = await waitForBrowserJsonResponseMatching(
    page,
    (candidate) => {
      const url = new URL(candidate.url());
      return candidate.request().method() === "POST" &&
        url.pathname.endsWith("/approve") &&
        url.pathname.includes("/join-requests/");
    },
    200,
    () => row.getByRole("button", { name: "Approve", exact: true }).click(),
    "owner-approve-enrollment",
  );
  const membership = response?.membership?.membership;
  if (response?.claim?.status !== "accepted" || !isUuid(membership?.membershipId)) {
    fail("Browser.InvalidEnrollmentApproval", "owner-approve-enrollment");
  }
  return { membershipId: membership.membershipId, subjectId: membership.subjectId };
}

async function replayEnrollmentInBrowser(page, source, identity, original) {
  await openJoinLink(page, source, "enrollment-terminal-replay");
  await page.waitForURL(
    (url) => url.origin === configuration.publicOrigin.origin && url.pathname === "/" && !url.hash,
    { timeout: configuration.convergenceTimeoutMilliseconds },
  );
  await assertSecretCleared(page, source.token, "enrollment-terminal-replay");
  const current = await waitForProvisionedAccess(
    identity,
    targetWorkspaceId,
    allowedPropertyId,
    deniedPropertyId,
    2,
    source.sourceId,
    identifiers.enrollmentMembershipId,
  );
  if (current.applicationId !== original.applicationId ||
      current.staffMemberId !== original.staffMemberId) {
    fail("Browser.EnrollmentReplayDuplicatedProjection", "enrollment-terminal-replay");
  }
  const sources = await listAll(
    (pageNumber) => api(
      `/api/workspace-staff-enrollment/sources?sourceKind=2&page=${pageNumber}&pageSize=100`,
      {
        tenantId: targetWorkspaceId,
        accessToken: owner.accessToken,
        stage: "enrollment-source-capacity",
      },
    ),
    "enrollment-source-capacity",
  );
  const currentSource = sources.find((candidate) => candidate?.sourceId === source.sourceId);
  if (currentSource?.status !== 7 || currentSource?.reservedClaims !== 1 ||
      currentSource?.maximumClaims !== 1) {
    fail("Browser.EnrollmentCapacityDidNotClose", "enrollment-source-capacity");
  }
}

async function openJoinLink(page, source, stage) {
  const response = await page.goto(source.url, {
    waitUntil: "domcontentloaded",
    timeout: configuration.requestTimeoutMilliseconds,
  });
  if (!response || response.status() !== 200 ||
      response.headers()["x-bunkfy-release-id"] !== configuration.expectedReleaseId) {
    fail("Browser.JoinNavigationReleaseMismatch", stage);
  }
  await page.waitForFunction(() => window.location.hash === "", null, {
    timeout: configuration.requestTimeoutMilliseconds,
  });
  if (new URL(page.url()).pathname !== "/join") {
    fail("Browser.JoinPathChangedBeforeCapture", stage);
  }
}

async function waitForDashboard(page, expectedWorkspaceName = null) {
  await page.waitForURL(
    (url) => url.origin === configuration.publicOrigin.origin && url.pathname === "/" && !url.hash,
    { timeout: configuration.convergenceTimeoutMilliseconds },
  );
  await page.getByRole("navigation", { name: "Main navigation" }).waitFor({
    timeout: configuration.convergenceTimeoutMilliseconds,
  });
  if (expectedWorkspaceName) {
    const selector = page.getByRole("combobox", {
      name: "Current workspace",
      exact: true,
    }).first();
    await selector.waitFor({ timeout: configuration.convergenceTimeoutMilliseconds });
    const selected = await selector.textContent();
    if (!selected?.includes(expectedWorkspaceName)) {
      fail("Browser.WrongWorkspaceActivated", "dashboard-activation");
    }
  }
}

async function navigateToPublicPage(page, path, stage) {
  const response = await page.goto(new URL(path, configuration.publicOrigin).toString(), {
    waitUntil: "domcontentloaded",
    timeout: configuration.requestTimeoutMilliseconds,
  });
  if (!response || response.status() !== 200 ||
      response.headers()["x-bunkfy-release-id"] !== configuration.expectedReleaseId) {
    fail("Browser.NavigationReleaseMismatch", stage);
  }
}

async function waitForBrowserResponse(page, path, method, expectedStatus, action, stage) {
  const response = await waitForBrowserResponseOnly(
    page,
    path,
    method,
    expectedStatus,
    stage,
    configuration.convergenceTimeoutMilliseconds,
    action,
  );
  return response;
}

async function waitForBrowserJsonResponse(page, path, method, expectedStatus, action, stage) {
  const response = await waitForBrowserResponse(page, path, method, expectedStatus, action, stage);
  return readBoundedJson(response, 256 * 1024, "Browser.ResponseTooLarge", stage);
}

async function waitForJoinSourceIssuance(page, path, action, stage) {
  const deadline = Date.now() + configuration.convergenceTimeoutMilliseconds;
  let lastProblemCode = null;
  while (Date.now() < deadline) {
    const response = await waitForBrowserResponseOnly(
      page,
      path,
      "POST",
      [200, 409],
      stage,
      configuration.convergenceTimeoutMilliseconds,
      action,
    );
    const payload = await readBoundedJson(
      response,
      256 * 1024,
      "Browser.ResponseTooLarge",
      stage,
    );
    if (response.status() === 200) return payload;
    lastProblemCode = safeProblemCode(payload);
    if (!RETRYABLE_JOIN_SOURCE_CODES.has(lastProblemCode)) {
      const suffix = lastProblemCode ? `.${lastProblemCode}` : "";
      fail(`Browser.UnexpectedStatus.409${suffix}`, stage);
    }
    await page.waitForTimeout(configuration.pollIntervalMilliseconds);
  }
  const suffix = lastProblemCode ? `.${lastProblemCode}` : "";
  fail(`Browser.RetryableConflictTimeout${suffix}`, stage);
}

async function waitForBrowserJsonResponseMatching(page, predicate, expectedStatus, action, stage) {
  const responsePromise = page.waitForResponse(predicate, {
    timeout: configuration.convergenceTimeoutMilliseconds,
  });
  await action();
  const response = await responsePromise;
  await throwForUnexpectedBrowserStatus(response, expectedStatus, stage);
  return readBoundedJson(response, 256 * 1024, "Browser.ResponseTooLarge", stage);
}

async function waitForBrowserResponseOnly(
  page,
  path,
  method,
  expectedStatus,
  stage,
  timeout,
  action = null,
) {
  const responsePromise = page.waitForResponse((candidate) => {
    const url = new URL(candidate.url());
    return url.origin === configuration.publicOrigin.origin &&
      url.pathname === path &&
      candidate.request().method() === method;
  }, { timeout });
  if (action) await action();
  const response = await responsePromise;
  await throwForUnexpectedBrowserStatus(response, expectedStatus, stage);
  return response;
}

async function throwForUnexpectedBrowserStatus(response, expectedStatus, stage) {
  const acceptedStatuses = Array.isArray(expectedStatus) ? expectedStatus : [expectedStatus];
  if (acceptedStatuses.includes(response.status())) return;
  let problemCode = null;
  try {
    const problem = await readBoundedJson(
      response,
      64 * 1024,
      "Browser.ErrorResponseTooLarge",
      stage,
    );
    problemCode = safeProblemCode(problem);
  } catch {
    // The status and proof stage remain sufficient when the error payload is unavailable.
  }
  const suffix = problemCode ? `.${problemCode}` : "";
  fail(`Browser.UnexpectedStatus.${response.status()}${suffix}`, stage);
}

function safeProblemCode(problem) {
  const candidate = problem?.code ?? problem?.error?.code ?? problem?.title;
  return typeof candidate === "string" &&
    /^[A-Za-z][A-Za-z0-9._-]{2,127}$/.test(candidate)
    ? candidate
    : null;
}

async function assertSecretCleared(page, secret, stage) {
  if (page.url().includes(secret)) fail("Browser.SecretVisibleInUrl", stage);
  const retained = await page.evaluate((value) => {
    const stores = [window.localStorage, window.sessionStorage];
    return stores.some((storage) =>
      Array.from({ length: storage.length }, (_, index) => storage.key(index))
        .filter(Boolean)
        .some((key) => `${key}:${storage.getItem(key) ?? ""}`.includes(value)));
  }, secret);
  if (retained) fail("Browser.SecretRetainedAfterTerminalTransition", stage);
}

async function assertPageHasNoRawCredential(page, value, stage) {
  const exposed = await page.evaluate((credential) =>
    document.documentElement.textContent?.includes(credential) === true,
  value);
  if (exposed) fail("Browser.RawCredentialRendered", stage);
}

function buildJoinUrl(kind, token) {
  const url = new URL("/join", configuration.publicOrigin);
  url.hash = new URLSearchParams({ [kind]: token }).toString();
  return url.toString();
}

function escapeRegularExpression(value) {
  return value.replace(/[.*+?^${}()|[\]\\]/g, "\\$&");
}

async function assertPendingAccessDenied(identity, workspaceId, propertyId) {
  await api(`/api/properties/${propertyId}`, {
    tenantId: workspaceId,
    accessToken: identity.accessToken,
    expectedStatus: 403,
    responseType: "body",
    stage: "pending-property-access-denial",
  });
  const tenantScope = `tenant:${workspaceId}`;
  const propertyScope = `${tenantScope}/property:${propertyId}`;
  const evaluation = await api("/api/access/permissions/evaluate", {
    method: "POST",
    tenantId: workspaceId,
    accessToken: identity.accessToken,
    expectedStatus: [200, 403],
    data: {
      checks: [
        { permission: "properties.read", scope: propertyScope },
        { permission: "reservations.create", scope: propertyScope },
        { permission: "staff.manage", scope: tenantScope },
      ],
    },
    stage: "pending-policy-evaluation",
  });
  if (evaluation.status === 403) return;
  for (const candidate of evaluation.body?.permissions ?? []) {
    if (candidate?.allowed !== false) {
      fail("Access.PendingPermissionGranted", "pending-policy-evaluation");
    }
  }
  if (!Array.isArray(evaluation.body?.permissions) ||
      evaluation.body.permissions.length !== 3) {
    fail("Access.PendingEvaluationIncomplete", "pending-policy-evaluation");
  }
}

async function waitForProvisionedAccess(
  identity,
  workspaceId,
  allowedId,
  deniedId,
  sourceKind,
  sourceId,
  membershipId,
) {
  const current = await pollUntil(
    () => api(
      `/api/workspace-staff-enrollment/${workspaceId}/applications/current` +
        `?sourceKind=${sourceKind}&sourceId=${sourceId}`,
      {
        accessToken: identity.accessToken,
        expectedStatus: [200, 429],
        stage: "wait-onboarding-application",
      },
    ),
    (response) => response.body?.status === 5 && isUuid(response.body?.staffMemberId),
    pollOptions("Onboarding.ProvisioningTimeout", "wait-onboarding-application"),
  );
  const staff = await waitForCurrentStaff(identity, workspaceId);
  if (staff.staffMemberId !== current.body.staffMemberId ||
      typeof staff.authSubjectId !== "string") {
    fail("Staff.ProvisioningCorrelationMismatch", "wait-onboarding-application");
  }
  const tenantScope = `tenant:${workspaceId}`;
  const allowedScope = `${tenantScope}/property:${allowedId}`;
  const deniedScope = `${tenantScope}/property:${deniedId}`;
  await pollUntil(
    () => api("/api/access/permissions/evaluate", {
      method: "POST",
      tenantId: workspaceId,
      accessToken: identity.accessToken,
      expectedStatus: [200, 429],
      data: {
        checks: [
          { permission: "properties.read", scope: allowedScope },
          { permission: "reservations.create", scope: allowedScope },
          { permission: "properties.read", scope: deniedScope },
          { permission: "staff.manage", scope: tenantScope },
        ],
      },
      stage: "wait-least-privilege-access",
    }),
    (response) =>
      permissionMatches(response.body, "properties.read", allowedScope, true) &&
      permissionMatches(response.body, "reservations.create", allowedScope, true) &&
      permissionMatches(response.body, "properties.read", deniedScope, false) &&
      permissionMatches(response.body, "staff.manage", tenantScope, false),
    pollOptions("Access.AssignmentTimeout", "wait-least-privilege-access"),
  );
  await api(`/api/properties/${allowedId}`, {
    tenantId: workspaceId,
    accessToken: identity.accessToken,
    stage: "allowed-property-route",
  });
  await api(`/api/properties/${deniedId}`, {
    tenantId: workspaceId,
    accessToken: identity.accessToken,
    expectedStatus: 403,
    responseType: "body",
    stage: "denied-property-route",
  });
  const members = await listAll(
    (page) => api(`/api/organizations/${workspaceId}/members?page=${page}&pageSize=100`, {
      tenantId: workspaceId,
      accessToken: owner.accessToken,
      stage: "verify-membership-cardinality",
    }),
    "verify-membership-cardinality",
  );
  const matches = members.filter((member) => member?.membershipId === membershipId);
  if (matches.length !== 1 || matches[0]?.subjectId !== staff.authSubjectId) {
    fail("Workspace.MembershipCardinalityMismatch", "verify-membership-cardinality");
  }
  const encodedSubject = encodeURIComponent(staff.authSubjectId);
  await pollUntil(
    () => api(`/api/workspace-access/members/${encodedSubject}/access`, {
      tenantId: workspaceId,
      accessToken: owner.accessToken,
      expectedStatus: [200, 404, 429],
      stage: "verify-owner-visible-assignment",
    }),
    (response) => response.status === 200 &&
      Array.isArray(response.body?.assignments) &&
      response.body.assignments.length === 1 &&
      response.body.assignments[0]?.profileKey === "front-desk" &&
      response.body.assignments[0]?.propertyId === allowedId,
    pollOptions("Access.OwnerProjectionTimeout", "verify-owner-visible-assignment"),
  );
  return {
    applicationId: current.body.applicationId,
    staffMemberId: staff.staffMemberId,
    membershipId,
    subjectId: staff.authSubjectId,
  };
}

function permissionMatches(payload, permission, scope, allowed) {
  const matches = Array.isArray(payload?.permissions)
    ? payload.permissions.filter((candidate) =>
      candidate?.permission === permission && candidate?.scope === scope)
    : [];
  return matches.length === 1 && matches[0].allowed === allowed;
}

async function removeNonOwnerMembers(identity, workspaceId) {
  let removed = 0;
  const deadline = Date.now() + configuration.convergenceTimeoutMilliseconds;
  while (Date.now() < deadline) {
    const members = await listAll(
      (page) => api(`/api/organizations/${workspaceId}/members?page=${page}&pageSize=100`, {
        tenantId: workspaceId,
        accessToken: identity.accessToken,
        stage: "cleanup-members",
      }),
      "cleanup-members",
    );
    const target = members.find((member) =>
      member?.role !== "owner" && member?.status !== "removed");
    if (!target) return removed;

    const staffSummaries = await listAll(
      (page) => api(`/api/staff/members?page=${page}&pageSize=100`, {
        tenantId: workspaceId,
        accessToken: identity.accessToken,
        stage: "cleanup-staff-list",
      }),
      "cleanup-staff-list",
    );
    const profiles = [];
    for (const summary of staffSummaries) {
      const profile = await api(`/api/staff/members/${summary.staffMemberId}/profile`, {
        tenantId: workspaceId,
        accessToken: identity.accessToken,
        stage: "cleanup-staff-profile",
      });
      if (profile.body?.staffMemberId !== summary.staffMemberId) {
        fail("Cleanup.StaffProfileMismatch", "cleanup-staff-profile");
      }
      profiles.push(profile.body);
    }
    const matches = profiles.filter((profile) => profile?.authSubjectId === target.subjectId);
    if (matches.length === 0) {
      await new Promise((resolveDelay) =>
        setTimeout(resolveDelay, configuration.pollIntervalMilliseconds));
      continue;
    }
    if (matches.length !== 1) fail("Cleanup.DuplicateStaff", "cleanup-staff-profile");
    const staff = matches[0];
    if (staff.status === 1 || staff.status === 2) {
      const departure = await api(`/api/staff/members/${staff.staffMemberId}/depart`, {
        method: "POST",
        tenantId: workspaceId,
        accessToken: identity.accessToken,
        data: {
          operationId: crypto.randomUUID(),
          effectiveOn: new Date().toISOString().slice(0, 10),
          reason: "Preview browser onboarding rehearsal cleanup.",
          expectedVersion: staff.version,
        },
        stage: "cleanup-staff-departure",
      });
      if (departure.body?.staffMemberId !== staff.staffMemberId ||
          departure.body?.status !== 3) {
        fail("Cleanup.InvalidDepartureReceipt", "cleanup-staff-departure");
      }
      removed += 1;
    } else if (staff.status !== 3) {
      fail("Cleanup.UnsupportedStaffStatus", "cleanup-staff-departure");
    }
    await new Promise((resolveDelay) =>
      setTimeout(resolveDelay, configuration.pollIntervalMilliseconds));
  }
  fail("Cleanup.MembershipTimeout", "cleanup-members");
}

async function retireProperties(identity, workspaceId, propertyIds) {
  let retired = 0;
  for (const propertyId of propertyIds.filter(Boolean)) {
    const response = await api(`/api/properties/${propertyId}`, {
      tenantId: workspaceId,
      accessToken: identity.accessToken,
      stage: "cleanup-property-read",
    });
    if (response.body?.status === "retired") {
      retired += 1;
      continue;
    }
    if (response.body?.status !== "active") {
      fail("Cleanup.UnsupportedPropertyStatus", "cleanup-property-read");
    }
    const receipt = await api(`/api/properties/${propertyId}/retire`, {
      method: "POST",
      tenantId: workspaceId,
      accessToken: identity.accessToken,
      data: {
        operationId: crypto.randomUUID(),
        confirmed: true,
        expectedVersion: response.body.version,
      },
      stage: "cleanup-property-retire",
    });
    if (receipt.body?.propertyId !== propertyId || receipt.body?.status !== "retired") {
      fail("Cleanup.InvalidPropertyRetirement", "cleanup-property-retire");
    }
    retired += 1;
  }
  return retired;
}

async function archiveWorkspace(identity, workspaceId) {
  const summary = await waitForWorkspace(identity, workspaceId, "active").catch(async () => {
    const items = await listAll(
      (page) => api(`/api/organizations?page=${page}&pageSize=100`, {
        accessToken: identity.accessToken,
        stage: "cleanup-workspace-list",
      }),
      "cleanup-workspace-list",
    );
    return items.find((item) => item?.organization?.organizationId === workspaceId) ?? null;
  });
  if (!summary?.organization) fail("Cleanup.WorkspaceMissing", "cleanup-workspace-list");
  let organization = summary.organization;
  if (organization.status === "archived") return;
  if (organization.status === "active") {
    const suspended = await api(`/api/organizations/${workspaceId}/suspend`, {
      method: "POST",
      tenantId: workspaceId,
      accessToken: identity.accessToken,
      data: {
        operationId: crypto.randomUUID(),
        expectedVersion: organization.version,
      },
      stage: "cleanup-workspace-suspend",
    });
    organization = suspended.body;
  }
  if (organization?.status !== "suspended") {
    fail("Cleanup.UnsupportedWorkspaceStatus", "cleanup-workspace-suspend");
  }
  const archived = await api(`/api/organizations/${workspaceId}/archive`, {
    method: "POST",
    tenantId: workspaceId,
    accessToken: identity.accessToken,
    data: {
      operationId: crypto.randomUUID(),
      expectedVersion: organization.version,
    },
    stage: "cleanup-workspace-archive",
  });
  if (archived.body?.status !== "archived" ||
      archived.body?.organizationId !== workspaceId) {
    fail("Cleanup.InvalidWorkspaceArchive", "cleanup-workspace-archive");
  }
}

async function revokeIdentitySessions(identity) {
  const response = await api("/api/auth/sign-out-all", {
    method: "POST",
    accessToken: identity.accessToken,
    expectedStatus: [204, 401],
    responseType: "body",
    stage: `cleanup-sessions-${identity.role}`,
  });
  if (response.status === 401) return "already-revoked";
  await pollUntil(
    () => api("/api/auth/methods", {
      accessToken: identity.accessToken,
      expectedStatus: [200, 401, 429],
      responseType: "body",
      stage: `verify-session-revocation-${identity.role}`,
    }),
    (candidate) => candidate.status === 401,
    pollOptions("Cleanup.SessionRevocationTimeout", `verify-session-revocation-${identity.role}`),
  );
  return "revoked";
}
