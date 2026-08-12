import {
  fail,
  pollUntil,
  readBoundedJson,
} from "./preview-browser-onboarding.common.mjs";

const PROPERTIES_READ = "properties.read";
const RESERVATIONS_READ = "reservations.read";
const RESERVATIONS_CREATE = "reservations.create";
const STAFF_MANAGE = "staff.manage";
const PROFILES_MANAGE = "access-control.profiles.manage";

export async function runPreviewWorkspaceAccessAdministration(context) {
  const roleName = `Property observer ${context.batchId}`;
  const roleDescription = "Read one property's setup and reservation schedule.";

  context.setStage("workspace-access-create-role-browser");
  await openWorkspaceTab(context, context.ownerPage, "Roles", "Roles and permissions");
  await context.ownerPage.getByRole("button", { name: "New role", exact: true }).click();
  const createDialog = context.ownerPage.getByRole("dialog", {
    name: "New workspace role",
    exact: true,
  });
  await createDialog.getByLabel("Role name", { exact: true }).fill(roleName);
  await createDialog.getByLabel("Description", { exact: true }).fill(roleDescription);
  await checkPermission(createDialog, "View properties");
  const created = await waitForBrowserJsonResponse(
    context,
    context.ownerPage,
    "/api/workspace-access/profiles",
    "POST",
    200,
    () => createDialog.getByRole("button", { name: "Create role", exact: true }).click(),
    "workspace-access-create-role-browser",
  );
  assertProfile(created, {
    displayName: roleName,
    permissions: [PROPERTIES_READ],
    status: 1,
    isSeed: false,
  }, "workspace-access-create-role-browser");
  context.setProfileId(created.profileId);

  context.setStage("workspace-access-assign-custom-role-browser");
  const customAssignment = await assignMemberRole(
    context,
    roleName,
    created.profileId,
    context.allowedPropertyName,
  );
  assertExactAssignment(
    customAssignment,
    context.memberSubjectId,
    created.profileId,
    context.allowedPropertyId,
    "workspace-access-assign-custom-role-browser",
  );

  context.setStage("workspace-access-custom-role-least-privilege");
  await waitForEffectiveAccess(context, false);
  await waitForDeniedProfileMutation(context, created, roleName, roleDescription);
  await assertMemberNavigation(context, false);

  context.setStage("workspace-access-update-role-browser");
  await openWorkspaceTab(context, context.ownerPage, "Roles", "Roles and permissions");
  const roleArticle = await oneRoleArticle(context.ownerPage, roleName, "workspace-access-update-role-browser");
  await roleArticle.getByRole("button", { name: "Edit", exact: true }).click();
  const editDialog = context.ownerPage.getByRole("dialog", {
    name: `Edit ${roleName}`,
    exact: true,
  });
  await checkPermission(editDialog, "View reservations");
  const updated = await waitForBrowserJsonResponse(
    context,
    context.ownerPage,
    `/api/workspace-access/profiles/${created.profileId}`,
    "PUT",
    200,
    () => editDialog.getByRole("button", { name: "Save role", exact: true }).click(),
    "workspace-access-update-role-browser",
  );
  assertProfile(updated, {
    displayName: roleName,
    permissions: [PROPERTIES_READ, RESERVATIONS_READ],
    status: 1,
    isSeed: false,
  }, "workspace-access-update-role-browser");
  if (updated.version <= created.version) {
    fail("WorkspaceAccess.ProfileVersionDidNotAdvance", "workspace-access-update-role-browser");
  }

  context.setStage("workspace-access-updated-role-convergence");
  await waitForEffectiveAccess(context, true);
  await assertMemberNavigation(context, true);

  context.setStage("workspace-access-reassign-front-desk-browser");
  const frontDeskAssignment = await assignMemberRole(
    context,
    "Front desk",
    null,
    context.allowedPropertyName,
  );
  const frontDesk = frontDeskAssignment.assignments?.[0];
  if (frontDeskAssignment.subjectId !== context.memberSubjectId ||
      !Array.isArray(frontDeskAssignment.assignments) ||
      frontDeskAssignment.assignments.length !== 1 ||
      frontDesk?.profileKey !== "front-desk" ||
      frontDesk?.propertyId !== context.allowedPropertyId ||
      frontDesk?.profileId === created.profileId) {
    fail("WorkspaceAccess.FrontDeskReplacementMismatch", "workspace-access-reassign-front-desk-browser");
  }
  await waitForProfileState(context, created.profileId, 1, 0);

  context.setStage("workspace-access-archive-role-browser");
  await openWorkspaceTab(context, context.ownerPage, "Roles", "Roles and permissions");
  const unassignedRole = await oneRoleArticle(
    context.ownerPage,
    roleName,
    "workspace-access-archive-role-browser",
  );
  const archiveButton = unassignedRole.getByRole("button", { name: "Archive", exact: true });
  await archiveButton.waitFor({ timeout: context.configuration.convergenceTimeoutMilliseconds });
  if (await archiveButton.isDisabled()) {
    fail("WorkspaceAccess.ProfileStillAssigned", "workspace-access-archive-role-browser");
  }
  await archiveButton.click();
  const archiveDialog = context.ownerPage.getByRole("dialog", {
    name: `Archive ${roleName}?`,
    exact: true,
  });
  await waitForBrowserResponse(
    context,
    context.ownerPage,
    `/api/workspace-access/profiles/${created.profileId}/archive`,
    "POST",
    204,
    () => archiveDialog.getByRole("button", { name: "Archive role", exact: true }).click(),
    "workspace-access-archive-role-browser",
  );
  await waitForProfileState(context, created.profileId, 2, 0);

  context.setStage("workspace-access-archived-role-unavailable");
  await reloadWithReleaseGuard(context, context.ownerPage, "workspace-access-archive-refresh");
  await openWorkspaceTab(context, context.ownerPage, "Members", "Workspace members");
  const memberEditor = await openOnlyMemberAccessEditor(context);
  const rolePicker = memberEditor.getByRole("combobox", { name: "Role", exact: true });
  await rolePicker.filter({ hasText: /^Front desk\b/ }).waitFor({
    timeout: context.configuration.convergenceTimeoutMilliseconds,
  });
  await rolePicker.click();
  await context.ownerPage.getByRole("option", { name: /^Front desk\b/ }).waitFor({
    timeout: context.configuration.requestTimeoutMilliseconds,
  });
  const archivedOptions = context.ownerPage.getByRole("option", {
    name: new RegExp(`^${escapeRegularExpression(roleName)}\\b`),
  });
  if (await archivedOptions.count() !== 0) {
    fail("WorkspaceAccess.ArchivedProfileStillAssignable", "workspace-access-archived-role-unavailable");
  }
  await context.ownerPage.keyboard.press("Escape");
  await memberEditor.getByRole("button", { name: "Cancel", exact: true }).click();

  return {
    profileId: created.profileId,
    checks: [
      "custom-role-created-through-browser",
      "custom-role-reassignment-least-privilege",
      "custom-role-update-live-permissions",
      "custom-role-unassigned-and-archived",
    ],
  };
}

