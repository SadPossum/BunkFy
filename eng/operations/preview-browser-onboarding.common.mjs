import { createHash, randomUUID } from "node:crypto";
import { chmod, lstat, mkdir, rename, rm, writeFile } from "node:fs/promises";
import { dirname, resolve } from "node:path";
import { spawnSync } from "node:child_process";

const MAXIMUM_API_BYTES = 256 * 1024;
const MAXIMUM_MAILPIT_BYTES = 512 * 1024;
const RELEASE_ID_PATTERN = /^[a-z0-9][a-z0-9._-]{2,127}$/;
const VERIFICATION_CODE_PATTERN =
  /^\s*Use this one-time verification code:\s*([A-Za-z0-9+/=]{32,256})\s*$/gm;

export class ProofFailure extends Error {
  constructor(code, stage) {
    super(`${code} at ${stage}`);
    this.name = "ProofFailure";
    this.code = code;
    this.stage = stage;
  }
}

export function fail(code, stage) {
  throw new ProofFailure(code, stage);
}

export function requireEnvironment(name, environment = process.env) {
  const value = environment[name]?.trim();
  if (!value) fail("Configuration.Missing", name);
  return value;
}

export function optionalBooleanEnvironment(name, fallback, environment = process.env) {
  const value = environment[name]?.trim().toLowerCase();
  if (!value) return fallback;
  if (value === "true") return true;
  if (value === "false") return false;
  fail("Configuration.InvalidBoolean", name);
}

export function optionalIntegerEnvironment(
  name,
  fallback,
  minimum,
  maximum,
  environment = process.env,
) {
  const raw = environment[name]?.trim();
  if (!raw) return fallback;
  if (!/^[0-9]+$/.test(raw)) fail("Configuration.InvalidInteger", name);
  const value = Number(raw);
  if (!Number.isSafeInteger(value) || value < minimum || value > maximum) {
    fail("Configuration.IntegerOutOfRange", name);
  }
  return value;
}

export function parsePublicOrigin(value, allowLoopbackHttp = false) {
  let origin;
  try {
    origin = new URL(value);
  } catch {
    fail("Configuration.InvalidPublicOrigin", "configuration");
  }
  const loopback = origin.hostname === "localhost" ||
    origin.hostname === "127.0.0.1" ||
    origin.hostname === "[::1]";
  if (origin.username || origin.password || origin.search || origin.hash ||
      (origin.pathname !== "/" && origin.pathname !== "")) {
    fail("Configuration.InvalidPublicOrigin", "configuration");
  }
  if (origin.protocol !== "https:" &&
      !(allowLoopbackHttp && loopback && origin.protocol === "http:")) {
    fail("Configuration.InsecurePublicOrigin", "configuration");
  }
  return new URL(`${origin.protocol}//${origin.host}/`);
}

export function parseMailpitOrigin(value) {
  let origin;
  try {
    origin = new URL(value);
  } catch {
    fail("Configuration.InvalidMailpitOrigin", "configuration");
  }
  if (origin.protocol !== "http:" || origin.hostname !== "127.0.0.1" ||
      !origin.port || origin.pathname !== "/" || origin.search || origin.hash ||
      origin.username || origin.password) {
    fail("Configuration.InvalidMailpitOrigin", "configuration");
  }
  return origin;
}

export function parseReleaseId(value) {
  if (!RELEASE_ID_PATTERN.test(value)) {
    fail("Configuration.InvalidReleaseId", "configuration");
  }
  return value;
}

export async function assertRegularFile(path, stage = "configuration") {
  const absolute = resolve(path);
  let entry;
  try {
    entry = await lstat(absolute);
  } catch {
    fail("Configuration.FileMissing", stage);
  }
  if (!entry.isFile() || entry.isSymbolicLink()) {
    fail("Configuration.FileUnsafe", stage);
  }
  return absolute;
}

export function fingerprint(value) {
  return createHash("sha256").update(value.trim().toLowerCase(), "utf8").digest("hex");
}

export function newSyntheticIdentity(role, batchId) {
  const suffix = randomUUID().replaceAll("-", "").slice(0, 12);
  const email = `bunkfy-preview-browser-${role}-${batchId}-${suffix}@example.test`;
  return {
    role,
    email,
    fingerprintSha256: fingerprint(email),
    password: `Bf9!${randomUUID().replaceAll("-", "")}${randomUUID().replaceAll("-", "")}`,
    accessToken: null,
    capturedMessageCount: 0,
  };
}

export async function readBoundedJson(response, maximumBytes, code, stage) {
  const declared = Number(response.headers()["content-length"] ?? "0");
  if (Number.isFinite(declared) && declared > maximumBytes) fail(code, stage);
  const body = await response.body();
  if (body.length > maximumBytes) fail(code, stage);
  if (body.length === 0) return null;
  try {
    return JSON.parse(body.toString("utf8"));
  } catch {
    fail("Response.InvalidJson", stage);
  }
}

