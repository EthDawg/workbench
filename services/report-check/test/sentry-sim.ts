// In-memory stand-in for the parts of Sentry's API the verifier reads. No network.
import { createHash, randomBytes, randomUUID } from "node:crypto";

export const API_BASE = "https://us.sentry.test";
export const STORAGE_BASE = "https://objectstore.sentry.test";
export const TOKEN = "sntryu_synthetic_token_for_tests_only_0123456789";
const PROJECT_PATH = "/api/0/projects/workbench-dp/workbench-reports/events/";

export type Storage = "inline" | "cross-origin" | "same-origin";

export interface SimAttachment {
  id: string;
  name: string;
  bytes: Uint8Array<ArrayBuffer>;
  /** Size reported by the list endpoint; defaults to bytes.length. */
  listedSize?: number;
  /** Bytes served on download; defaults to `bytes`. */
  served?: Uint8Array<ArrayBuffer>;
  storage?: Storage;
  downloadStatus?: number;
  /** Error the download stream after this many bytes. */
  breakAfter?: number;
}

export interface SimEvent {
  eventID: string;
  tags: unknown;
  contexts: Record<string, unknown>;
  occurrence?: Record<string, unknown>;
}

export interface Seen {
  url: string;
  authorization: string | null;
}

type Override = (url: URL) => Response | Promise<Response> | undefined;

export class SentrySim {
  events = new Map<string, SimEvent>();
  attachments = new Map<string, SimAttachment[]>();
  pageSize = 100;
  seen: Seen[] = [];
  overrides: Override[] = [];
  nextId = 1000;

  fetch = async (input: string | URL | Request, init?: RequestInit): Promise<Response> => {
    const url = new URL(input instanceof Request ? input.url : input.toString());
    const headers = new Headers(init?.headers);
    this.seen.push({ url: url.toString(), authorization: headers.get("authorization") });
    if (init?.redirect !== "manual") throw new Error("verifier must handle redirects itself");
    for (const override of this.overrides) {
      const response = await override(url);
      if (response) return response;
    }
    if (url.origin === STORAGE_BASE) return this.storage(url);
    if (url.origin !== API_BASE) return new Response("unknown host", { status: 599 });
    if (headers.get("authorization") !== `Bearer ${TOKEN}`) return json(401, { detail: "Invalid token" });
    if (url.pathname.startsWith("/api/0/organizations/1/objectstore/")) return this.storage(url);
    if (!url.pathname.startsWith(PROJECT_PATH)) return json(404, { detail: "not found" });
    const rest = url.pathname.slice(PROJECT_PATH.length).split("/").filter(Boolean);
    const event = this.events.get(rest[0] ?? "");
    if (!event) return json(404, { detail: "Event not found" });
    if (rest.length === 1) return json(200, { id: event.eventID, ...event });
    if (rest[1] !== "attachments") return json(404, {});
    const all = this.attachments.get(rest[0]!) ?? [];
    if (rest.length === 2) return this.list(url, all);
    const attachment = all.find((item) => item.id === rest[2]);
    if (!attachment) return json(404, { detail: "Attachment not found" });
    if (!url.searchParams.has("download")) return json(200, serialize(rest[0]!, attachment));
    if (attachment.downloadStatus) return json(attachment.downloadStatus, {});
    if (attachment.storage === "cross-origin") {
      return redirect(`${STORAGE_BASE}/v1/objects/attachments/${attachment.id}?os_auth=presigned`);
    }
    if (attachment.storage === "same-origin") {
      return redirect(`${API_BASE}/api/0/organizations/1/objectstore/v1/objects/attachments/${attachment.id}?os_auth=presigned`);
    }
    return bytesResponse(attachment);
  };

  private list(url: URL, all: SimAttachment[]): Response {
    const sorted = [...all].sort((a, b) => a.name.localeCompare(b.name));
    const offset = Number(url.searchParams.get("cursor") ?? "0");
    const page = sorted.slice(offset, offset + this.pageSize);
    const eventId = url.pathname.split("/").at(-3)!;
    const more = offset + this.pageSize < sorted.length;
    const next = new URL(url);
    next.searchParams.set("cursor", String(offset + this.pageSize));
    const link = `<${url}>; rel="previous"; results="false"; cursor="0:0:1", <${next}>; rel="next"; results="${more}"; cursor="0:${offset + this.pageSize}:0"`;
    return json(200, page.map((item) => serialize(eventId, item)), { Link: link });
  }