export async function ensureWorkspaceAccessProfileArchived({
  api,
  ownerAccessToken,
  workspaceId,
  profileId,
  configuration,
}) {
  const profile = await pollUntil(
    () => findProfile(api, ownerAccessToken, workspaceId, profileId),
    (candidate) => candidate?.status === 2 ||
      (candidate?.status === 1 && candidate?.assignmentCount === 0),
    {
      timeoutMilliseconds: configuration.convergenceTimeoutMilliseconds,
      pollIntervalMilliseconds: configuration.pollIntervalMilliseconds,
      code: "Cleanup.CustomProfileAssignmentTimeout",
      stage: "cleanup-custom-profile",
    },
  );
  if (profile.status === 2) return "archived";
  await api(`/api/workspace-access/profiles/${profileId}/archive`, {
    method: "POST",
    tenantId: workspaceId,
    accessToken: ownerAccessToken,
    data: { expectedVersion: profile.version },
    expectedStatus: 204,
    responseType: "body",
    stage: "cleanup-custom-profile",
  });
  return "archived";
}

async function openWorkspaceTab(context, page, tabName, expectedHeading) {
  await navigateToPublicPage(context, page, "/workspace", `workspace-access-${tabName.toLowerCase()}-navigation`);
  await page.getByRole("heading", { name: context.workspaceName, exact: true }).waitFor({
    timeout: context.configuration.convergenceTimeoutMilliseconds,
  });
  const tab = page.getByRole("tab", { name: tabName, exact: true });
  await tab.click();
  await page.getByRole("heading", { name: expectedHeading, exact: true }).waitFor({
    timeout: context.configuration.convergenceTimeoutMilliseconds,
  });
}

async function checkPermission(dialog, label) {
  const checkbox = dialog.getByRole("checkbox", {
    name: new RegExp(`^${escapeRegularExpression(label)}\\b`),
  });
  await checkbox.waitFor();
  if (!(await checkbox.isChecked())) await checkbox.check();
}

