import assert from "node:assert/strict";
import { describe, it, mock } from "node:test";
import verifier, {
  ATTACHMENT_LIMITS,
  createHandler,
  nextPage,
  MAX_ELAPSED_SECONDS,
  parseStrictJson,
  PENDING_WINDOW_SECONDS,
  readConfig,
  type Config,
  type ConfigProblem,
} from "../api/v1/verify.ts";
import { API_BASE, STORAGE_BASE, SentrySim, TOKEN, json, makeReport, requestBody, sha256, type Report } from "./sentry-sim.ts";

const NOW = new Date("2026-10-07T01:00:00.000Z");
const config: Config = { apiBase: new URL(API_BASE), org: "workbench-dp", project: "workbench-reports", token: TOKEN };

function setup(
  options: {
    requestTimeoutMs?: number;
    deadlineMs?: number;
    config?: Config | ConfigProblem;
    requestsPerMinute?: number;
    now?: () => Date;
  } = {},
) {
  const sim = new SentrySim();
  const logs: Record<string, unknown>[] = [];
  const handler = createHandler({
    fetch: sim.fetch,
    config: options.config ?? config,
    now: options.now ?? (() => NOW),
    requestTimeoutMs: options.requestTimeoutMs ?? 2000,
    deadlineMs: options.deadlineMs ?? 5000,
    // The limiter has its own tests; elsewhere many requests share one synthetic client.
    requestsPerMinute: options.requestsPerMinute ?? 1000,
    log: (line) => logs.push(line),
  });
  const post = (body: unknown, init: { headers?: Record<string, string>; raw?: BodyInit; method?: string } = {}) =>
    handler(
      new Request("https://check.test/api/v1/verify", {
        method: init.method ?? "POST",
        headers: { "Content-Type": "application/json", ...init.headers },
        body: init.method === "GET" ? null : (init.raw ?? JSON.stringify(body)),
        duplex: "half",
      } as RequestInit),
    );
  return { sim, logs, post };
}

async function verdict(response: Response, at: Date = NOW): Promise<string> {
  assert.equal(response.status, 200, `status ${response.status}`);
  const body = (await response.json()) as Record<string, unknown>;
  assert.deepEqual(Object.keys(body).sort(), ["checked_at", "state"]);
  assert.equal(body.checked_at, at.toISOString());
  return body.state as string;
}

async function unavailable(response: Response): Promise<number> {
  assert.equal(response.status, 503);
  assert.equal(response.headers.get("cache-control"), "no-store");
  const body = (await response.json()) as Record<string, unknown>;
  assert.equal(body.error, "upstream_unavailable");
  assert.equal(String(body.retry_after_seconds), response.headers.get("retry-after"));
  return Number(response.headers.get("retry-after"));
}

function full(): Report {
  return makeReport({ screenshot: true, voice: true });
}

