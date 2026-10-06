// Workbench report verifier.
//
// The Mac app sends each bug report straight to Sentry as one envelope: a feedback item
// plus `context.json` (the exact manifest bytes) and optional `screenshot.png` and
// `voice.wav` attachments. Sentry's 200 only means the envelope was accepted for
// processing. This stateless function reads the stored event back with a server-only
// token and answers whether the feedback event and every attachment arrived with the
// exact bytes, so the app can show "Received" truthfully.
//
// It never returns or logs report content, identifiers or credentials. It is
// self-contained (only `node:` imports) so Vercel and Node's type stripping run the same
// file without a build step.
import { createHash, randomBytes } from "node:crypto";

export const MAX_REQUEST_BYTES = 4096;
/** Fixed attachment names and their byte limits (docs/bug-reporting-schema.md). */
export const ATTACHMENT_LIMITS: Readonly<Record<string, number>> = Object.freeze({
  "context.json": 32 * 1024,
  "screenshot.png": 8 * 1024 * 1024,
  "voice.wav": 4 * 1024 * 1024,
});
const MAX_EVENT_JSON_BYTES = 2 * 1024 * 1024;
const MAX_LIST_JSON_BYTES = 512 * 1024;
const MAX_ATTACHMENT_PAGES = 5;
const MAX_REDIRECTS = 3;
/**
 * Sentry answers 404 until it has processed and indexed an envelope (live probe: 8-40 s),
 * and also when the envelope never arrived. While `elapsed_seconds` is under this window a
 * missing event or attachment is `pending`; afterwards it is `not_found`.
 */
export const PENDING_WINDOW_SECONDS = 15 * 60;
/** Upper bound for `elapsed_seconds`: one year. */
export const MAX_ELAPSED_SECONDS = 31_536_000;
/** Weak per-instance backstop; the real limit belongs in Vercel's firewall. */
export const DEFAULT_REQUESTS_PER_MINUTE = 20;
const LIMITER_MAX_CLIENTS = 10_000;
/** How long a missing project is remembered before checking again. */
const PROJECT_MISSING_RECHECK_MS = 60_000;

export type State = "received" | "pending" | "mismatch" | "not_found";

export interface Expected {
  name: string;
  size: number;
  sha256: string;
}

export interface VerifyRequest {
  /** 32 lowercase hex characters, the form Sentry uses in API paths. */
  eventId: string;
  /** Lowercase; the tag is compared case-insensitively. */
  reportId: string;
  attachments: Expected[];
  /** Seconds since the app received Sentry's 200 for its latest send of this event ID. */
  elapsedSeconds: number;
}

export interface Config {
  apiBase: URL;
  org: string;
  project: string;
  token: string;
}

/** Why the function cannot verify anything; logged, never returned. */
export interface ConfigProblem {
  problem: "token_missing" | "token_invalid" | "settings_invalid";
}

export interface Deps {
  fetch: typeof fetch;
  config: Config | ConfigProblem;
  now?: () => Date;
  /** Per client per minute on this instance. */
  requestsPerMinute?: number;
  /** Per upstream request; downloads get twice this. */
  requestTimeoutMs?: number;
  /** Whole verification. Keep below the function's maxDuration (vercel.json). */
  deadlineMs?: number;
  log?: (line: Record<string, unknown>) => void;
}

/** An upstream failure: never a verification result, always retryable by the caller. */
export class UpstreamError extends Error {
  readonly code: string;
  readonly retryAfter: number;
  constructor(code: string, retryAfter = 30) {
    super(code);
    this.code = code;
    this.retryAfter = Math.min(3600, Math.max(1, Math.round(retryAfter)));
  }
}

class InputError extends Error {}

// ---------------------------------------------------------------------------
// Configuration

const SLUG = /^[a-z0-9][a-z0-9_-]{0,63}$/;