async function assignMemberRole(context, roleName, expectedProfileId, propertyName) {
  await openWorkspaceTab(context, context.ownerPage, "Members", "Workspace members");
  const dialog = await openOnlyMemberAccessEditor(context);
  const picker = dialog.getByRole("combobox", { name: "Role", exact: true });
  await picker.click();
  await context.ownerPage.getByRole("option", {
    name: new RegExp(`^${escapeRegularExpression(roleName)}\\b`),
  }).click();
  const property = dialog.getByRole("checkbox", {
    name: new RegExp(`^${escapeRegularExpression(propertyName)}\\b`),
  });
  if (await property.count() === 0) {
    await dialog.getByRole("button", { name: /^Selected properties\b/ }).click();
  }
  await property.waitFor({ timeout: context.configuration.requestTimeoutMilliseconds });
  if (!(await property.isChecked())) await property.check();
  const checkedPropertyNames = await dialog.getByRole("checkbox").evaluateAll((items) =>
    items.filter((item) => item.checked).map((item) => item.getAttribute("aria-label") ?? ""),
  );
  if (checkedPropertyNames.length !== 1) {
    fail("WorkspaceAccess.PropertyScopeAmbiguous", "workspace-access-member-assignment");
  }
  const response = await waitForBrowserJsonResponseMatching(
    context,
    context.ownerPage,
    (candidate) => {
      const url = new URL(candidate.url());
      return url.origin === context.configuration.publicOrigin.origin &&
        url.pathname.startsWith("/api/workspace-access/members/") &&
        url.pathname.endsWith("/access") &&
        candidate.request().method() === "PUT";
    },
    200,
    () => dialog.getByRole("button", { name: "Save access", exact: true }).click(),
    "workspace-access-member-assignment",
  );
  if (expectedProfileId && response.assignments?.[0]?.profileId !== expectedProfileId) {
    fail("WorkspaceAccess.ProfileSelectionMismatch", "workspace-access-member-assignment");
  }
  return response;
}

async function waitForDeniedProfileMutation(context, profile, roleName, roleDescription) {
  await pollUntil(
    () => context.api(`/api/workspace-access/profiles/${profile.profileId}`, {
      method: "PUT",
      tenantId: context.workspaceId,
      accessToken: context.memberAccessToken,
      data: {
        displayName: roleName,
        description: roleDescription,
        permissions: [PROPERTIES_READ, RESERVATIONS_READ],
        expectedVersion: profile.version,
      },
      expectedStatus: [403, 429],
      responseType: "body",
      stage: "workspace-access-self-escalation-denied",
    }),
    (response) => response.status === 403,
    {
      timeoutMilliseconds: context.configuration.convergenceTimeoutMilliseconds,
      pollIntervalMilliseconds: context.configuration.pollIntervalMilliseconds,
      code: "WorkspaceAccess.SelfEscalationDenialTimeout",
      stage: "workspace-access-self-escalation-denied",
    },
  );
}

async function openOnlyMemberAccessEditor(context) {
  const manageButtons = context.ownerPage.getByRole("button", { name: "Manage access", exact: true });
  await manageButtons.first().waitFor({ timeout: context.configuration.convergenceTimeoutMilliseconds });
  if (await manageButtons.count() !== 1) {
    fail("WorkspaceAccess.MemberEditorAmbiguous", "workspace-access-member-assignment");
  }
  await manageButtons.click();
  const dialog = context.ownerPage.getByRole("dialog").filter({
    hasText: "Saving replaces this member's operational assignment exactly.",
  });
  await dialog.getByRole("combobox", { name: "Role", exact: true }).waitFor({
    timeout: context.configuration.convergenceTimeoutMilliseconds,
  });
  return dialog;
}