export async function readBoundedBody(response, maximumBytes, code, stage) {
  const declared = Number(response.headers()["content-length"] ?? "0");
  if (Number.isFinite(declared) && declared > maximumBytes) fail(code, stage);
  const body = await response.body();
  if (body.length > maximumBytes) fail(code, stage);
  return body;
}

export function createApiClient(context, origin, requestTimeoutMilliseconds) {
  return async function invoke(path, {
    method = "GET",
    tenantId = "global",
    accessToken = null,
    data = undefined,
    expectedStatus = 200,
    responseType = "json",
    stage = "api-request",
  } = {}) {
    const headers = {
      Accept: "application/json",
      "X-Tenant-Id": tenantId,
    };
    if (accessToken) headers.Authorization = `Bearer ${accessToken}`;
    const response = await context.fetch(new URL(path, origin).toString(), {
      method,
      headers,
      data,
      failOnStatusCode: false,
      maxRedirects: 0,
      timeout: requestTimeoutMilliseconds,
    });
    const acceptedStatuses = Array.isArray(expectedStatus)
      ? expectedStatus
      : [expectedStatus];
    if (!acceptedStatuses.includes(response.status())) {
      fail(`Api.UnexpectedStatus.${response.status()}`, stage);
    }
    const body = responseType === "json"
      ? await readBoundedJson(response, MAXIMUM_API_BYTES, "Api.ResponseTooLarge", stage)
      : await readBoundedBody(response, MAXIMUM_API_BYTES, "Api.ResponseTooLarge", stage);
    return {
      status: response.status(),
      headers: response.headers(),
      body,
    };
  };
}

export async function assertReleaseIdentity(api, expectedReleaseId, stage) {
  const root = await api("/", {
    responseType: "body",
    stage: `${stage}-web-root`,
  });
  const webReleaseId = root.headers["x-bunkfy-release-id"];
  if (webReleaseId !== expectedReleaseId) fail("Release.WebMismatch", stage);

  const smoke = await api("/api/smoke", { stage: `${stage}-api-smoke` });
  const payload = smoke.body;
  if (!payload || payload.application !== "BunkFy" ||
      payload.service !== "BunkFy.Host.Api" || payload.status !== "ok" ||
      payload.releaseId !== expectedReleaseId) {
    fail("Release.ApiMismatch", stage);
  }
  return expectedReleaseId;
}

export async function waitForVerificationCode(
  mailpitContext,
  mailpitOrigin,
  recipient,
  convergenceTimeoutMilliseconds,
  pollIntervalMilliseconds,
) {
  const deadline = Date.now() + convergenceTimeoutMilliseconds;
  while (Date.now() < deadline) {
    const listResponse = await mailpitContext.get(
      new URL("/api/v1/messages?limit=100", mailpitOrigin).toString(),
      { failOnStatusCode: false, timeout: Math.min(15_000, convergenceTimeoutMilliseconds) },
    );
    if (listResponse.status() !== 200) fail("Mailpit.ListUnavailable", "email-verification");
    const list = await readBoundedJson(
      listResponse,
      MAXIMUM_MAILPIT_BYTES,
      "Mailpit.ResponseTooLarge",
      "email-verification",
    );
    if (!list || !Array.isArray(list.messages)) {
      fail("Mailpit.InvalidMessageList", "email-verification");
    }
    const messages = list.messages.filter((message) =>
      typeof message?.ID === "string" &&
      Array.isArray(message?.To) &&
      message.To.some((target) =>
        typeof target?.Address === "string" &&
        target.Address.toLowerCase() === recipient.toLowerCase()),
    );
    for (const message of messages) {
      const detailResponse = await mailpitContext.get(
        new URL(`/api/v1/message/${encodeURIComponent(message.ID)}`, mailpitOrigin).toString(),
        { failOnStatusCode: false, timeout: Math.min(15_000, convergenceTimeoutMilliseconds) },
      );
      if (detailResponse.status() !== 200) continue;
      const detail = await readBoundedJson(
        detailResponse,
        MAXIMUM_MAILPIT_BYTES,
        "Mailpit.ResponseTooLarge",
        "email-verification",
      );
      if (typeof detail?.Text !== "string") continue;
      const matches = [...detail.Text.matchAll(VERIFICATION_CODE_PATTERN)];
      if (matches.length !== 1) continue;
      const code = matches[0][1];
      let decoded;
      try {
        decoded = Buffer.from(code, "base64");
      } catch {
        continue;
      }
      if (decoded.length < 32 || decoded.length > 128 ||
          decoded.toString("base64").replace(/=+$/, "") !== code.replace(/=+$/, "")) {
        decoded.fill(0);
        continue;
      }
      decoded.fill(0);
      return { code, capturedMessageCount: messages.length };
    }
    await delay(pollIntervalMilliseconds);
  }
  fail("Mailpit.VerificationCodeTimeout", "email-verification");
}

