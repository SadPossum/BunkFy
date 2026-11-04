// Real compiled UI, HTTP APIs and Worker. No endpoint mocks or seeded authority.
import assert from 'node:assert/strict';
import { createRequire } from 'node:module';
import { createHmac, randomUUID } from 'node:crypto';
import { readFileSync, writeFileSync, statSync, lstatSync } from 'node:fs';
import { join } from 'node:path';
import { pathToFileURL } from 'node:url';
import { assertExpectedUiStatus, bookingReceiptObservation, safeBusinessFailure } from './business-canary.contracts.mjs';

const root = process.env.CANDIDATE_ROOT;
const origin = new URL(process.env.CANDIDATE_PROBE_PUBLIC_ORIGIN);
assert(origin.protocol === 'http:' && origin.hostname === '127.0.0.1' && Number(origin.port) >= 1024);
const statePath = process.env.CANDIDATE_CANARY_PRIVATE_STATE;
const evidencePath = process.env.CANDIDATE_CANARY_EVIDENCE;
const mode = process.argv[2];
assert(['create', 'restore'].includes(mode));
const require = createRequire(join(root, 'apps/web/package.json'));
const { chromium, request, expect } = require('@playwright/test');
const { createApiClient, waitForVerificationCode, assertReleaseIdentity, newSyntheticIdentity } =
  await import(pathToFileURL(join(root, 'eng/operations/preview-browser-onboarding.common.mjs')).href);
let stage = 'initialization', browser, context, page, setup, mail;
const checks = [];
const report = { schemaVersion: 1, mode, sourceCommit: process.env.CANDIDATE_SOURCE_COMMIT,
  result: 'failed', checks, scope: 'Synthetic real OCI UI/API/Worker and cold-recovery canary; no production or real-data approval.' };