export function readConfig(env: Record<string, string | undefined>): Config | ConfigProblem {
  // Pasted secrets often carry a trailing newline; surrounding whitespace is never part of a token.
  const token = (env.SENTRY_READ_TOKEN ?? "").trim();
  const org = env.SENTRY_ORG?.trim() || "workbench-dp";
  const project = env.SENTRY_PROJECT?.trim() || "workbench-reports";
  const base = env.SENTRY_API_BASE?.trim() || "https://us.sentry.io";
  if (!token) return { problem: "token_missing" };
  if (/[\s\x00-\x1f\x7f]/.test(token)) return { problem: "token_invalid" };
  if (!SLUG.test(org) || !SLUG.test(project)) return { problem: "settings_invalid" };
  let apiBase: URL;
  try {
    apiBase = new URL(base);
  } catch {
    return { problem: "settings_invalid" };
  }
  if (apiBase.protocol !== "https:" || apiBase.pathname !== "/" || apiBase.search || apiBase.username) {
    return { problem: "settings_invalid" };
  }
  return { apiBase, org, project, token };
}

// ---------------------------------------------------------------------------
// Strict request parsing

/** JSON.parse that also rejects duplicate keys, unpaired surrogates and deep nesting. */
export function parseStrictJson(text: string, maxDepth = 8): unknown {
  let i = 0;
  const fail = (): never => {
    throw new InputError("invalid_json");
  };
  const ws = () => {
    while (i < text.length && (text[i] === " " || text[i] === "\t" || text[i] === "\n" || text[i] === "\r")) i++;
  };
  const string = (): string => {
    const start = i;
    i++;
    for (;;) {
      if (i >= text.length) fail();
      const c = text.charCodeAt(i);
      if (c === 0x22) break;
      if (c < 0x20) fail();
      if (c === 0x5c) {
        i++;
        const e = text[i];
        if (e === "u") {
          if (!/^[0-9a-fA-F]{4}$/.test(text.slice(i + 1, i + 5))) fail();
          i += 5;
          continue;
        }
        if (e === undefined || !'"\\/bfnrt'.includes(e)) fail();
      }
      i++;
    }
    i++;
    const value = JSON.parse(text.slice(start, i)) as string;
    if (!value.isWellFormed()) fail();
    return value;
  };
  const value = (depth: number): unknown => {
    if (depth > maxDepth) fail();
    ws();
    const c = text[i];
    if (c === "{") {
      i++;
      const out: Record<string, unknown> = Object.create(null);
      const seen = new Set<string>();
      ws();
      if (text[i] === "}") {
        i++;
        return out;
      }
      for (;;) {
        ws();
        if (text[i] !== '"') fail();
        const key = string();
        if (seen.has(key)) fail();
        seen.add(key);
        ws();
        if (text[i] !== ":") fail();
        i++;
        out[key] = value(depth + 1);
        ws();
        if (text[i] === ",") {
          i++;
          continue;
        }
        if (text[i] === "}") {
          i++;
          return out;
        }
        fail();
      }
    }
    if (c === "[") {
      i++;
      const out: unknown[] = [];
      ws();
      if (text[i] === "]") {
        i++;
        return out;
      }
      for (;;) {
        out.push(value(depth + 1));
        ws();
        if (text[i] === ",") {
          i++;
          continue;
        }
        if (text[i] === "]") {
          i++;
          return out;
        }
        fail();
      }
    }
    if (c === '"') return string();
    const literal = /^(?:true|false|null|-?(?:0|[1-9]\d*)(?:\.\d+)?(?:[eE][+-]?\d+)?)/.exec(text.slice(i));
    if (!literal) fail();
    i += literal![0].length;
    return JSON.parse(literal![0]);
  };
  const result = value(0);
  ws();
  if (i !== text.length) fail();
  return result;
}

const UUID_V4 = /^[a-f0-9]{8}-[a-f0-9]{4}-4[a-f0-9]{3}-[89ab][a-f0-9]{3}-[a-f0-9]{12}$/;
const UUID_V4_ANY_CASE = /^[a-f0-9]{8}-[a-f0-9]{4}-4[a-f0-9]{3}-[89ab][a-f0-9]{3}-[a-f0-9]{12}$/i;
const HEX_V4 = /^[a-f0-9]{12}4[a-f0-9]{3}[89ab][a-f0-9]{15}$/;
const SHA256 = /^[a-f0-9]{64}$/;