describe("verification results", () => {
  it("received: event, report tag and every attachment's bytes match", async () => {
    const { sim, post } = setup();
    const report = full();
    sim.store(report, { storage: "same-origin" });
    const response = await post(requestBody(report));
    assert.equal(response.headers.get("cache-control"), "no-store");
    assert.equal(await verdict(response), "received");
    const downloads = sim.seen.filter((seen) => seen.url.includes("download") || seen.url.includes("objectstore"));
    assert.equal(downloads.length, 6, "three downloads plus three same-origin redirects");
  });

  it("received for a text-only report (context.json alone)", async () => {
    const { sim, post } = setup();
    const report = makeReport({ screenshot: false, voice: false });
    sim.store(report);
    assert.equal(await verdict(await post(requestBody(report))), "received");
  });

  it("accepts a dashed event ID and queries Sentry with the 32-hex form", async () => {
    const { sim, post } = setup();
    const report = full();
    sim.store(report);
    const e = report.eventId;
    const dashed = `${e.slice(0, 8)}-${e.slice(8, 12)}-${e.slice(12, 16)}-${e.slice(16, 20)}-${e.slice(20)}`;
    assert.equal(await verdict(await post(requestBody(report, dashed))), "received");
    assert.ok(sim.seen.some((seen) => seen.url.endsWith(`/events/${e}/`)));
    assert.ok(!sim.seen.some((seen) => seen.url.includes(dashed)));
  });

  it("event not processed: pending inside the window, not_found from 900 s", async () => {
    const { post } = setup();
    const report = full();
    for (const [elapsed, state] of [[0, "pending"], [PENDING_WINDOW_SECONDS - 1, "pending"],
      [PENDING_WINDOW_SECONDS, "not_found"], [MAX_ELAPSED_SECONDS, "not_found"]] as const) {
      assert.equal(await verdict(await post(requestBody(report, report.eventId, elapsed))), state, `${elapsed}`);
    }
  });

  it("attachment not listed: pending inside the window, not_found (attachment_missing) after", async () => {
    const { sim, logs, post } = setup();
    const report = full();
    sim.store(report);
    sim.attachments.set(report.eventId, sim.attachments.get(report.eventId)!.filter((a) => a.name !== "voice.wav"));
    assert.equal(await verdict(await post(requestBody(report, report.eventId, 60))), "pending");
    assert.equal(logs.at(-1)!.reason, "attachment_pending");
    assert.equal(await verdict(await post(requestBody(report, report.eventId, PENDING_WINDOW_SECONDS))), "not_found");
    assert.equal(logs.at(-1)!.reason, "attachment_missing");
  });

  it("listed attachment not downloadable: pending inside the window, not_found after", async () => {
    const { sim, logs, post } = setup();
    const report = full();
    sim.store(report)[1]!.downloadStatus = 404;
    assert.equal(await verdict(await post(requestBody(report, report.eventId, 60))), "pending");
    assert.equal(await verdict(await post(requestBody(report, report.eventId, 3600))), "not_found");
    assert.equal(logs.at(-1)!.reason, "attachment_missing");
  });

  it("report_id compares case-insensitively on both sides", async () => {
    const { sim, post } = setup();
    const report = full();
    sim.store(report);
    assert.equal(await verdict(await post({ ...requestBody(report), report_id: report.reportId.toUpperCase() })), "received");
    sim.store(report, { tags: [{ key: "report_id", value: report.reportId.toUpperCase() }] });
    assert.equal(await verdict(await post(requestBody(report))), "received");
  });

  it("mismatch: listed size differs from the sent size", async () => {
    const { sim, post } = setup();
    const report = full();
    const stored = sim.store(report);
    stored[2]!.listedSize = stored[2]!.bytes.length - 1;
    assert.equal(await verdict(await post(requestBody(report))), "mismatch");
  });

  it("mismatch: downloaded bytes hash differently", async () => {
    const { sim, post } = setup();
    const report = full();
    const stored = sim.store(report);
    const altered = new Uint8Array(stored[1]!.bytes);
    altered[100] = altered[100]! ^ 0xff;
    stored[1]!.served = altered;
    assert.equal(await verdict(await post(requestBody(report))), "mismatch");
  });

  it("mismatch: download is longer than the listed size", async () => {
    const { sim, post } = setup();
    const report = full();
    const stored = sim.store(report);
    stored[0]!.served = new Uint8Array([...stored[0]!.bytes, 0x0a]);
    assert.equal(await verdict(await post(requestBody(report))), "mismatch");
  });

  it("mismatch: wrong, missing or malformed report_id tag", async () => {
    for (const tags of [
      [{ key: "report_id", value: makeReport().reportId }],
      [{ key: "edition", value: "stable" }],
      "report_id",
    ]) {
      const { sim, post } = setup();
      const report = full();
      sim.store(report, { tags });
      assert.equal(await verdict(await post(requestBody(report))), "mismatch");
    }
  });

  it("accepts the [key, value] tag form too", async () => {
    const { sim, post } = setup();
    const report = full();
    sim.store(report, { tags: [["report_id", report.reportId]] });
    assert.equal(await verdict(await post(requestBody(report))), "received");
  });

  it("mismatch: the event is not a feedback event", async () => {
    const { sim, post } = setup();
    const report = full();
    sim.store(report);
    sim.events.get(report.eventId)!.contexts = { os: { name: "macOS" } };
    assert.equal(await verdict(await post(requestBody(report))), "mismatch");
    // An issue-platform occurrence typed as feedback is accepted without the context.
    sim.events.get(report.eventId)!.occurrence = { issueType: "feedback" };
    assert.equal(await verdict(await post(requestBody(report))), "received");
  });

  it("mismatch: Sentry returns a different event ID", async () => {
    const { sim, post } = setup();
    const report = full();
    sim.store(report);
    sim.events.get(report.eventId)!.eventID = makeReport().eventId;
    assert.equal(await verdict(await post(requestBody(report))), "mismatch");
  });

  it("mismatch: an attachment the app did not send is on the event", async () => {
    const { sim, post } = setup();
    const report = full();
    sim.store(report);
    sim.attachments.get(report.eventId)!.push({ id: "9", name: "extra.txt", bytes: new Uint8Array([1]) });
    assert.equal(await verdict(await post(requestBody(report))), "mismatch");
  });

  it("repeated deliveries are received, hashing one copy per name", async () => {
    const { sim, post } = setup();
    const report = full();
    const stored = [...sim.store(report)];
    // Three extra deliveries of every attachment (resends inside Sentry's dedupe hour).
    for (let copy = 0; copy < 3; copy++) {
      stored.forEach((item, index) => {
        sim.attachments.get(report.eventId)!.push({ ...item, id: String(5000 + copy * 10 + index) });
      });
    }
    assert.equal(sim.attachments.get(report.eventId)!.length, 12);
    assert.equal(await verdict(await post(requestBody(report))), "received");
    const downloads = sim.seen.filter((seen) => seen.url.includes("download"));
    assert.equal(downloads.length, 3);
    // The lowest-numbered copy of each name is the one hashed.
    assert.deepEqual(downloads.map((seen) => seen.url.split("/attachments/")[1]!.split("/")[0]).sort(),
      stored.map((item) => item.id).sort());
  });

  it("a duplicate copy with a different size is a mismatch", async () => {
    const { sim, post } = setup();
    const report = full();
    const stored = sim.store(report);
    sim.attachments.get(report.eventId)!.push({ ...stored[1]!, id: "77", listedSize: stored[1]!.bytes.length + 5 });
    assert.equal(await verdict(await post(requestBody(report))), "mismatch");
  });

  it("follows attachment pagination", async () => {
    const { sim, post } = setup();
    const report = full();
    sim.store(report);
    sim.pageSize = 1;
    assert.equal(await verdict(await post(requestBody(report))), "received");
    const pages = sim.seen.filter((seen) => /\/attachments\/\?/.test(seen.url));
    assert.equal(pages.length, 3);
    assert.ok(pages.every((page) => page.authorization === `Bearer ${TOKEN}`));
  });

  it("refuses a pagination link to another origin (it would carry the token)", async () => {
    const { sim, post } = setup();
    const report = full();
    sim.store(report);
    sim.overrides.push((url) =>
      url.pathname.endsWith("/attachments/")
        ? json(200, [], { Link: `<https://evil.test/next>; rel="next"; results="true"; cursor="1"` })
        : undefined,
    );
    await unavailable(await post(requestBody(report)));
    assert.ok(!sim.seen.some((seen) => seen.url.startsWith("https://evil.test")));
  });
});