const checked = (name) => checks.push({ name, result: 'passed' });
const same = (value, label) => value === label || String(value).toLowerCase() === String(label).toLowerCase();
const pause = (ms) => new Promise(resolve => setTimeout(resolve, ms));
async function until(action, predicate, label, timeout = 120000) {
  stage = label;
  const deadline = Date.now() + timeout;
  while (Date.now() < deadline) {
    const value = await action();
    if (predicate(value)) return value;
    await pause(1000);
  }
  throw new Error('Bounded convergence failed at ' + label);
}
function claims(token) { return JSON.parse(Buffer.from(token.split('.')[1], 'base64url').toString()); }
function totp(secret, offset = 0) {
  let bits = '';
  for (const letter of secret.replace(/[=\s]/g, '').toUpperCase()) {
    const digit = 'ABCDEFGHIJKLMNOPQRSTUVWXYZ234567'.indexOf(letter); assert(digit >= 0);
    bits += digit.toString(2).padStart(5, '0');
  }
  const key = Buffer.from((bits.match(/.{8}/g) || []).map(value => parseInt(value, 2)));
  const counter = Buffer.alloc(8); counter.writeBigUInt64BE(BigInt(Math.floor(Date.now() / 30000) + offset));
  const digest = createHmac('sha1', key).update(counter).digest(); key.fill(0);
  const index = digest[digest.length - 1] & 15;
  return ((digest.readUInt32BE(index) & 0x7fffffff) % 1000000).toString().padStart(6, '0');
}
async function nextTotp(state) {
  while (Math.floor(Date.now() / 30000) <= state.lastTotpStep) await pause(500);
  return totp(state.totpSecret);
}
async function responseFor(path, method, action, expected = [200, 201, 202]) {
  const pending = page.waitForResponse(r => new URL(r.url()).pathname.replace(/\/$/, '') === path
    && r.request().method() === method, { timeout: 90000 });
  void pending.catch(() => {});
  await action();
  const response = await pending;
  let problem;
  if (!expected.includes(response.status())) {
    try {
      const body = await response.body();
      if (body.length <= 16384) problem = JSON.parse(body.toString('utf8'));
    } catch { /* Unexpected responses still fail; no unreviewed content is retained. */ }
  }
  assertExpectedUiStatus(response.status(), expected, problem);
  return { status: response.status(), body: await response.json(), request: response.request().postDataJSON() };
}
async function signIn(state, mfa) {
  stage = 'actual-ui-sign-in';
  await page.goto(origin.href);
  await page.getByLabel('Email', { exact: true }).fill(state.owner.email);
  await page.locator('input[name="password"]').fill(state.owner.password);
  let login = await responseFor('/api/auth/browser/login', 'POST',
    () => page.getByRole('button', { name: 'Sign in', exact: true }).click(), [mfa ? 202 : 200]);
  if (mfa) {
    assert(typeof login.body.challengeToken === 'string');
    const validCodes = [-2, -1, 0, 1, 2].map(offset => totp(state.totpSecret, offset));
    const wrong = ['000000', '999999', '123456', '654321'].find(value => !validCodes.includes(value));
    const api = createApiClient(context.request, origin, 15000);
    await api('/api/auth/browser/mfa/challenges/complete', { method: 'POST',
      data: { challengeToken: login.body.challengeToken, codeType: 'totp', code: wrong },
      expectedStatus: [400, 401], stage: 'restored-wrong-totp-denied' });
    checked('restored-incorrect-authenticator-code-denied');
    await page.getByLabel('Authenticator code', { exact: true }).fill(await nextTotp(state));
    login = await responseFor('/api/auth/browser/mfa/challenges/complete', 'POST',
      () => page.getByRole('button', { name: 'Verify and sign in', exact: true }).click(), [200]);
    state.lastTotpStep = Math.floor(Date.now() / 30000);
    checked('restored-actual-ui-protected-totp-sign-in');
  }
  assert(typeof login.body.accessToken === 'string' && login.body.accessToken.length >= 32);
  await page.getByRole('navigation', { name: 'Main navigation' }).waitFor({ timeout: 120000 });
  const token = login.body.accessToken;
  if (state.ownerSubject) assert(claims(token).sub === state.ownerSubject);
  else state.ownerSubject = claims(token).sub;
  return token;
}
async function register(role) {
  const identity = newSyntheticIdentity(role, randomUUID().replaceAll('-', '').slice(0, 12));
  const isolated = await request.newContext();
  try {
    const api = createApiClient(isolated, origin, 15000);
    const registered = await api('/api/auth/browser/register', { method: 'POST', data: {
      username: identity.email, usernameType: 'email', password: identity.password }, stage: 'normal-registration' });
    identity.accessToken = registered.body.accessToken; assert(typeof identity.accessToken === 'string');
    const methods = (await api('/api/auth/methods', { accessToken: identity.accessToken })).body;
    const email = methods.emails.find(value => value.isActive && value.email === identity.email); assert(email);
    await api('/api/auth/email-verification', { method: 'POST', accessToken: identity.accessToken,
      data: { emailId: email.id }, expectedStatus: 202 });
    const capture = await waitForVerificationCode(mail, new URL(process.env.CANDIDATE_MAILPIT_ORIGIN),
      identity.email, 120000, 1000);
    try {
      await api('/api/auth/email-verification/confirm', { method: 'POST', accessToken: identity.accessToken,
        data: { code: capture.code }, expectedStatus: 204 });
    } finally { capture.code = null; }
    const name = 'OCI canary ' + role + ' ' + randomUUID().slice(0, 8);
    const organization = (await api('/api/organizations', { method: 'POST', accessToken: identity.accessToken,
      data: { operationId: randomUUID(), name, slug: 'oci-' + randomUUID() } })).body;
    identity.workspaceId = organization.organization.organizationId; identity.workspaceName = name;
    assert(organization.organization.status === 'active' && organization.membership.role === 'owner');
    await until(() => api('/api/staff/me', { accessToken: identity.accessToken, tenantId: identity.workspaceId,
      expectedStatus: [200, 404, 429] }), value => value.status === 200 && value.body.staffMemberId,
      'actual-owner-staff-projection');
    const created = (await api('/api/properties', { method: 'POST', accessToken: identity.accessToken,
      tenantId: identity.workspaceId, data: { operationId: randomUUID(), name: 'OCI property ' + role,
        code: 'Q' + randomUUID().replaceAll('-', '').slice(0, 10), timeZoneId: 'UTC' } })).body;
    identity.propertyId = created.propertyId; assert(identity.propertyId);
    await until(() => api('/api/properties/' + identity.propertyId, { accessToken: identity.accessToken,
      tenantId: identity.workspaceId, expectedStatus: [200, 404, 429] }),
      value => value.status === 200 && value.body.status === 'active', 'actual-preview-property-activation');
    return identity;
  } finally { await isolated.dispose(); }
}
try {
  setup = await request.newContext();
  mail = await request.newContext();
  await assertReleaseIdentity(createApiClient(setup, origin, 15000), process.env.CANDIDATE_PROBE_RELEASE_ID, 'release');
  checked('actual-web-and-api-release-binding');
  browser = await chromium.launch({ headless: true });
  context = await browser.newContext({ viewport: { width: 1440, height: 960 }, acceptDownloads: false });
  page = await context.newPage();
  if (mode === 'create') {
    const state = { owner: await register('canaryowner'), outsider: await register('canaryoutsider') };
    checked('normal-verified-identities-and-independent-owned-tenants');
    let token = await signIn(state, false);
    const api = createApiClient(context.request, origin, 15000);
    const own = (path, options = {}) => api(path, { accessToken: token, tenantId: state.owner.workspaceId, ...options });
    const property = (await own('/api/properties/' + state.owner.propertyId)).body;
    const roomName = 'OCI recoverable room';
    const room = (await own('/api/properties/' + state.owner.propertyId + '/rooms', { method: 'POST',
      data: { operationId: randomUUID(), name: roomName, buildingLabel: 'Synthetic demo', floorLabel: null,
        expectedPropertyVersion: property.version } })).body;
    state.roomId = room.roomId; assert(state.roomId);
    const directoryPath = '/api/inventory/properties/' + state.owner.propertyId + '/rooms';
    const projected = await until(() => own(directoryPath + '?page=1&pageSize=100'),
      value => value.body.rooms.some(item => item.roomId === state.roomId && item.units.length === 1),
      'actual-room-inventory-projection');
    const current = projected.body.rooms.find(item => item.roomId === state.roomId);
    await own(directoryPath + '/' + state.roomId + '/sales-mode', { method: 'PUT',
      data: { operationId: randomUUID(), salesMode: 2, expectedVersion: current.version } });
    await until(() => own(directoryPath + '?page=1&pageSize=100'), value => {
      const item = value.body.rooms.find(item => item.roomId === state.roomId);
      return item && (item.salesMode === 2 || same(item.salesMode, 'roomLevel'))
        && item.units.length === 1 && item.units[0].isSellable;
    }, 'actual-room-selling-projection');
    checked('actual-room-inventory-and-selling-projections');
    stage = 'actual-booking-workspace';
    await page.goto(new URL('/workspace', origin).href);
    await page.getByRole('heading', { name: state.owner.workspaceName, exact: true }).waitFor({ timeout: 120000 });
    await page.goto(new URL('/reservations', origin).href);
    stage = 'actual-booking-dialog';
    await page.getByRole('button', { name: 'New reservation', exact: true }).click();
    const dialog = page.getByRole('dialog');
    await dialog.getByRole('button', { name: 'Expand all', exact: true }).click();
    stage = 'actual-booking-room-choice';
    const choice = dialog.locator('section[aria-label="' + roomName + '"] input[type="checkbox"]');
    await expect(choice).toHaveCount(1); await choice.check();
    stage = 'actual-booking-guest-entry';
    await dialog.getByLabel('Primary guest', { exact: true }).fill('Synthetic recovery guest');
    await dialog.getByRole('checkbox', { name: /Save as a Guest Record/ }).check();
    await dialog.getByRole('button', { name: 'Continue', exact: true }).click();
    await dialog.getByLabel('Legal name (optional)', { exact: true }).fill('Synthetic recovery guest');
    const path = '/api/reservations/properties/' + state.owner.propertyId;
    stage = 'actual-booking-create-http-response';
    const created = await responseFor(path, 'POST',
      () => dialog.getByRole('button', { name: 'Create reservation', exact: true }).click());
    stage = 'actual-booking-receipt-operation-identity';
    report.bookingReceipt = bookingReceiptObservation(created.request, created.body);
    state.reservationId = created.body.reservationId; state.request = created.request;
    assert(state.reservationId === state.request.operationId);
    const reservation = await until(() => own(path + '/' + state.reservationId),
      value => (value.body.status === 2 || same(value.body.status, 'confirmed')) && value.body.guests.length === 1,
      'actual-worker-booking-and-guest-record');
    state.reservation = reservation.body; assert(state.reservation.holdsInventory === true);
    state.availabilityPath = '/api/inventory/properties/' + state.owner.propertyId + '/availability?arrival='
      + state.request.arrival + '&departure=' + state.request.departure;
    state.availability = (await own(state.availabilityPath)).body;
    assert(state.availability.units.some(item => item.unit.inventoryUnitId === state.request.inventoryUnitIds[0]
      && !item.isAvailable && item.activeAllocationIds.includes(state.reservation.allocationId)));
    checked('actual-compiled-ui-booking-guest-and-worker-allocation');
    assert((await own(path, { method: 'POST', data: state.request })).body.reservationId === state.reservationId);
    await own(path, { method: 'POST', data: { ...state.request, primaryGuestName: 'Rejected changed replay' }, expectedStatus: 409 });
    const conflict = (await own(path, { method: 'POST', data: { ...state.request, operationId: randomUUID() } })).body;
    const rejected = await until(() => own(path + '/' + conflict.reservationId),
      value => value.body.status === 3 || same(value.body.status, 'allocationRejected'), 'actual-double-booking-rejection');
    assert(!rejected.body.holdsInventory && !rejected.body.allocationId);
    assert.deepEqual((await own(path + '/' + state.reservationId)).body, state.reservation);
    checked('real-idempotence-conflicting-replay-and-double-booking-fences');
    await api('/api/properties/' + state.owner.propertyId, { accessToken: state.outsider.accessToken,
      tenantId: state.owner.workspaceId, expectedStatus: [403, 404] });
    await api('/api/properties/' + state.outsider.propertyId, { accessToken: token,
      tenantId: state.outsider.workspaceId, expectedStatus: [403, 404] });
    checked('two-existing-tenant-cross-owner-denials');
    stage = 'protected-totp-canary';
    const before = claims(token).sid;
    const enrollment = (await api('/api/auth/mfa/totp/enrollment', { method: 'POST', accessToken: token })).body;
    assert(typeof enrollment.secret === 'string'); state.totpSecret = enrollment.secret;
    const activation = (await api('/api/auth/browser/mfa/totp/activate', { method: 'POST', accessToken: token,
      data: { code: totp(state.totpSecret) } })).body;
    token = activation.accessToken; assert(claims(token).sid === before);
    state.lastTotpStep = Math.floor(Date.now() / 30000);
    checked('protected-authenticator-activation-retains-session-identity');
    writeFileSync(statePath, JSON.stringify(state), { flag: 'wx', mode: 0o600 });
  } else {
    assert(lstatSync(statePath).isFile() && !lstatSync(statePath).isSymbolicLink());
    if (process.platform !== 'win32') assert((statSync(statePath).mode & 0o077) === 0);
    const state = JSON.parse(readFileSync(statePath, 'utf8'));
    const token = await signIn(state, true);
    const api = createApiClient(context.request, origin, 15000);
    const own = path => api(path, { accessToken: token, tenantId: state.owner.workspaceId });
    const path = '/api/reservations/properties/' + state.owner.propertyId + '/' + state.reservationId;
    assert.deepEqual((await own(path)).body, state.reservation);
    assert.deepEqual((await own(state.availabilityPath)).body, state.availability);
    const outsider = await request.newContext();
    try {
      const otherApi = createApiClient(outsider, origin, 15000);
      const fresh = await otherApi('/api/auth/browser/login', { method: 'POST',
        data: { username: state.outsider.email, password: state.outsider.password } });
      await otherApi(path, { accessToken: fresh.body.accessToken, tenantId: state.owner.workspaceId,
        expectedStatus: [403, 404] });
    } finally { await outsider.dispose(); }
    await page.goto(new URL('/reservations', origin).href);
    await page.getByText('Synthetic recovery guest', { exact: true }).first().waitFor({ timeout: 120000 });
    checked('cold-restored-booking-guest-allocation-and-real-ui-visible');
    checked('cold-restored-existing-tenant-authorization-boundary');
  }
  report.result = 'passed';
} catch (error) {
  // No assertion values, credentials, response bodies, traces or screenshots.
  report.failure = safeBusinessFailure(stage, error); process.exitCode = 1;
} finally {
  for (const value of [context, setup, mail, browser]) {
    if (!value) continue;
    try { await (value.close?.() ?? value.dispose?.()); }
    catch { report.result = 'failed'; report.cleanupFailure = true; process.exitCode = 1; }
  }
  writeFileSync(evidencePath, JSON.stringify(report, null, 2) + '\n', { flag: 'wx', mode: 0o600 });
}
