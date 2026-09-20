import test from "node:test";
import assert from "node:assert/strict";
import { cleanDefaultTab, readDefaultTab, saveDefaultTab, openDefaultTab, redirectNewTab } from "../default-tab.js";

const defaultURL = "https://compound-snowy-pi.vercel.app/pocket?passwordMode=1&app=rippling#employee";
const settings = extra => ({ version: 1, url: defaultURL, redirectNewTabs: false, openOnStartup: false, ...extra });
function fixture() {
  const local = {}, calls = [];
  const api = { storage: { local: {
    get: async () => structuredClone(local),
    set: async value => Object.assign(local, structuredClone(value)),
  } }, tabs: { create: async value => { calls.push(value); return { id: 42 }; } } };
  return { api, local, calls };
}

test("unconfigured and disabled settings never redirect or open at startup", async () => {
  const f = fixture(); const redirects = [];
  assert.deepEqual(await readDefaultTab(f.api), settings({ url: "" }));
  assert.equal(await openDefaultTab(f.api, { startup: true }), false);
  assert.equal(await redirectNewTab(f.api, { replace: url => redirects.push(url) }), false);
  await assert.rejects(openDefaultTab(f.api), { code: "defaultTabMissing" });
  await saveDefaultTab(f.api, settings());
  assert.equal(await openDefaultTab(f.api, { startup: true }), false);
  assert.deepEqual(f.calls, []); assert.deepEqual(redirects, []);
});

test("manual opening preserves query and fragment, without pairing, tab inspection or site access", async () => {
  const f = fixture(); await saveDefaultTab(f.api, settings());
  assert.equal(await openDefaultTab(f.api), true);
  assert.deepEqual(f.calls, [{ url: defaultURL, active: true }]);
  assert.deepEqual(Object.keys(f.local), ["defaultTab"]);
});

test("two profile settings remain independent even with the same local companion", async () => {
  const manager = fixture(), employee = fixture();
  manager.local.profileID = "manager"; employee.local.profileID = "employee";
  await saveDefaultTab(manager.api, settings({ url: "https://example.test/manager", redirectNewTabs: true }));
  await saveDefaultTab(employee.api, settings({ openOnStartup: true }));
  const redirects = [];
  await redirectNewTab(manager.api, { replace: url => redirects.push(url) });
  assert.equal(await redirectNewTab(employee.api, { replace: url => redirects.push(url) }), false);
  assert.equal(await openDefaultTab(manager.api, { startup: true }), false);
  await openDefaultTab(employee.api, { startup: true });
  assert.deepEqual(redirects, ["https://example.test/manager"]);
  assert.deepEqual(employee.calls, [{ url: defaultURL, active: false }]);
  assert.deepEqual(manager.calls, []);
  assert.equal(manager.local.profileID, "manager");
});

test("clearing settings stops both automatic paths and does not touch existing tabs or pairing", async () => {
  const f = fixture(); f.local.paired = true;
  await saveDefaultTab(f.api, settings({ redirectNewTabs: true, openOnStartup: true }));
  await saveDefaultTab(f.api, settings({ url: "" }));
  assert.equal(await openDefaultTab(f.api, { startup: true }), false);
  assert.equal(await redirectNewTab(f.api, { replace: () => assert.fail("unexpected redirect") }), false);
  assert.deepEqual(f.calls, []); assert.equal(f.local.paired, true);
});

test("URL validation rejects credentials, unsafe schemes and secret parameters before writing or opening", async () => {
  for (const url of ["javascript:alert(1)", "data:text/html,x", "file:///tmp/a", "chrome://newtab/", "https://user:pass@example.test/", "https://@example.test/", "https://example.test/?token=x", "https://example.test/#/login?password=x", "https://example.test/?%61pi_key=x", "https://exam\nple.test/", "https://example.test/\\x", "https://example.test/" + "a".repeat(4096)]) {
    const f = fixture();
    await assert.rejects(saveDefaultTab(f.api, settings({ url })), { code: "defaultTabInvalid" });
    assert.deepEqual(f.local, {}); assert.deepEqual(f.calls, []);
  }
});

test("corrupt stored configuration fails closed rather than navigating or silently overwriting it", async () => {
  for (const bad of [null, [], settings({ version: 2 }), settings({ redirectNewTabs: "false" }), settings({ openOnStartup: 1 }), settings({ extra: true }), settings({ url: "", redirectNewTabs: true }), settings({ url: "", openOnStartup: true }), settings({ url: "javascript:alert(1)", redirectNewTabs: true })]) {
    const f = fixture(); f.local.defaultTab = bad;
    await assert.rejects(openDefaultTab(f.api, { startup: true }), { code: "defaultTabInvalid" });
    await assert.rejects(redirectNewTab(f.api, { replace: () => assert.fail("unexpected redirect") }), { code: "defaultTabInvalid" });
    assert.deepEqual(f.local.defaultTab, bad); assert.deepEqual(f.calls, []);
  }
});

test("save failure preserves previous setting; failed opening is not retried", async () => {
  const f = fixture(); await saveDefaultTab(f.api, settings());
  f.api.storage.local.set = async () => { throw new Error("storage unavailable"); };
  await assert.rejects(saveDefaultTab(f.api, settings({ redirectNewTabs: true })));
  assert.equal((await readDefaultTab(f.api)).redirectNewTabs, false);
  f.api.tabs.create = async value => { f.calls.push(value); throw new Error("uncertain creation"); };
  await assert.rejects(openDefaultTab(f.api));
  assert.equal(f.calls.length, 1);
});

test("known Compound app variants remain complete navigation URLs", () => {
  for (const app of ["rippling", "servicenow", "workday"]) {
    const url = `https://compound-snowy-pi.vercel.app/pocket?passwordMode=1&app=${app}`;
    assert.equal(cleanDefaultTab(settings({ url })).url, url);
  }
});
