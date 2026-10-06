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
import { createHash } from "node:crypto";

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
const MAX_DOWNLOADS = 6;
const MAX_REDIRECTS = 3;
/**
 * Sentry answers 404 until it has processed and indexed an envelope (live probe: 8-40 s),
 * and also when the envelope never arrived. Inside this window after the app's own send
 * time a 404 is reported as `pending`; afterwards as `not_found`.
 */
export const PENDING_WINDOW_SECONDS = 15 * 60;

export type State = "received" | "pending" | "mismatch" | "not_found";

export interface Expected {
  name: string;
  size: number;
  sha256: string;
}

export interface VerifyRequest {
  /** 32 lowercase hex characters, the form Sentry uses in API paths. */
  eventId: string;
  reportId: string;
  attachments: Expected[];
  /** When the app received Sentry's 200 for this event, if it said. */
  sentAt: Date | null;
}

export interface Config {
  apiBase: URL;
  org: string;
  project: string;
  token: string;
}

export interface Deps {
  fetch: typeof fetch;
  config: Config | null;
  now?: () => Date;
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

export function readConfig(env: Record<string, string | undefined>): Config | null {
  const token = env.SENTRY_READ_TOKEN ?? "";
  const org = env.SENTRY_ORG || "workbench-dp";
  const project = env.SENTRY_PROJECT || "workbench-reports";
  const base = env.SENTRY_API_BASE || "https://us.sentry.io";
  if (!token || /\s/.test(token) || !SLUG.test(org) || !SLUG.test(project)) return null;
  let apiBase: URL;
  try {
    apiBase = new URL(base);
  } catch {
    return null;
  }
  if (apiBase.protocol !== "https:" || apiBase.pathname !== "/" || apiBase.search || apiBase.username) {
    return null;
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
const HEX_V4 = /^[a-f0-9]{12}4[a-f0-9]{3}[89ab][a-f0-9]{15}$/;
const SHA256 = /^[a-f0-9]{64}$/;

function exactKeys(value: unknown, keys: string[], optional: string[] = []): Record<string, unknown> {
  if (typeof value !== "object" || value === null || Array.isArray(value)) throw new InputError("invalid_request");
  const record = value as Record<string, unknown>;
  if (!keys.every((key) => Object.hasOwn(record, key))) throw new InputError("invalid_request");
  if (!Object.keys(record).every((key) => keys.includes(key) || optional.includes(key))) {
    throw new InputError("invalid_request");
  }
  return record;
}

const RFC3339 = /^(\d{4})-(\d{2})-(\d{2})[Tt](\d{2}):(\d{2}):(\d{2})(\.\d{1,9})?([Zz]|[+-]\d{2}:\d{2})$/;

/** Strict RFC 3339 date-time; rejects impossible dates instead of normalising them. */
export function parseTimestamp(value: unknown): Date {
  if (typeof value !== "string" || value.length > 40) throw new InputError("invalid_request");
  const match = RFC3339.exec(value);
  if (!match) throw new InputError("invalid_request");
  const [year, month, day, hour, minute, second] = match.slice(1, 7).map(Number) as [number, number, number, number, number, number];
  const calendar = new Date(Date.UTC(year, month - 1, day));
  if (
    calendar.getUTCFullYear() !== year || calendar.getUTCMonth() !== month - 1 || calendar.getUTCDate() !== day ||
    hour > 23 || minute > 59 || second > 60
  ) {
    throw new InputError("invalid_request");
  }
  const offset = match[8]!;
  if (offset.length === 6 && (Number(offset.slice(1, 3)) > 23 || Number(offset.slice(4)) > 59)) {
    throw new InputError("invalid_request");
  }
  const parsed = new Date(value.replace(/[tz]/g, (c) => c.toUpperCase()).replace(/:60(?=[.Zz+-])/, ":59"));
  if (Number.isNaN(parsed.getTime())) throw new InputError("invalid_request");
  return parsed;
}

/** Validate the decoded body against the fixed request shape. */
export function validateRequest(value: unknown): VerifyRequest {
  const body = exactKeys(value, ["event_id", "report_id", "attachments"], ["sent_at"]);
  const eventInput = body.event_id;
  if (typeof eventInput !== "string") throw new InputError("invalid_request");
  const eventId = UUID_V4.test(eventInput) ? eventInput.replaceAll("-", "") : eventInput;
  if (!HEX_V4.test(eventId)) throw new InputError("invalid_request");
  const reportId = body.report_id;
  if (typeof reportId !== "string" || !UUID_V4.test(reportId)) throw new InputError("invalid_request");
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
  const sentAt = Object.hasOwn(body, "sent_at") ? parseTimestamp(body.sent_at) : null;
  return { eventId, reportId, attachments, sentAt };
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
  now: Date,
): Promise<{ state: State; reason: string }> {
  const eventUrl = upstream.projectUrl(`events/${request.eventId}/`);
  const event = await upstream.json(eventUrl, MAX_EVENT_JSON_BYTES);
  // Sentry answers 404 both before the event is processed and when it never arrived; only
  // the app's send time tells them apart. A future send time (clock skew) counts as recent.
  if (event.status === 404) {
    const recent = request.sentAt !== null && now.getTime() - request.sentAt.getTime() < PENDING_WINDOW_SECONDS * 1000;
    return recent ? { state: "pending", reason: "event_processing" } : { state: "not_found", reason: "event_not_found" };
  }
  if (!event.body || typeof event.body !== "object" || Array.isArray(event.body)) {
    throw new UpstreamError("upstream_invalid_json");
  }
  const record = event.body as Record<string, unknown>;
  const returnedId = typeof record.eventID === "string" ? record.eventID : record.id;
  if (typeof returnedId !== "string" || returnedId.replaceAll("-", "").toLowerCase() !== request.eventId) {
    return { state: "mismatch", reason: "event_id" };
  }
  if (!isFeedback(record)) return { state: "mismatch", reason: "not_feedback" };
  if (tagValue(record, "report_id") !== request.reportId) return { state: "mismatch", reason: "report_id_tag" };

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
      if (typeof id !== "string" || !/^\d{1,20}$/.test(id) || typeof name !== "string" || typeof size !== "number") {
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
  for (const item of request.attachments) {
    const copies = listed.filter((entry) => entry.name === item.name);
    if (copies.length === 0) return { state: "pending", reason: "attachment_not_listed" };
    if (copies.some((entry) => entry.size !== item.size)) return { state: "mismatch", reason: "attachment_size" };
  }
  if (listed.length > MAX_DOWNLOADS) return { state: "mismatch", reason: "duplicate_attachments" };
  for (const entry of listed) {
    const want = expected.get(entry.name)!;
    const result = await upstream.digest(
      upstream.projectUrl(`events/${request.eventId}/attachments/${entry.id}/?download=1`),
      want.size,
    );
    if (result.kind === "missing") return { state: "pending", reason: "attachment_not_downloadable" };
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

export function createHandler(deps: Deps): (request: Request) => Promise<Response> {
  const now = deps.now ?? (() => new Date());
  const log = deps.log ?? defaultLog;
  const requestTimeoutMs = deps.requestTimeoutMs ?? 8000;
  const deadlineMs = deps.deadlineMs ?? 25000;

  return async (request: Request): Promise<Response> => {
    const started = Date.now();
    const finish = (response: Response, fields: Record<string, unknown>) => {
      log({ msg: "verify", status: response.status, ms: Date.now() - started, ...fields });
      return response;
    };
    if (request.method !== "POST") {
      return finish(reply(405, { error: "method_not_allowed" }, { Allow: "POST" }), { reason: "method" });
    }
    const type = (request.headers.get("content-type") ?? "").split(";")[0]!.trim().toLowerCase();
    if (type !== "application/json") {
      return finish(reply(422, { error: "invalid_request" }), { reason: "content_type" });
    }
    const declared = request.headers.get("content-length");
    if (declared !== null && !(/^\d+$/.test(declared) && Number(declared) <= MAX_REQUEST_BYTES)) {
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
    if (!deps.config) {
      return finish(reply(503, { error: "not_configured" }, { "Retry-After": "300" }), { reason: "config" });
    }
    const upstream = new Upstream(
      { fetch: deps.fetch, requestTimeoutMs },
      deps.config,
      AbortSignal.timeout(deadlineMs),
    );
    try {
      const checkedAt = now();
      const { state, reason } = await verifyReport(parsed, upstream, checkedAt);
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