function exactKeys(value: unknown, keys: string[]): Record<string, unknown> {
  if (typeof value !== "object" || value === null || Array.isArray(value)) throw new InputError("invalid_request");
  const record = value as Record<string, unknown>;
  const present = Object.keys(record);
  if (present.length !== keys.length || !keys.every((key) => Object.hasOwn(record, key))) {
    throw new InputError("invalid_request");
  }
  return record;
}

/** Validate the decoded body against the fixed request shape. */
export function validateRequest(value: unknown): VerifyRequest {
  const body = exactKeys(value, ["event_id", "report_id", "elapsed_seconds", "attachments"]);
  const eventInput = body.event_id;
  if (typeof eventInput !== "string") throw new InputError("invalid_request");
  const eventId = UUID_V4.test(eventInput) ? eventInput.replaceAll("-", "") : eventInput;
  if (!HEX_V4.test(eventId)) throw new InputError("invalid_request");
  const reportInput = body.report_id;
  if (typeof reportInput !== "string" || !UUID_V4_ANY_CASE.test(reportInput)) throw new InputError("invalid_request");
  const reportId = reportInput.toLowerCase();
  const elapsedSeconds = body.elapsed_seconds;
  if (
    typeof elapsedSeconds !== "number" || !Number.isSafeInteger(elapsedSeconds) ||
    elapsedSeconds < 0 || elapsedSeconds > MAX_ELAPSED_SECONDS
  ) {
    throw new InputError("invalid_request");
  }
  const list = body.attachments;
  if (!Array.isArray(list) || list.length < 1 || list.length > 3) throw new InputError("invalid_request");
  const attachments: Expected[] = [];
  const names = new Set<string>();
  for (const item of list) {
    const record = exactKeys(item, ["name", "size", "sha256"]);
    const { name, size, sha256 } = record;
    if (typeof name !== "string" || !Object.hasOwn(ATTACHMENT_LIMITS, name) || names.has(name)) {
      throw new InputError("invalid_request");
    }
    if (typeof size !== "number" || !Number.isSafeInteger(size) || size < 1 || size > ATTACHMENT_LIMITS[name]!) {
      throw new InputError("invalid_request");
    }
    if (typeof sha256 !== "string" || !SHA256.test(sha256)) throw new InputError("invalid_request");
    names.add(name);
    attachments.push({ name, size, sha256 });
  }
  if (!names.has("context.json")) throw new InputError("invalid_request");
  return { eventId, reportId, attachments, elapsedSeconds };
}

async function readBounded(stream: ReadableStream<Uint8Array> | null, limit: number): Promise<Uint8Array | null> {
  if (!stream) return new Uint8Array();
  const reader = stream.getReader();
  const parts: Uint8Array[] = [];
  let total = 0;
  for (;;) {
    const { done, value } = await reader.read();
    if (done) break;
    total += value.byteLength;
    if (total > limit) {
      await reader.cancel().catch(() => {});
      return null;
    }
    parts.push(value);
  }
  const out = new Uint8Array(total);
  let offset = 0;
  for (const part of parts) {
    out.set(part, offset);
    offset += part.byteLength;
  }
  return out;
}

// ---------------------------------------------------------------------------
// Sentry readback

interface Listed {
  id: string;
  name: string;
  size: number;
}

class Upstream {
  private readonly deps: Required<Pick<Deps, "fetch" | "requestTimeoutMs">>;
  private readonly config: Config;
  private readonly deadline: AbortSignal;
  calls = 0;

  constructor(deps: Required<Pick<Deps, "fetch" | "requestTimeoutMs">>, config: Config, deadline: AbortSignal) {
    this.deps = deps;
    this.config = config;
    this.deadline = deadline;
  }