export async function pollUntil(action, predicate, {
  timeoutMilliseconds,
  pollIntervalMilliseconds,
  code,
  stage,
}) {
  const deadline = Date.now() + timeoutMilliseconds;
  let last;
  while (Date.now() < deadline) {
    last = await action();
    if (await predicate(last)) return last;
    await delay(pollIntervalMilliseconds);
  }
  fail(code, stage);
}

export function runCompose(composePath, environmentPath, args, stage) {
  const result = spawnSync(
    "docker",
    ["compose", "--env-file", environmentPath, "-f", composePath, ...args],
    { encoding: "utf8", maxBuffer: 1024 * 1024 },
  );
  if (result.status !== 0) fail("Compose.CommandFailed", stage);
  return result.stdout.trim();
}

export function assertPreviewCompose(composePath, environmentPath, expectedProjectName) {
  const output = runCompose(
    composePath,
    environmentPath,
    ["config", "--format", "json"],
    "worker-control-preflight",
  );
  let configuration;
  try {
    configuration = JSON.parse(output);
  } catch {
    fail("Compose.InvalidConfiguration", "worker-control-preflight");
  }
  if (configuration?.name !== expectedProjectName || !configuration?.services?.worker ||
      Object.hasOwn(configuration.services.worker, "ports")) {
    fail("Compose.UnexpectedPreviewTopology", "worker-control-preflight");
  }
}

export function stopPreviewWorker(composePath, environmentPath) {
  runCompose(
    composePath,
    environmentPath,
    ["stop", "--timeout", "30", "worker"],
    "worker-stop",
  );
  const running = runCompose(
    composePath,
    environmentPath,
    ["ps", "--status", "running", "--quiet", "worker"],
    "worker-stop-verification",
  );
  if (running) fail("Worker.StopDidNotConverge", "worker-stop-verification");
}

export function isVerifiedServiceState(status) {
  return status === "healthy" || status === "running";
}

export async function startPreviewWorker(
  composePath,
  environmentPath,
  convergenceTimeoutMilliseconds,
  pollIntervalMilliseconds,
) {
  runCompose(
    composePath,
    environmentPath,
    ["up", "--detach", "--no-deps", "--no-build", "worker"],
    "worker-start",
  );
  return pollUntil(
    () => {
      const containerId = runCompose(
        composePath,
        environmentPath,
        ["ps", "--status", "running", "--quiet", "worker"],
        "worker-health",
      );
      if (!/^[0-9a-f]{12,64}$/.test(containerId)) return null;
      const inspection = spawnSync(
        "docker",
        ["inspect", "--format", "{{if .State.Health}}{{.State.Health.Status}}{{else}}{{.State.Status}}{{end}}", containerId],
        { encoding: "utf8", maxBuffer: 64 * 1024 },
      );
      return inspection.status === 0 ? inspection.stdout.trim() : null;
    },
    // The Preview Worker is a background process and intentionally has no
    // HTTP healthcheck. Docker's format expression returns the health status
    // when one exists and falls back to the container state otherwise.
    isVerifiedServiceState,
    {
      timeoutMilliseconds: convergenceTimeoutMilliseconds,
      pollIntervalMilliseconds,
      code: "Worker.HealthTimeout",
      stage: "worker-health",
    },
  );
}

export async function writeEvidence(path, evidence, force) {
  const absolute = resolve(path);
  const parent = dirname(absolute);
  await mkdir(parent, { recursive: true, mode: 0o700 });
  const existing = await lstat(absolute).catch(() => null);
  if (existing && (!existing.isFile() || existing.isSymbolicLink())) {
    fail("Evidence.PathUnsafe", "evidence-write");
  }
  if (existing && !force) fail("Evidence.AlreadyExists", "evidence-write");
  const temporary = `${absolute}.${randomUUID().replaceAll("-", "")}.tmp`;
  try {
    await writeFile(temporary, `${JSON.stringify(evidence, null, 2)}\n`, {
      encoding: "utf8",
      mode: 0o600,
      flag: "wx",
    });
    await chmod(temporary, 0o600);
    if (existing && force) await rm(absolute, { force: true });
    await rename(temporary, absolute);
    await chmod(absolute, 0o600);
  } finally {
    await rm(temporary, { force: true }).catch(() => {});
  }
  return absolute;
}

export function sanitizedFailure(error, fallbackStage) {
  if (error instanceof ProofFailure) {
    return { code: error.code, stage: error.stage };
  }
  if (error?.name === "TimeoutError") {
    return { code: "Browser.Timeout", stage: fallbackStage };
  }
  return { code: "BrowserRehearsal.UnexpectedFailure", stage: fallbackStage };
}

export function delay(milliseconds) {
  return new Promise((resolveDelay) => setTimeout(resolveDelay, milliseconds));
}