describe("redirects and credentials", () => {
  it("follows a storage redirect to another origin without the Authorization header", async () => {
    const { sim, post } = setup();
    const report = full();
    sim.store(report, { storage: "cross-origin" });
    assert.equal(await verdict(await post(requestBody(report))), "received");
    const storage = sim.seen.filter((seen) => seen.url.startsWith(STORAGE_BASE));
    assert.equal(storage.length, 3);
    assert.ok(storage.every((seen) => seen.authorization === null));
    const api = sim.seen.filter((seen) => seen.url.startsWith(API_BASE));
    assert.ok(api.every((seen) => seen.authorization === `Bearer ${TOKEN}`));
  });

  it("keeps Authorization on a same-origin redirect (Sentry's objectstore proxy)", async () => {
    const { sim, post } = setup();
    const report = full();
    sim.store(report, { storage: "same-origin" });
    assert.equal(await verdict(await post(requestBody(report))), "received");
    const proxied = sim.seen.filter((seen) => seen.url.includes("/objectstore/"));
    assert.equal(proxied.length, 3);
    assert.ok(proxied.every((seen) => seen.authorization === `Bearer ${TOKEN}`));
  });

  it("refuses an https-to-http redirect and redirect loops", async () => {
    for (const location of ["http://objectstore.sentry.test/x", `${API_BASE}/loop`]) {
      const { sim, post } = setup();
      const report = full();
      sim.store(report);
      sim.overrides.push((url) =>
        url.searchParams.has("download") || url.pathname === "/loop"
          ? new Response(null, { status: 302, headers: { Location: location } })
          : undefined,
      );
      await unavailable(await post(requestBody(report)));
      assert.ok(!sim.seen.some((seen) => seen.url.startsWith("http:")));
    }
  });
});