  /** Whether the configured project exists; 404 means misconfiguration, not a report state. */
  async projectExists(): Promise<boolean> {
    const result = await this.json(this.projectUrl(""), MAX_LIST_JSON_BYTES);
    return result.status === 200;
  }

  projectUrl(path: string): URL {
    const { apiBase, org, project } = this.config;
    return new URL(`/api/0/projects/${org}/${project}/${path}`, apiBase);
  }

  /**
   * GET with manual redirects. The Authorization header goes only to the configured API
   * origin; storage redirects (pre-signed URLs) are followed without it. Never downgrades
   * from https.
   */
  async get(url: URL, timeoutMs: number, accept: string): Promise<Response> {
    let current = url;
    for (let hop = 0; hop <= MAX_REDIRECTS; hop++) {
      const headers: Record<string, string> = { Accept: accept, "Accept-Encoding": "identity" };
      if (current.origin === this.config.apiBase.origin) headers.Authorization = `Bearer ${this.config.token}`;
      this.calls++;
      let response: Response;
      try {
        response = await this.deps.fetch(current, {
          method: "GET",
          headers,
          redirect: "manual",
          signal: AbortSignal.any([this.deadline, AbortSignal.timeout(timeoutMs)]),
        });
      } catch {
        throw new UpstreamError("upstream_unreachable");
      }
      if (![301, 302, 303, 307, 308].includes(response.status)) return response;
      await response.body?.cancel().catch(() => {});
      const location = response.headers.get("location");
      let next: URL;
      try {
        next = new URL(location ?? "", current);
      } catch {
        throw new UpstreamError("upstream_bad_redirect");
      }
      if (!location || next.protocol !== "https:" || next.username || next.password) {
        throw new UpstreamError("upstream_bad_redirect");
      }
      current = next;
    }
    throw new UpstreamError("upstream_bad_redirect");
  }

  /** Map statuses that are never a verification result. */
  static failure(response: Response): UpstreamError {
    const status = response.status;
    if (status === 429) {
      const header = Number(response.headers.get("retry-after"));
      return new UpstreamError("upstream_rate_limited", Number.isFinite(header) && header > 0 ? header : 60);
    }
    if (status === 401 || status === 403) return new UpstreamError("upstream_unauthorized", 300);
    return new UpstreamError(`upstream_status_${status >= 500 ? "5xx" : status}`);
  }

  async json(url: URL, limit: number): Promise<{ status: number; body: unknown; link: string | null }> {
    const response = await this.get(url, this.deps.requestTimeoutMs, "application/json");
    if (response.status === 404) {
      await response.body?.cancel().catch(() => {});
      return { status: 404, body: null, link: null };
    }
    if (response.status !== 200) {
      await response.body?.cancel().catch(() => {});
      throw Upstream.failure(response);
    }
    let bytes: Uint8Array | null;
    try {
      bytes = await readBounded(response.body, limit);
    } catch {
      throw new UpstreamError("upstream_unreachable");
    }
    if (!bytes) throw new UpstreamError("upstream_oversized");
    try {
      return { status: 200, body: JSON.parse(new TextDecoder().decode(bytes)), link: response.headers.get("link") };
    } catch {
      throw new UpstreamError("upstream_invalid_json");
    }
  }

  /** Hash a download, reading at most `size + 1` bytes. */
  async digest(url: URL, size: number): Promise<{ kind: "hash"; sha256: string } | { kind: "missing" } | { kind: "oversize" }> {
    const response = await this.get(url, this.deps.requestTimeoutMs * 2, "*/*");
    if (response.status === 404) {
      await response.body?.cancel().catch(() => {});
      return { kind: "missing" };
    }
    if (response.status !== 200) {
      await response.body?.cancel().catch(() => {});
      throw Upstream.failure(response);
    }
    const hash = createHash("sha256");
    let total = 0;
    try {
      const reader = response.body?.getReader();
      if (reader) {
        for (;;) {
          const { done, value } = await reader.read();
          if (done) break;
          total += value.byteLength;
          if (total > size) {
            await reader.cancel().catch(() => {});
            return { kind: "oversize" };
          }
          hash.update(value);
        }
      }
    } catch {
      throw new UpstreamError("upstream_unreachable");
    }
    // A short body is an interrupted transfer, not evidence that the stored bytes differ.
    if (total < size) throw new UpstreamError("upstream_truncated");
    return { kind: "hash", sha256: hash.digest("hex") };
  }
}

