import test from "node:test";
import assert from "node:assert/strict";
import { canonicalizeURL, cleanName, permissionPattern, matchesRememberedTab, matchesExactTab, validEnvelope,
  cleanDestinations, FocusController, safeError, ERRORS, MAX_PACKET_BYTES } from "../core.js";

const ID = "00000000-0000-4000-8000-000000000001";
const PROFILE = "00000000-0000-4000-8000-000000000002";
const URL = "https://manager.example.test/home";

function fixture({ tabs = [], permission = true, remembered, windowState = "normal" } = {}) {
  const tabMap = new Map(tabs.map(tab => [tab.id, { active: false, windowId: 1, incognito: false, ...tab }]));
  const windows = new Map([[1, { id: 1, focused: false, state: windowState, incognito: false }]]);
  const session = { destinationTabs: remembered ? { [ID]: remembered } : {} };
  const calls = [];
  const api = {
    storage: { session: {
      get: async key => { calls.push(["storage.get", key]); return structuredClone(session); },
      set: async value => { calls.push(["storage.set", value]); Object.assign(session, structuredClone(value)); },
    } },
    permissions: { contains: async value => { calls.push(["permissions", value]); return permission; } },
    tabs: {
      get: async id => { calls.push(["get", id]); if (!tabMap.has(id)) throw new Error("private URL must never leak"); return { ...tabMap.get(id) }; },
      query: async query => { calls.push(["query", query]); return [...tabMap.values()].map(tab => ({ ...tab })); },
      update: async (id, value) => { calls.push(["update", id, value]); if (!tabMap.has(id)) throw new Error("closed"); Object.assign(tabMap.get(id), value); return { ...tabMap.get(id) }; },
      create: async value => { calls.push(["create", value]); const tab = { id: 99, windowId: 1, incognito: false, ...value }; tabMap.set(99, tab); return { ...tab }; },
    },
    windows: {
      get: async id => { calls.push(["window.get", id]); return { ...windows.get(id) }; },
      update: async (id, value) => { calls.push(["window.update", id, value]); Object.assign(windows.get(id), value); return { ...windows.get(id) }; },
    },
  };
  return { api, calls, session, tabMap, windows };
}

test("canonical URL removes query and fragment and normalizes hostname/default port", () => {
  assert.equal(canonicalizeURL("HTTPS://MANAGER.EXAMPLE.TEST:443/home?a=private#detail"), URL);
  assert.equal(canonicalizeURL("https://example.test"), "https://example.test/");
});

for (const invalid of ["javascript:alert(1)", "file:///x", "chrome://settings", "data:text/plain,x", "//example.test", "https:example.test", "https:///", "https:///example.test", "https://@example.test", "https://user:secret@example.test", "https://user@example.test", "https://example.test/a b", "https://example.test/\n", "https://example.test\\other", "https://x/" + "a".repeat(4096)]) {
  test(`reject URL ${invalid.slice(0, 42)}`, () => assert.throws(() => canonicalizeURL(invalid), { code: "invalidURL" }));
}

test("names are bounded Unicode names and reject controls", () => {
  assert.equal(cleanName("  Manager  "), "Manager");
  assert.equal(cleanName("😀".repeat(80)), "😀".repeat(80));
  for (const name of ["", " \n ", "a\tb", "x".repeat(81)]) assert.throws(() => cleanName(name));
});

test("host permission has no subdomain wildcard; exact origin comparison includes port", () => {
  assert.equal(permissionPattern("https://manager.example.test:8443/home"), "https://manager.example.test/*");
  assert.equal(matchesRememberedTab({ id: 1, url: "https://manager.example.test:8443/home" }, URL), false);
  assert.equal(matchesRememberedTab({ id: 1, url: "https://other.example.test/home" }, URL), false);
});

test("remembered tab may move within exact origin, fallback must match canonical URL", () => {
  const tab = { id: 1, url: "https://manager.example.test/record/12?filter=all#view" };
  assert.equal(matchesRememberedTab(tab, URL), true);
  assert.equal(matchesExactTab(tab, URL), false);
  assert.equal(matchesExactTab({ id: 1, url: URL + "?filter=all#view" }, URL), true);
});

test("pending navigation wins over old tab address and incognito is excluded", () => {
  assert.equal(matchesRememberedTab({ id: 1, url: URL, pendingUrl: "https://foreign.test/" }, URL), false);
  assert.equal(matchesRememberedTab({ id: 1, url: URL, pendingUrl: "chrome://settings/" }, URL), false);
  assert.equal(matchesExactTab({ id: 1, url: URL, incognito: true }, URL), false);
});

