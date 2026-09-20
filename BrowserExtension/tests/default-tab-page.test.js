import test from "node:test";
import assert from "node:assert/strict";
let sequence = 0;
const settle = () => new Promise(resolve => setImmediate(resolve));
function fixture() {
  const local = {}, opened = [], nodes = new Map();
  const element = id => {
    if (!nodes.has(id)) nodes.set(id, { value: "", checked: false, disabled: false, hidden: true, dataset: {}, listeners: {},
      addEventListener(name, callback) { this.listeners[name] = callback; },
      setAttribute() {}, querySelectorAll: () => [...nodes.values()],
    });
    return nodes.get(id);
  };
  globalThis.document = { getElementById: element };
  globalThis.chrome = { storage: { local: {
    get: async () => structuredClone(local), set: async value => Object.assign(local, structuredClone(value)),
  } }, tabs: { create: async value => { opened.push(value); } } };
  return { local, opened, element };
}

test("setup form saves, explicitly opens and clears only this profile's default setting", async () => {
  const f = fixture(); f.local.paired = true;
  await import(`../default-tab-page.js?test=${sequence++}`); await settle();
  assert.equal(f.element("redirect-new-tabs").checked, false);
  f.element("default-url").value = "https://example.test/home?app=workday";
  f.element("redirect-new-tabs").checked = true;
  f.element("default-tab-form").listeners.submit({ preventDefault() {} }); await settle();
  assert.equal(f.local.defaultTab.redirectNewTabs, true);
  assert.equal(f.opened.length, 0);
  f.element("open-default-tab").listeners.click(); await settle();
  assert.deepEqual(f.opened, [{ url: "https://example.test/home?app=workday", active: true }]);
  f.element("clear-default-tab").listeners.click(); await settle();
  assert.equal(f.local.defaultTab.url, "");
  assert.equal(f.local.defaultTab.redirectNewTabs, false);
  assert.equal(f.local.defaultTab.openOnStartup, false);
  assert.equal(f.local.paired, true);
  assert.match(f.element("default-tab-feedback").textContent, /New Tab still shows/);
});

test("invalid form address reports a safe error and retains previous saved default", async () => {
  const f = fixture();
  f.local.defaultTab = { version: 1, url: "https://example.test/", redirectNewTabs: false, openOnStartup: false };
  await import(`../default-tab-page.js?test=${sequence++}`); await settle();
  f.element("default-url").value = "https://user:private@example.test/";
  f.element("default-tab-form").listeners.submit({ preventDefault() {} }); await settle();
  assert.equal(f.local.defaultTab.url, "https://example.test/");
  assert.equal(f.element("default-tab-feedback").dataset.error, "true");
  assert.doesNotMatch(f.element("default-tab-feedback").textContent, /private/);
  assert.equal(f.element("default-url").disabled, false);
  assert.equal(f.opened.length, 0);
});

test("bundled New Tab page redirects its own document only after opt-in and retains manual open recovery", async () => {
  const f = fixture(), redirects = [];
  globalThis.window = { location: { replace: url => redirects.push(url) } };
  await import(`../newtab.js?test=${sequence++}`); await settle();
  assert.deepEqual(redirects, []);
  f.local.defaultTab = { version: 1, url: "https://example.test/", redirectNewTabs: true, openOnStartup: false };
  await import(`../newtab.js?test=${sequence++}`); await settle();
  assert.deepEqual(redirects, ["https://example.test/"]);
  await f.element("open-default-tab").listeners.click();
  assert.deepEqual(f.opened, [{ url: "https://example.test/", active: true }]);
});