/** Next page from Sentry's cursor `Link` header, only when it has results. */
export function nextPage(link: string | null): string | null {
  if (!link) return null;
  for (const part of link.split(/,(?=\s*<)/)) {
    const match = /^\s*<([^>]*)>(.*)$/.exec(part);
    if (!match) continue;
    const params = match[2]!;
    if (/;\s*rel="next"/.test(params) && /;\s*results="true"/.test(params)) return match[1]!;
  }
  return null;
}

function tagValue(event: Record<string, unknown>, key: string): string | null {
  const tags = event.tags;
  if (!Array.isArray(tags)) return null;
  for (const tag of tags) {
    if (Array.isArray(tag) && tag[0] === key && typeof tag[1] === "string") return tag[1];
    if (tag && typeof tag === "object" && (tag as Record<string, unknown>).key === key) {
      const value = (tag as Record<string, unknown>).value;
      return typeof value === "string" ? value : null;
    }
  }
  return null;
}

function isFeedback(event: Record<string, unknown>): boolean {
  const contexts = event.contexts as Record<string, unknown> | undefined;
  const feedback = contexts && typeof contexts === "object" ? contexts.feedback : undefined;
  if (feedback && typeof feedback === "object" && !Array.isArray(feedback)) return true;
  const occurrence = event.occurrence as Record<string, unknown> | undefined;
  return !!occurrence && typeof occurrence === "object" && occurrence.issueType === "feedback";
}

/**
 * Read the event and its attachments back and compare them with what the app sent.
 * Throws UpstreamError when Sentry cannot answer; that is never a verification result.
 */