test("wire validation bounds bytes and rejects wrong versions or ids", () => {
  assert.equal(validEnvelope({ v: 1, id: ID, type: "list" }), true);
  assert.equal(validEnvelope({ v: 2, id: ID, type: "list" }), false);
  assert.equal(validEnvelope({ v: 1, id: "not-id", type: "list" }), false);
  assert.equal(validEnvelope({ v: 1, id: ID, type: "list", text: "😀".repeat(MAX_PACKET_BYTES / 4) }), false);
});

test("destination list is validated and query strings never reach popup", () => {
  const item = { id: ID, profileID: PROFILE, title: "Manager", profileName: "Demo", connected: true, url: URL + "?private=yes" };
  assert.equal(cleanDestinations([item])[0].url, URL);
  assert.throws(() => cleanDestinations([{ ...item, profileID: "invalid" }]));
  assert.throws(() => cleanDestinations([{ ...item, connected: "yes" }]));
});

test("permission refusal cannot query or create a tab", async () => {
  const f = fixture({ permission: false });
  await assert.rejects(new FocusController(f.api).focus({ destinationID: ID, url: URL }), { code: "permission" });
  assert.deepEqual(f.calls.map(call => call[0]), ["permissions"]);
});

test("remembered tab in same tenant path focuses without querying or navigating", async () => {
  const f = fixture({ tabs: [{ id: 2, url: "https://manager.example.test/record/123" }], remembered: { tabID: 2, savedURL: URL } });
  assert.deepEqual(await new FocusController(f.api).focus({ destinationID: ID, url: URL }), { ok: true, status: "focused" });
  assert.equal(f.calls.some(call => ["query", "create"].includes(call[0])), false);
  assert.deepEqual(f.calls.find(call => call[0] === "update"), ["update", 2, { active: true }]);
});

test("missing remembered tab resolves one exact address with origin-limited query", async () => {
  const f = fixture({ tabs: [{ id: 2, url: URL + "?view=current" }, { id: 3, url: "https://foreign.test/home" }], remembered: { tabID: 1, savedURL: URL } });
  await new FocusController(f.api).focus({ destinationID: ID, url: URL });
  assert.deepEqual(f.calls.find(call => call[0] === "query"), ["query", { url: "https://manager.example.test/*" }]);
  assert.equal(f.session.destinationTabs[ID].tabID, 2);
});

test("reused remembered tab on another origin remains unchanged and new exact tab opens", async () => {
  const f = fixture({ tabs: [{ id: 1, url: "https://foreign.test/home" }], remembered: { tabID: 1, savedURL: URL } });
  const result = await new FocusController(f.api).focus({ destinationID: ID, url: URL });
  assert.equal(result.status, "opened");
  assert.equal(f.tabMap.get(1).active, false);
  assert.equal(f.tabMap.get(1).url, "https://foreign.test/home");
  assert.deepEqual(f.calls.find(call => call[0] === "create"), ["create", { url: URL, active: true }]);
});

test("changed saved URL invalidates old binding even on same host", async () => {
  const f = fixture({ tabs: [{ id: 1, url: "https://manager.example.test/old" }], remembered: { tabID: 1, savedURL: "https://manager.example.test/old" } });
  assert.equal((await new FocusController(f.api).focus({ destinationID: ID, url: URL })).status, "opened");
  assert.equal(f.session.destinationTabs[ID].tabID, 99);
});

test("multiple exact matches fail without any focus or create mutation", async () => {
  const f = fixture({ tabs: [{ id: 1, url: URL }, { id: 2, url: URL + "?other=true" }] });
  await assert.rejects(new FocusController(f.api).focus({ destinationID: ID, url: URL }), { code: "ambiguous" });
  assert.equal(f.calls.some(call => ["create", "update", "window.update"].includes(call[0])), false);
});

test("incognito and nonmatching paths cannot enter fallback candidates", async () => {
  const f = fixture({ tabs: [{ id: 1, url: URL, incognito: true }, { id: 2, url: "https://manager.example.test/other" }] });
  assert.equal((await new FocusController(f.api).focus({ destinationID: ID, url: URL })).status, "opened");
});