describe("upstream failures are never a result", () => {
  const cases: Array<[string, number, Record<string, string>]> = [
    ["unauthorized", 401, {}],
    ["forbidden (token user lacks attachment access)", 403, {}],
    ["rate limited", 429, { "Retry-After": "120" }],
    ["server error", 500, {}],
    ["bad gateway", 502, {}],
  ];
  for (const stage of ["project", "event", "list", "download"] as const) {
    for (const [label, status, headers] of cases) {
      it(`${stage}: ${label} → 503`, async () => {
        const { sim, post } = setup();
        const report = full();
        sim.store(report);
        sim.overrides.push((url) => {
          const isProject = url.pathname.endsWith("/workbench-reports/");
          const isList = url.pathname.endsWith("/attachments/");
          const isDownload = url.searchParams.has("download");
          const isEvent = url.pathname.endsWith(`/events/${report.eventId}/`);
          const hit = { project: isProject, event: isEvent, list: isList, download: isDownload }[stage];
          return hit ? json(status, { detail: "synthetic" }, headers) : undefined;
        });
        const retry = await unavailable(await post(requestBody(report)));
        if (status === 429) assert.equal(retry, 120);
      });
    }
  }

  it("network errors, invalid JSON and a missing attachment list → 503", async () => {
    for (const override of [
      () => Promise.reject(new TypeError("fetch failed")),
      (url: URL) => (url.pathname.endsWith("/attachments/") ? new Response("{oops", { status: 200 }) : undefined),
      (url: URL) => (url.pathname.endsWith("/attachments/") ? json(404, {}) : undefined),
    ]) {
      const { sim, post } = setup();
      const report = full();
      sim.store(report);
      sim.overrides.push(override as (url: URL) => Promise<Response> | Response | undefined);
      await unavailable(await post(requestBody(report)));
    }
  });

  it("an interrupted download is retried later, not judged", async () => {
    const { sim, post } = setup();
    const report = full();
    sim.store(report)[1]!.breakAfter = 100;
    await unavailable(await post(requestBody(report)));
    const { sim: sim2, post: post2 } = setup();
    sim2.store(report)[1]!.served = report.files.get("screenshot.png")!.slice(0, 10);
    await unavailable(await post2(requestBody(report)));
  });

  it("times out a hung upstream request", async () => {
    const hanging: typeof fetch = (_input, init) =>
      new Promise<Response>((_resolve, reject) => {
        init?.signal?.addEventListener("abort", () => reject(init.signal!.reason));
      });
    const handler = createHandler({ fetch: hanging, config, now: () => NOW, requestTimeoutMs: 50, deadlineMs: 2000, log: () => {} });
    const started = Date.now();
    const response = await handler(
      new Request("https://check.test/api/v1/verify", {
        method: "POST",
        headers: { "Content-Type": "application/json" },
        body: JSON.stringify(requestBody(full())),
      }),
    );
    await unavailable(response);
    assert.ok(Date.now() - started < 1500);
  });

  it("is unavailable, not wrong, when unconfigured", async () => {
    for (const problem of ["token_missing", "token_invalid", "settings_invalid"] as const) {
      const { post, logs, sim } = setup({ config: { problem } });
      const response = await post(requestBody(full()));
      assert.equal(response.status, 503);
      assert.equal(response.headers.get("retry-after"), "300");
      assert.deepEqual(await response.json(), { error: "not_configured" });
      assert.equal(logs.at(-1)!.reason, problem);
      assert.equal(sim.seen.length, 0);
    }
  });

  it("a missing project is misconfiguration (503), checked once per instance", async () => {
    let clock = NOW.getTime();
    const { sim, logs, post } = setup({ now: () => new Date(clock) });
    const report = full();
    sim.store(report);
    sim.projectExists = false;
    const response = await post(requestBody(report, report.eventId, 3600));
    assert.equal(response.status, 503);
    assert.deepEqual(await response.json(), { error: "not_configured" });
    assert.equal(logs.at(-1)!.reason, "project_not_found");
    assert.ok(!sim.seen.some((seen) => seen.url.includes("/events/")), "no event lookup, so never not_found");
    // Remembered for a minute, then checked again.
    sim.projectExists = true;
    assert.equal((await post(requestBody(report))).status, 503);
    clock += 60_000;
    assert.equal(await verdict(await post(requestBody(report)), new Date(clock)), "received");
    const projectChecks = () => sim.seen.filter((seen) => seen.url.endsWith("/workbench-reports/")).length;
    assert.equal(projectChecks(), 2);
    // Once found, never checked again on this instance.
    clock += 3_600_000;
    assert.equal(await verdict(await post(requestBody(report)), new Date(clock)), "received");
    assert.equal(projectChecks(), 2);
  });

  it("an unanswered project check is retried on the next request", async () => {
    const { sim, post } = setup();
    const report = full();
    sim.store(report);
    sim.overrides.push((url) => (url.pathname.endsWith("/workbench-reports/") ? json(502, {}) : undefined));
    await unavailable(await post(requestBody(report)));
    sim.overrides.length = 0;
    assert.equal(await verdict(await post(requestBody(report))), "received");
  });
});