async function waitForEffectiveAccess(context, reservationsAllowed) {
  const tenantScope = `tenant:${context.workspaceId}`;
  const allowedScope = `${tenantScope}/property:${context.allowedPropertyId}`;
  const deniedScope = `${tenantScope}/property:${context.deniedPropertyId}`;
  await pollUntil(
    () => context.api("/api/access/permissions/evaluate", {
      method: "POST",
      tenantId: context.workspaceId,
      accessToken: context.memberAccessToken,
      expectedStatus: [200, 429],
      data: {
        checks: [
          { permission: PROPERTIES_READ, scope: allowedScope },
          { permission: PROPERTIES_READ, scope: deniedScope },
          { permission: RESERVATIONS_READ, scope: allowedScope },
          { permission: RESERVATIONS_CREATE, scope: allowedScope },
          { permission: STAFF_MANAGE, scope: tenantScope },
          { permission: PROFILES_MANAGE, scope: tenantScope },
        ],
      },
      stage: "workspace-access-effective-permissions",
    }),
    (response) => response.status === 200 &&
      permissionMatches(response.body, PROPERTIES_READ, allowedScope, true) &&
      permissionMatches(response.body, PROPERTIES_READ, deniedScope, false) &&
      permissionMatches(response.body, RESERVATIONS_READ, allowedScope, reservationsAllowed) &&
      permissionMatches(response.body, RESERVATIONS_CREATE, allowedScope, false) &&
      permissionMatches(response.body, STAFF_MANAGE, tenantScope, false) &&
      permissionMatches(response.body, PROFILES_MANAGE, tenantScope, false),
    {
      timeoutMilliseconds: context.configuration.convergenceTimeoutMilliseconds,
      pollIntervalMilliseconds: context.configuration.pollIntervalMilliseconds,
      code: "WorkspaceAccess.PermissionConvergenceTimeout",
      stage: "workspace-access-effective-permissions",
    },
  );
  await context.api(`/api/properties/${context.allowedPropertyId}`, {
    tenantId: context.workspaceId,
    accessToken: context.memberAccessToken,
    stage: "workspace-access-allowed-property",
  });
  await context.api(`/api/properties/${context.deniedPropertyId}`, {
    tenantId: context.workspaceId,
    accessToken: context.memberAccessToken,
    expectedStatus: 403,
    responseType: "body",
    stage: "workspace-access-denied-property",
  });
}

async function assertMemberNavigation(context, reservationsVisible) {
  await reloadWithReleaseGuard(context, context.memberPage, "workspace-access-member-navigation");
  const navigation = context.memberPage.getByRole("navigation", { name: "Main navigation" });
  await navigation.getByRole("link", { name: "Properties", exact: true }).waitFor({
    timeout: context.configuration.convergenceTimeoutMilliseconds,
  });
  const reservations = navigation.getByRole("link", { name: "Reservations", exact: true });
  if (reservationsVisible) {
    await reservations.waitFor({ timeout: context.configuration.convergenceTimeoutMilliseconds });
  } else if (await reservations.count() !== 0) {
    fail("WorkspaceAccess.ReservationsNavigationOverexposed", "workspace-access-member-navigation");
  }
  if (await navigation.getByRole("link", { name: "Staff", exact: true }).count() !== 0) {
    fail("WorkspaceAccess.StaffNavigationOverexposed", "workspace-access-member-navigation");
  }
  await navigateToPublicPage(
    context,
    context.memberPage,
    "/workspace",
    "workspace-access-member-settings-navigation",
  );
  const rolesTab = context.memberPage.getByRole("tab", { name: "Roles", exact: true });
  await rolesTab.waitFor({ timeout: context.configuration.convergenceTimeoutMilliseconds });
  if (!(await rolesTab.isDisabled())) {
    fail("WorkspaceAccess.RoleAdministrationVisible", "workspace-access-member-settings-navigation");
  }
}

async function waitForProfileState(context, profileId, status, assignmentCount) {
  return pollUntil(
    () => findProfile(
      context.api,
      context.ownerAccessToken,
      context.workspaceId,
      profileId,
    ),
    (profile) => profile?.status === status && profile?.assignmentCount === assignmentCount,
    {
      timeoutMilliseconds: context.configuration.convergenceTimeoutMilliseconds,
      pollIntervalMilliseconds: context.configuration.pollIntervalMilliseconds,
      code: "WorkspaceAccess.ProfileStateTimeout",
      stage: "workspace-access-profile-state",
    },
  );
}

async function findProfile(api, accessToken, workspaceId, profileId) {
  for (let page = 1; page <= 100; page += 1) {
    const response = await api(
      `/api/workspace-access/profiles?includeArchived=true&page=${page}&pageSize=100`,
      {
        tenantId: workspaceId,
        accessToken,
        expectedStatus: [200, 429],
        stage: "workspace-access-find-profile",
      },
    );
    if (response.status === 429) return null;
    if (!Array.isArray(response.body?.items)) {
      fail("WorkspaceAccess.InvalidProfilePage", "workspace-access-find-profile");
    }
    const match = response.body.items.find((candidate) => candidate?.profileId === profileId);
    if (match) return match;
    if (response.body.hasMore !== true) {
      fail("WorkspaceAccess.ProfileMissing", "workspace-access-find-profile");
    }
  }
  fail("WorkspaceAccess.ProfilePaginationLimit", "workspace-access-find-profile");
}