export async function verifyReport(
  request: VerifyRequest,
  upstream: Upstream,
): Promise<{ state: State; reason: string }> {
  // Sentry answers 404 both before it has processed an envelope and when the envelope or an
  // attachment never arrived; only the time since the app's send tells them apart.
  const recent = request.elapsedSeconds < PENDING_WINDOW_SECONDS;
  const absent = (pendingReason: string, missingReason: string) =>
    recent ? { state: "pending" as const, reason: pendingReason } : { state: "not_found" as const, reason: missingReason };

  const eventUrl = upstream.projectUrl(`events/${request.eventId}/`);
  const event = await upstream.json(eventUrl, MAX_EVENT_JSON_BYTES);
  if (event.status === 404) return absent("event_processing", "event_not_found");
  if (!event.body || typeof event.body !== "object" || Array.isArray(event.body)) {
    throw new UpstreamError("upstream_invalid_json");
  }
  const record = event.body as Record<string, unknown>;
  const returnedId = typeof record.eventID === "string" ? record.eventID : record.id;
  if (typeof returnedId !== "string" || returnedId.replaceAll("-", "").toLowerCase() !== request.eventId) {
    return { state: "mismatch", reason: "event_id" };
  }
  if (!isFeedback(record)) return { state: "mismatch", reason: "not_feedback" };
  if (tagValue(record, "report_id")?.toLowerCase() !== request.reportId) return { state: "mismatch", reason: "report_id_tag" };

  const listed: Listed[] = [];
  let pageUrl: URL | null = upstream.projectUrl(`events/${request.eventId}/attachments/?per_page=100`);
  for (let page = 0; pageUrl; page++) {
    if (page >= MAX_ATTACHMENT_PAGES) throw new UpstreamError("upstream_too_many_pages");
    const result = await upstream.json(pageUrl, MAX_LIST_JSON_BYTES);
    // The event exists, so a 404 here means the list is unavailable, not that nothing arrived.
    if (result.status === 404) throw new UpstreamError("upstream_attachments_unavailable");
    if (!Array.isArray(result.body)) throw new UpstreamError("upstream_invalid_json");
    for (const item of result.body) {
      if (!item || typeof item !== "object") throw new UpstreamError("upstream_invalid_json");
      const { id, name, size } = item as Record<string, unknown>;
      if (typeof id !== "string" || !/^[0-9]{1,20}$/.test(id) || typeof name !== "string" || typeof size !== "number") {
        throw new UpstreamError("upstream_invalid_json");
      }
      listed.push({ id, name, size });
    }
    const next = nextPage(result.link);
    if (!next) break;
    let nextUrl: URL;
    try {
      nextUrl = new URL(next, pageUrl);
    } catch {
      throw new UpstreamError("upstream_bad_page");
    }
    // The cursor link carries our token, so it must stay on the API origin.
    if (nextUrl.origin !== upstream.projectUrl("").origin) throw new UpstreamError("upstream_bad_page");
    pageUrl = nextUrl;
  }

  const expected = new Map(request.attachments.map((item) => [item.name, item]));
  if (listed.some((item) => !expected.has(item.name))) return { state: "mismatch", reason: "unexpected_attachment" };
  // A resend within Sentry's one-hour dedupe stores the attachments again, so several
  // copies of a name are normal. Every copy must have the sent size; one copy is hashed.
  const chosen: Array<{ entry: Listed; want: Expected }> = [];
  for (const want of request.attachments) {
    const copies = listed.filter((entry) => entry.name === want.name);
    if (copies.length === 0) return absent("attachment_pending", "attachment_missing");
    if (copies.some((entry) => entry.size !== want.size)) return { state: "mismatch", reason: "attachment_size" };
    copies.sort((a, b) => (BigInt(a.id) < BigInt(b.id) ? -1 : 1));
    chosen.push({ entry: copies[0]!, want });
  }
  for (const { entry, want } of chosen) {
    const result = await upstream.digest(
      upstream.projectUrl(`events/${request.eventId}/attachments/${entry.id}/?download=1`),
      want.size,
    );
    if (result.kind === "missing") return absent("attachment_pending", "attachment_missing");
    if (result.kind === "oversize") return { state: "mismatch", reason: "attachment_size" };
    if (result.sha256 !== want.sha256) return { state: "mismatch", reason: "attachment_sha256" };
  }
  return { state: "received", reason: "verified" };
}

// ---------------------------------------------------------------------------
// HTTP

function reply(status: number, body: Record<string, unknown>, extra: Record<string, string> = {}): Response {
  return new Response(JSON.stringify(body), {
    status,
    headers: {
      "Content-Type": "application/json; charset=utf-8",
      "Cache-Control": "no-store",
      "X-Content-Type-Options": "nosniff",
      ...extra,
    },
  });
}

function defaultLog(line: Record<string, unknown>): void {
  console.log(JSON.stringify(line));
}

/**
 * Fixed one-minute window per client on this warm instance. Keys are salted hashes of the
 * client address, never the address itself, and are never logged. Instances do not share
 * counts, so this only blunts a single noisy client; Vercel's firewall is the real limit.
 */
export function createLimiter(perMinute: number, now: () => number) {
  const salt = randomBytes(16);
  const clients = new Map<string, { start: number; count: number }>();
  return (request: Request): number => {
    const forwarded = request.headers.get("x-forwarded-for")?.split(",")[0]?.trim();
    const address = request.headers.get("x-real-ip")?.trim() || forwarded || "unknown";
    const key = createHash("sha256").update(salt).update(address).digest("base64url");
    const at = now();
    if (clients.size >= LIMITER_MAX_CLIENTS) {
      for (const [client, window] of clients) if (at - window.start >= 60_000) clients.delete(client);
      if (clients.size >= LIMITER_MAX_CLIENTS) clients.clear();
    }
    let window = clients.get(key);
    if (!window || at - window.start >= 60_000) {
      window = { start: at, count: 0 };
      clients.set(key, window);
    }
    window.count++;
    return window.count > perMinute ? Math.max(1, Math.ceil((window.start + 60_000 - at) / 1000)) : 0;
  };
}