describe("request validation", () => {
  it("405 for anything but POST", async () => {
    const { post } = setup();
    const response = await post(null, { method: "GET" });
    assert.equal(response.status, 405);
    assert.equal(response.headers.get("allow"), "POST");
    assert.equal(response.headers.get("cache-control"), "no-store");
  });

  it("413 for a declared or streamed body over 4 KiB", async () => {
    const { post, sim } = setup();
    const big = JSON.stringify({ ...requestBody(full()), pad: "x".repeat(5000) });
    assert.equal((await post(null, { raw: big })).status, 413);
    const declared = await post(null, { raw: "{}", headers: { "Content-Length": "4097" } });
    assert.equal(declared.status, 413);
    const stream = new ReadableStream<Uint8Array>({
      start(controller) {
        controller.enqueue(new TextEncoder().encode(big));
        controller.close();
      },
    });
    const { post: post2 } = setup();
    const response = await post2(null, { raw: stream, headers: {} });
    assert.equal(response.status, 413);
    assert.equal(sim.seen.length, 0);
  });

  it("422 for a wrong content type, invalid UTF-8, malformed or non-strict JSON", async () => {
    const { post, sim } = setup();
    const valid = JSON.stringify(requestBody(full()));
    const invalidUtf8 = new Uint8Array([...new TextEncoder().encode(valid.slice(0, -1)), 0xff, 0x7d]);
    const duplicate = valid.replace('{"event_id"', '{"report_id":"x","event_id"');
    for (const [raw, headers] of [
      [valid, { "Content-Type": "text/plain" }],
      [invalidUtf8, {}],
      [duplicate, {}],
      [valid + "x", {}],
      ["", {}],
      ["[]", {}],
    ] as Array<[BodyInit, Record<string, string>]>) {
      assert.equal((await post(null, { raw, headers })).status, 422);
    }
    assert.equal(sim.seen.length, 0);
  });

  it("422 for every field outside the contract", async () => {
    const { post, sim } = setup();
    const report = full();
    const base = requestBody(report);
    const attachments = base.attachments as Array<Record<string, unknown>>;
    const variants: unknown[] = [
      { ...base, extra: 1 },
      { event_id: base.event_id, report_id: base.report_id },
      { ...base, event_id: report.eventId.toUpperCase() },
      { ...base, event_id: report.eventId.slice(1) },
      { ...base, event_id: report.eventId.slice(0, 12) + "1" + report.eventId.slice(13) },
      { ...base, report_id: "a02149ed-36f5-1f10-9a21-10acfe2289b2" },
      { ...base, report_id: "a02149ed36f54f109a2110acfe2289b2" },
      { ...base, attachments: [] },
      { ...base, attachments: [...attachments, attachments[0]] },
      { ...base, attachments: attachments.slice(1) },
      { ...base, attachments: [{ ...attachments[0], extra: true }] },
      { ...base, attachments: [{ ...attachments[0], name: "../context.json" }] },
      { ...base, attachments: [{ ...attachments[0], size: 0 }] },
      { ...base, attachments: [{ ...attachments[0], size: 1.5 }] },
      { ...base, attachments: [{ ...attachments[0], size: ATTACHMENT_LIMITS["context.json"]! + 1 }] },
      { ...base, attachments: [{ ...attachments[0], size: "10" }] },
      { ...base, attachments: [{ ...attachments[0], sha256: "A".repeat(64) }] },
      Object.fromEntries(Object.entries(base).filter(([key]) => key !== "elapsed_seconds")),
      { ...base, elapsed_seconds: -1 },
      { ...base, elapsed_seconds: 1.5 },
      { ...base, elapsed_seconds: "30" },
      { ...base, elapsed_seconds: null },
      { ...base, elapsed_seconds: MAX_ELAPSED_SECONDS + 1 },
      { ...base, elapsed_seconds: 1e300 },
      { ...base, sent_at: "2026-10-07T01:00:00Z" },
    ];
    for (const variant of variants) {
      assert.equal((await post(variant)).status, 422, JSON.stringify(variant).slice(0, 120));
    }
    assert.equal(sim.seen.length, 0);
  });

  it("strict JSON parser", () => {
    assert.equal(JSON.stringify(parseStrictJson('{"a":[1,true,null,"\\ud83d\\ude00"]}')), '{"a":[1,true,null,"😀"]}');
    for (const text of ['{"a":"\\ud800"}', '{"a":1,"a":2}', '{"a":1}x', "{'a':1}", '{"a":01}', "[[[[[[[[[[1]]]]]]]]]]", '"\u0001"']) {
      assert.throws(() => parseStrictJson(text), text);
    }
  });

});