async function oneRoleArticle(page, roleName, stage) {
  const article = page.locator("article").filter({
    has: page.getByRole("heading", { name: roleName, exact: true }),
  });
  await article.first().waitFor();
  if (await article.count() !== 1) {
    fail("WorkspaceAccess.RoleRowAmbiguous", stage);
  }
  return article;
}

function assertProfile(profile, expected, stage) {
  if (!isUuid(profile?.profileId) ||
      profile?.displayName !== expected.displayName ||
      profile?.status !== expected.status ||
      profile?.isSeed !== expected.isSeed ||
      !Number.isSafeInteger(profile?.version) || profile.version < 1 ||
      !sameStrings(profile?.permissions, expected.permissions)) {
    fail("WorkspaceAccess.ProfileReceiptMismatch", stage);
  }
}

function assertExactAssignment(payload, subjectId, profileId, propertyId, stage) {
  const assignment = payload?.assignments?.[0];
  if (payload?.subjectId !== subjectId ||
      !Array.isArray(payload?.assignments) || payload.assignments.length !== 1 ||
      assignment?.profileId !== profileId || assignment?.propertyId !== propertyId) {
    fail("WorkspaceAccess.AssignmentReceiptMismatch", stage);
  }
}

function permissionMatches(payload, permission, scope, allowed) {
  const matches = Array.isArray(payload?.permissions)
    ? payload.permissions.filter((candidate) =>
      candidate?.permission === permission && candidate?.scope === scope)
    : [];
  return matches.length === 1 && matches[0].allowed === allowed;
}

function sameStrings(actual, expected) {
  return Array.isArray(actual) &&
    actual.length === expected.length &&
    [...actual].sort().every((value, index) => value === [...expected].sort()[index]);
}

function isUuid(value) {
  return typeof value === "string" &&
    /^[0-9a-f]{8}-[0-9a-f]{4}-[1-5][0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$/i.test(value);
}

function escapeRegularExpression(value) {
  return value.replace(/[.*+?^${}()|[\]\\]/g, "\\$&");
}

async function navigateToPublicPage(context, page, path, stage) {
  const response = await page.goto(new URL(path, context.configuration.publicOrigin).toString(), {
    waitUntil: "domcontentloaded",
    timeout: context.configuration.requestTimeoutMilliseconds,
  });
  assertReleaseResponse(context, response, stage);
}

async function reloadWithReleaseGuard(context, page, stage) {
  const response = await page.reload({
    waitUntil: "domcontentloaded",
    timeout: context.configuration.requestTimeoutMilliseconds,
  });
  assertReleaseResponse(context, response, stage);
  await page.getByRole("navigation", { name: "Main navigation" }).waitFor({
    timeout: context.configuration.convergenceTimeoutMilliseconds,
  });
}

function assertReleaseResponse(context, response, stage) {
  if (!response || response.status() !== 200 ||
      response.headers()["x-bunkfy-release-id"] !== context.configuration.expectedReleaseId) {
    fail("WorkspaceAccess.BrowserReleaseMismatch", stage);
  }
}

async function waitForBrowserJsonResponse(context, page, path, method, status, action, stage) {
  const response = await waitForBrowserResponse(
    context,
    page,
    path,
    method,
    status,
    action,
    stage,
  );
  return readBoundedJson(response, 256 * 1024, "Browser.ResponseTooLarge", stage);
}

async function waitForBrowserResponse(context, page, path, method, status, action, stage) {
  const responsePromise = page.waitForResponse((candidate) => {
    const url = new URL(candidate.url());
    return url.origin === context.configuration.publicOrigin.origin &&
      url.pathname === path && candidate.request().method() === method;
  }, { timeout: context.configuration.convergenceTimeoutMilliseconds });
  await action();
  const response = await responsePromise;
  if (response.status() !== status) {
    fail(`Browser.UnexpectedStatus.${response.status()}`, stage);
  }
  return response;
}

async function waitForBrowserJsonResponseMatching(
  context,
  page,
  predicate,
  status,
  action,
  stage,
) {
  const responsePromise = page.waitForResponse(predicate, {
    timeout: context.configuration.convergenceTimeoutMilliseconds,
  });
  await action();
  const response = await responsePromise;
  if (response.status() !== status) {
    fail(`Browser.UnexpectedStatus.${response.status()}`, stage);
  }
  return readBoundedJson(response, 256 * 1024, "Browser.ResponseTooLarge", stage);
}