  private storage(url: URL): Response {
    const id = url.pathname.split("/").at(-1)!;
    for (const list of this.attachments.values()) {
      const attachment = list.find((item) => item.id === id);
      if (attachment) return bytesResponse(attachment);
    }
    return new Response("missing", { status: 404 });
  }

  /** Store a report as Sentry would after processing the envelope. */
  store(report: Report, options: { storage?: Storage; tags?: unknown } = {}): SimAttachment[] {
    this.events.set(report.eventId, {
      eventID: report.eventId,
      tags: options.tags ?? [
        { key: "report_id", value: report.reportId },
        { key: "edition", value: "stable" },
        { key: "environment", value: "production" },
      ],
      contexts: { feedback: { message: report.message } },
    });
    const stored = [...report.files].map(([name, bytes]) => ({
      id: String(this.nextId++),
      name,
      bytes,
      storage: options.storage ?? "inline",
    }));
    this.attachments.set(report.eventId, stored);
    return stored;
  }
}

function serialize(eventId: string, item: SimAttachment) {
  return {
    id: item.id,
    event_id: eventId,
    type: "event.attachment",
    name: item.name,
    mimetype: "application/octet-stream",
    dateCreated: "2026-10-07T00:00:00Z",
    size: item.listedSize ?? item.bytes.length,
    headers: { "Content-Type": "application/octet-stream" },
    sha1: null,
  };
}

function bytesResponse(item: SimAttachment): Response {
  const bytes = item.served ?? item.bytes;
  if (item.breakAfter === undefined) return new Response(bytes, { status: 200 });
  const stream = new ReadableStream<Uint8Array>({
    start(controller) {
      controller.enqueue(bytes.slice(0, item.breakAfter));
      controller.error(new Error("connection reset"));
    },
  });
  return new Response(stream, { status: 200 });
}

export function json(status: number, body: unknown, headers: Record<string, string> = {}): Response {
  return new Response(JSON.stringify(body), { status, headers: { "Content-Type": "application/json", ...headers } });
}

function redirect(location: string): Response {
  return new Response(null, { status: 302, headers: { Location: location } });
}

export interface Report {
  eventId: string;
  reportId: string;
  message: string;
  files: Map<string, Uint8Array<ArrayBuffer>>;
}

export function sha256(bytes: Uint8Array): string {
  return createHash("sha256").update(bytes).digest("hex");
}

/** A synthetic report: manifest plus optional screenshot and voice bytes. */
export function makeReport(options: { screenshot?: boolean; voice?: boolean; message?: string } = {}): Report {
  const reportId = randomUUID();
  const eventId = randomUUID().replaceAll("-", "");
  const message = options.message ?? "Synthetic canary explanation 7f3a";
  const files = new Map<string, Uint8Array<ArrayBuffer>>();
  const attachments: unknown[] = [];
  const add = (name: string, bytes: Uint8Array<ArrayBuffer>, type: string) => {
    files.set(name, bytes);
    attachments.push({ name, content_type: type, bytes: bytes.length, sha256: sha256(bytes) });
  };
  const png = options.screenshot === false ? null : new Uint8Array(randomBytes(20_000));
  const wav = options.voice === false ? null : new Uint8Array(randomBytes(9_000));
  if (png) add("screenshot.png", png, "image/png");
  if (wav) add("voice.wav", wav, "audio/wav");
  const manifest = {
    schema_version: 1,
    report_id: reportId,
    created_at: "2026-10-07T00:00:00Z",
    explanation: message,
    build: { edition: "stable", version: "fixture", build: "1", revision: "unknown", dirty: null, kind: "release", os_version: "fixture", os_build: "fixture" },
    context: {},
    attachments,
  };
  const context = new TextEncoder().encode(JSON.stringify(manifest));
  const ordered = new Map<string, Uint8Array<ArrayBuffer>>([["context.json", context], ...files]);
  return { eventId, reportId, message, files: ordered };
}

export function requestBody(report: Report, eventId = report.eventId): Record<string, unknown> {
  return {
    event_id: eventId,
    report_id: report.reportId,
    attachments: [...report.files].map(([name, bytes]) => ({ name, size: bytes.length, sha256: sha256(bytes) })),
  };
}