describe("configuration and privacy", () => {
  it("reads configuration with the decided defaults", () => {
    const config = readConfig({ SENTRY_READ_TOKEN: "abc" }) as Config;
    assert.equal(config.apiBase.origin, "https://us.sentry.io");
    assert.equal(config.org, "workbench-dp");
    assert.equal(config.project, "workbench-reports");
    for (const [env, problem] of [
      [{}, "token_missing"],
      [{ SENTRY_READ_TOKEN: "" }, "token_missing"],
      [{ SENTRY_READ_TOKEN: " \n\t" }, "token_missing"],
      [{ SENTRY_READ_TOKEN: "has space" }, "token_invalid"],
      [{ SENTRY_READ_TOKEN: "has\u0000nul" }, "token_invalid"],
      [{ SENTRY_READ_TOKEN: "abc", SENTRY_API_BASE: "http://us.sentry.io" }, "settings_invalid"],
      [{ SENTRY_READ_TOKEN: "abc", SENTRY_API_BASE: "https://us.sentry.io/api/0" }, "settings_invalid"],
      [{ SENTRY_READ_TOKEN: "abc", SENTRY_ORG: "Bad Org" }, "settings_invalid"],
    ] as const) {
      assert.deepEqual(readConfig(env), { problem }, JSON.stringify(env));
    }
  });

  it("trims whitespace around a pasted token", async () => {
    const trimmed = readConfig({ SENTRY_READ_TOKEN: `  ${TOKEN}\n`, SENTRY_API_BASE: `${API_BASE}\n` }) as Config;
    assert.equal(trimmed.token, TOKEN);
    const { sim, post } = setup({ config: trimmed });
    const report = full();
    sim.store(report);
    assert.equal(await verdict(await post(requestBody(report))), "received");
    assert.ok(sim.seen.filter((seen) => seen.url.startsWith(API_BASE)).every((seen) => seen.authorization === `Bearer ${TOKEN}`));
  });

  it("limits one client to 20 requests a minute per instance, without logging its address", async () => {
    let clock = NOW.getTime();
    const sim = new SentrySim();
    const logs: Record<string, unknown>[] = [];
    const handler = createHandler({ fetch: sim.fetch, config, now: () => new Date(clock), log: (line) => logs.push(line) });
    const report = full();
    sim.store(report);
    const send = (ip: string, headers: Record<string, string> = {}) =>
      handler(new Request("https://check.test/api/v1/verify", {
        method: "POST",
        headers: { "Content-Type": "application/json", "x-forwarded-for": `${ip}, 10.0.0.1`, ...headers },
        body: JSON.stringify(requestBody(report)),
      }));
    for (let i = 0; i < 20; i++) assert.equal((await send("203.0.113.7")).status, 200);
    clock += 15_000;
    const limited = await send("203.0.113.7");
    assert.equal(limited.status, 429);
    assert.equal(limited.headers.get("retry-after"), "45");
    assert.equal(limited.headers.get("cache-control"), "no-store");
    assert.deepEqual(await limited.json(), { error: "rate_limited" });
    assert.equal(logs.at(-1)!.reason, "rate_limited");
    // Other clients are unaffected; x-real-ip wins over x-forwarded-for.
    assert.equal((await send("198.51.100.4")).status, 200);
    assert.equal((await send("203.0.113.7", { "x-real-ip": "192.0.2.55" })).status, 200);
    // A new window opens after a minute.
    clock += 45_000;
    assert.equal((await send("203.0.113.7")).status, 200);
    const output = JSON.stringify(logs);
    for (const ip of ["203.0.113.7", "198.51.100.4", "192.0.2.55", "10.0.0.1"]) assert.ok(!output.includes(ip));
  });

  it("parses Sentry cursor links", () => {
    const link =
      '<https://us.sentry.io/a/?cursor=0:0:1>; rel="previous"; results="false"; cursor="0:0:1", ' +
      '<https://us.sentry.io/a/?cursor=0:100:0>; rel="next"; results="true"; cursor="0:100:0"';
    assert.equal(nextPage(link), "https://us.sentry.io/a/?cursor=0:100:0");
    assert.equal(nextPage(link.replace('results="true"', 'results="false"')), null);
    assert.equal(nextPage(null), null);
  });

  it("logs no token, identifiers, message or hashes; responses carry no content", async () => {
    const { sim, logs, post } = setup();
    const report = full();
    sim.store(report, { storage: "cross-origin" });
    const bodies: string[] = [];
    for (const body of [requestBody(report), { ...requestBody(report), extra: 1 }]) {
      const response = await post(body);
      bodies.push(await response.text());
    }
    sim.overrides.push(() => json(401, {}));
    bodies.push(await (await post(requestBody(report))).text());
    const secrets = [TOKEN, report.eventId, report.reportId, report.message, ...[...report.files.values()].map(sha256)];
    const output = JSON.stringify(logs) + bodies.join("\n");
    for (const secret of secrets) assert.ok(!output.includes(secret), `leaked ${secret.slice(0, 12)}`);
    assert.ok(logs.length === 3 && logs.every((line) => line.msg === "verify"));
  });

  it("the deployed export answers through console logging only content-free lines", { skip: !!process.env.SENTRY_READ_TOKEN }, async () => {
    const logged = mock.method(console, "log", () => {});
    try {
      const response = await verifier.fetch(
        new Request("https://check.test/api/v1/verify", {
          method: "POST",
          headers: { "Content-Type": "application/json" },
          body: JSON.stringify(requestBody(full())),
        }),
      );
      // Tests never set SENTRY_READ_TOKEN, so the real export reports itself unconfigured.
      assert.equal(response.status, 503);
      assert.equal(logged.mock.callCount(), 1);
      const line = JSON.parse(String(logged.mock.calls[0]!.arguments[0]));
      assert.deepEqual(Object.keys(line).sort(), ["calls", "ms", "msg", "reason", "status"]);
      assert.equal(line.reason, "token_missing");
    } finally {
      logged.mock.restore();
    }
  });
});