test("minimized window restores; maximized window retains its state", async () => {
  for (const windowState of ["minimized", "maximized"]) {
    const f = fixture({ tabs: [{ id: 1, url: URL }], windowState });
    await new FocusController(f.api).focus({ destinationID: ID, url: URL });
    assert.deepEqual(f.calls.find(call => call[0] === "window.update")[2], windowState === "minimized" ? { focused: true, state: "normal" } : { focused: true });
  }
});

test("navigation race after query fails before activating an unrelated tab", async () => {
  const f = fixture({ tabs: [{ id: 1, url: URL }] });
  const query = f.api.tabs.query;
  f.api.tabs.query = async args => { const results = await query(args); f.tabMap.get(1).url = "https://foreign.test/"; return results; };
  await assert.rejects(new FocusController(f.api).focus({ destinationID: ID, url: URL }), { code: "changed" });
  assert.equal(f.calls.some(call => call[0] === "update"), false);
});

test("tab closed between query and action fails without creating a duplicate", async () => {
  const f = fixture({ tabs: [{ id: 1, url: URL }] });
  const query = f.api.tabs.query;
  f.api.tabs.query = async args => { const results = await query(args); f.tabMap.clear(); return results; };
  await assert.rejects(new FocusController(f.api).focus({ destinationID: ID, url: URL }), { code: "failed" });
  assert.equal(f.calls.some(call => call[0] === "create"), false);
});

test("failed window focus is not successful activation", async () => {
  const f = fixture({ tabs: [{ id: 1, url: URL }] });
  f.api.windows.update = async () => {};
  await assert.rejects(new FocusController(f.api).focus({ destinationID: ID, url: URL }), { code: "changed" });
  assert.equal(f.session.destinationTabs[ID], undefined);
});

test("error diagnostics never leak raw tab URLs or API payloads", async () => {
  const f = fixture();
  f.api.tabs.query = async () => { throw new Error("secret private path"); };
  try { await new FocusController(f.api).focus({ destinationID: ID, url: URL }); assert.fail(); }
  catch (error) { assert.equal(safeError(error), ERRORS.failed); }
  assert.equal(safeError(new Error("secret")), ERRORS.failed);
});

test("concurrent focus refuses duplicate opens while first operation is unresolved", async () => {
  const f = fixture();
  let resume;
  f.api.permissions.contains = () => new Promise(resolve => { resume = resolve; });
  const focus = new FocusController(f.api);
  const first = focus.focus({ destinationID: ID, url: URL });
  await assert.rejects(focus.focus({ destinationID: ID, url: URL }), { code: "busy" });
  resume(true);
  await first;
  assert.equal(f.calls.filter(call => call[0] === "create").length, 1);
});

test("deadline expiry after API await prevents create/focus and stale success", async () => {
  const f = fixture();
  let now = 1_000;
  f.api.tabs.query = async () => { now += 9_000; return []; };
  await assert.rejects(new FocusController(f.api, { now: () => now }).focus({ destinationID: ID, url: URL }), { code: "timeout" });
  assert.equal(f.calls.some(call => call[0] === "create"), false);
});

test("native expiresAt rejects expired, unbounded, and sleep-delayed commands", async () => {
  for (const expiresAt of [999, 1_000, 11_001, NaN, "soon"]) {
    const f = fixture();
    await assert.rejects(new FocusController(f.api, { now: () => 1_000 }).focus({ destinationID: ID, url: URL, expiresAt }), { code: "timeout" });
    assert.equal(f.calls.length, 0);
  }
  const f = fixture();
  let now = 1_000;
  f.api.permissions.contains = async () => { now = 1_101; return true; };
  await assert.rejects(new FocusController(f.api, { now: () => now }).focus({ destinationID: ID, url: URL, expiresAt: 1_100 }), { code: "timeout" });
});

test("abort while waiting never reports success or opens after cancellation", async () => {
  const f = fixture();
  const controller = new AbortController();
  f.api.tabs.query = async () => { controller.abort(); return []; };
  await assert.rejects(new FocusController(f.api).focus({ destinationID: ID, url: URL }, { signal: controller.signal }), { code: "timeout" });
  assert.equal(f.calls.some(call => call[0] === "create"), false);
});

test("concurrent save bindings retain both destinations in session storage", async () => {
  const f = fixture();
  const focus = new FocusController(f.api);
  await Promise.all([focus.remember(ID, 1, URL), focus.remember(PROFILE, 2, URL)]);
  assert.equal(f.session.destinationTabs[ID].tabID, 1);
  assert.equal(f.session.destinationTabs[PROFILE].tabID, 2);
});