export function createHandler(deps: Deps): (request: Request) => Promise<Response> {
  const now = deps.now ?? (() => new Date());
  const log = deps.log ?? defaultLog;
  const requestTimeoutMs = deps.requestTimeoutMs ?? 8000;
  const deadlineMs = deps.deadlineMs ?? 25000;
  const limited = createLimiter(deps.requestsPerMinute ?? DEFAULT_REQUESTS_PER_MINUTE, () => now().getTime());
  // Checked once per warm instance; a missing project is re-checked after a minute.
  let project: { exists: boolean; at: number } | null = null;

  return async (request: Request): Promise<Response> => {
    const started = Date.now();
    const finish = (response: Response, fields: Record<string, unknown>) => {
      log({ msg: "verify", status: response.status, ms: Date.now() - started, ...fields });
      return response;
    };
    const retryAfter = limited(request);
    if (retryAfter) {
      await request.body?.cancel().catch(() => {});
      return finish(reply(429, { error: "rate_limited" }, { "Retry-After": String(retryAfter) }), { reason: "rate_limited" });
    }
    if (request.method !== "POST") {
      return finish(reply(405, { error: "method_not_allowed" }, { Allow: "POST" }), { reason: "method" });
    }
    const type = (request.headers.get("content-type") ?? "").split(";")[0]!.trim().toLowerCase();
    if (type !== "application/json") {
      return finish(reply(422, { error: "invalid_request" }), { reason: "content_type" });
    }
    const declared = request.headers.get("content-length");
    if (declared !== null && !(/^[0-9]+$/.test(declared) && Number(declared) <= MAX_REQUEST_BYTES)) {
      await request.body?.cancel().catch(() => {});
      return finish(reply(413, { error: "payload_too_large" }), { reason: "length" });
    }
    let parsed: VerifyRequest;
    try {
      const bytes = await readBounded(request.body, MAX_REQUEST_BYTES);
      if (!bytes) return finish(reply(413, { error: "payload_too_large" }), { reason: "length" });
      const text = new TextDecoder("utf-8", { fatal: true, ignoreBOM: true }).decode(bytes);
      parsed = validateRequest(parseStrictJson(text));
    } catch {
      return finish(reply(422, { error: "invalid_request" }), { reason: "body" });
    }
    const notConfigured = (reason: string, calls = 0) =>
      finish(reply(503, { error: "not_configured" }, { "Retry-After": "300" }), { reason, calls });
    if ("problem" in deps.config) return notConfigured(deps.config.problem);
    const upstream = new Upstream(
      { fetch: deps.fetch, requestTimeoutMs },
      deps.config,
      AbortSignal.timeout(deadlineMs),
    );
    try {
      const at = now().getTime();
      if (!project || (!project.exists && at - project.at >= PROJECT_MISSING_RECHECK_MS)) {
        project = { exists: await upstream.projectExists(), at };
      }
      if (!project.exists) return notConfigured("project_not_found", upstream.calls);
      const checkedAt = now();
      const { state, reason } = await verifyReport(parsed, upstream);
      return finish(reply(200, { state, checked_at: checkedAt.toISOString() }), { state, reason, calls: upstream.calls });
    } catch (error) {
      const failure = error instanceof UpstreamError ? error : new UpstreamError("internal_error");
      return finish(
        reply(503, { error: "upstream_unavailable", retry_after_seconds: failure.retryAfter }, {
          "Retry-After": String(failure.retryAfter),
        }),
        { reason: failure.code, calls: upstream.calls },
      );
    }
  };
}

const handler = createHandler({ fetch: (...args) => globalThis.fetch(...args), config: readConfig(process.env) });

export default {
  fetch(request: Request): Promise<Response> {
    return handler(request);
  },
};
