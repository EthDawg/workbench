import test from "node:test";
import assert from "node:assert/strict";
import { SetupController, cleanSetup, setupURL } from "../setup.js";

const PACK = "00000000-0000-4000-8000-000000000001";
const uuid = n => `00000000-0000-4000-8000-${String(n).padStart(12, "0")}`;
const pack = () => ({ packID: PACK, title: "Synthetic pack", roleID: "manager", roleTitle: "Manager", bookmarks: [
  { id: "home", title: "Home", url: "https://example.test/home?view=compact#today", folder: "Work" },
  { id: "help", title: "Help", url: "https://example.test/help", folder: "Work" },
], launchURLs: ["https://example.test/home", "https://example.test/help"], defaultURL: "https://example.test/home" });

function fixture() {
  let time = 1000, sequence = 100, nextNode = 10;
  const local = {};
  const root = { id: "root", title: "", children: [
    { id: "local-bar", parentId: "root", title: "Local Bookmarks", folderType: "bookmarks-bar", syncing: false, children: [] },
    { id: "synced-bar", parentId: "root", title: "Account Bookmarks", folderType: "bookmarks-bar", syncing: true, children: [] },
    { id: "managed", parentId: "root", title: "Managed", folderType: "other", syncing: false, unmodifiable: "managed", children: [] },
  ] };
  const find = id => { const walk = node => node.id === id ? node : (node.children ?? []).map(walk).find(Boolean); return walk(root); };
  const controls = { permission: true, failAt: 0, saveFail: null, beforeWrite: null, beforeTree: null, launchFail: false };
  const writes = [], windows = [];
  const api = {
    permissions: { contains: async () => controls.permission },
    storage: { local: {
      get: async () => structuredClone(local),
      set: async value => { if (controls.saveFail?.(value)) throw Error("synthetic storage failure"); Object.assign(local, structuredClone(value)); },
    } },
    bookmarks: {
      getTree: async () => { controls.beforeTree?.(); return structuredClone([root]); },
      create: async input => {
        assert.ok(local.browserSetup.journal, "intent must be durable before a bookmark API write");
        writes.push({ type: "create", ...input }); controls.beforeWrite?.();
        if (controls.failAt === writes.length) throw Error("synthetic API failure");
        const node = { id: String(nextNode++), ...input, syncing: false, ...(input.url ? {} : { children: [] }) };
        find(input.parentId).children.push(node); return structuredClone(node);
      },
      update: async (id, changes) => {
        assert.ok(local.browserSetup.journal); writes.push({ type: "update", id, ...changes }); controls.beforeWrite?.();
        if (controls.failAt === writes.length) throw Error("synthetic API failure");
        const node = find(id); Object.assign(node, changes); return structuredClone(node);
      },
      move: async (id, target) => {
        assert.ok(local.browserSetup.journal); writes.push({ type: "move", id, ...target });
        const node = find(id), old = find(node.parentId); old.children.splice(old.children.indexOf(node), 1);
        node.parentId = target.parentId; find(target.parentId).children.push(node); return structuredClone(node);
      },
    },
    windows: { create: async input => {
      assert.equal(Object.values(local.browserSetup.launches).at(-1).state, "started");
      windows.push(input); if (controls.launchFail) throw Error("synthetic launch uncertainty");
      return { id: 5, incognito: false, tabs: input.url.map((url, id) => ({ id, url })) };
    } },
  };
  const options = { now: () => time, uuid: () => uuid(sequence++) };
  let controller = new SetupController(api, options);
  const message = (type, setup = pack(), extra = {}) => ({ v: 1, id: uuid(sequence++), type, expiresAt: time + 30_000, setup, ...extra });
  const preview = async setup => controller.command(message("setupPreview", setup));
  const apply = async (setup = pack(), token) => {
    const reviewToken = token ?? (await preview(setup)).setupResult.reviewToken;
    return controller.command(message("setupApply", setup, { reviewToken }));
  };
  return { get controller() { return controller; }, api, controls, writes, windows, local, root, find, message, preview, apply,
    configure: () => controller.selectRoot("local-bar"), advance: ms => { time += ms; },
    restart: () => { controller = new SetupController(api, options); },
    receipt: () => local.browserSetup.receipts[`${PACK}:manager`],
  };
}

test("pack preserves ordinary query and fragment, rejects secrets, unsafe addresses and duplicate IDs", () => {
  assert.equal(cleanSetup(pack()).bookmarks[0].url, pack().bookmarks[0].url);
  assert.equal(setupURL("https://example.test/?postcode=1#section"), "https://example.test/?postcode=1#section");
  for (const url of ["https://u:p@example.test", "https://@example.test", "javascript:alert(1)", "file:///x", "https://example.test/a b", "https://example.test/\\x", "https://example.test/?%74oken=x", "https://example.test/?API_KEY=x", "https://example.test/#access_token=x"]) assert.throws(() => setupURL(url), { code: "setupInvalid" });
  const value = pack(); value.bookmarks.push(value.bookmarks[0]); assert.throws(() => cleanSetup(value), { code: "setupInvalid" });
  value.bookmarks = []; value.launchURLs = Array(9).fill("https://example.test/"); assert.throws(() => cleanSetup(value), { code: "setupInvalid" });
});

test("missing permission performs no bookmark read or write and never requests it itself", async () => {
  const f = fixture(); f.controls.permission = false;
  f.api.bookmarks.getTree = () => { throw Error("must not inspect without permission"); };
  assert.equal((await f.controller.state()).permission, false);
  await assert.rejects(f.preview(), { code: "setupPermission" }); assert.equal(f.writes.length, 0);
});

test("root selection is explicit and accepts only writable local modern roots", async () => {
  const f = fixture();
  assert.deepEqual((await f.controller.state()).roots, [{ id: "local-bar", title: "Local Bookmarks" }]);
  await assert.rejects(f.preview(), { code: "setupRoot" });
  for (const id of ["synced-bar", "managed", "root", "unknown"]) await assert.rejects(f.controller.selectRoot(id), { code: "setupRoot" });
  for (const node of f.root.children) { delete node.syncing; delete node.folderType; }
  await assert.rejects(f.controller.state(), { code: "setupUnsupported" }); assert.equal(f.writes.length, 0);
});

test("apply creates bounded own folders, returns bookmark counts and is idempotent", async () => {
  const f = fixture(); await f.configure();
  const first = await f.apply(); assert.equal(first.ok, true); assert.equal(first.setupResult.create, 2);
  assert.equal(f.writes.length, 4); assert.equal(f.local.browserSetup.journal, null);
  const again = await f.apply(); assert.equal(again.ok, true); assert.equal(again.setupResult.unchanged, 2); assert.equal(again.setupResult.create, 0); assert.equal(f.writes.length, 4);
  assert.equal(f.root.children[1].children.length, 0); assert.equal(f.root.children[2].children.length, 0);
});

test("same named existing folders are never adopted and dangerous dictionary names are handled as literal text", async () => {
  const f = fixture(); await f.configure();
  f.find("local-bar").children.push({ id: "unowned", parentId: "local-bar", title: "Synthetic pack — Manager", syncing: false, children: [] });
  const setup = pack(); setup.bookmarks[0].folder = "__proto__"; setup.bookmarks[0].id = "constructor";
  assert.equal((await f.apply(setup)).ok, true);
  assert.equal(f.find("unowned").children.length, 0);
  assert.ok(Object.hasOwn(f.receipt().groups, "__proto__")); assert.ok(Object.hasOwn(f.receipt().items, "constructor"));
  assert.equal((await f.apply(setup)).setupResult.unchanged, 2);
});

test("updates preserve stable node IDs and support an explicit changed folder without deletes", async () => {
  const f = fixture(); await f.configure(); await f.apply();
  const id = f.receipt().items.home.id;
  const setup = pack(); setup.bookmarks[0].title = "New name"; setup.bookmarks[0].url = "https://example.test/new?mode=work#start"; setup.bookmarks[0].folder = "New folder";
  const result = await f.apply(setup); assert.equal(result.ok, true); assert.equal(result.setupResult.update, 1); assert.equal(result.setupResult.unchanged, 1);
  assert.equal(f.receipt().items.home.id, id); assert.equal(f.find(id).url, setup.bookmarks[0].url);
  assert.equal(f.find(f.receipt().groups.Work.id).children.length, 1);
});

test("manual changes, missing nodes and moved folders are conflicts without replacement or overwrite", async () => {
  const f = fixture(); await f.configure(); await f.apply();
  const before = f.writes.length; const id = f.receipt().items.home.id; f.find(id).title = "My manual choice";
  const result = await f.apply(); assert.equal(result.ok, true); assert.equal(result.setupResult.conflicts, 1); assert.equal(f.find(id).title, "My manual choice"); assert.equal(f.writes.length, before);
  f.find(f.receipt().container.id).title = "Renamed by me";
  assert.equal((await f.preview()).setupResult.conflicts, 2);
});

test("preview token expires after five minutes, is single-use, and binds exact setup and root snapshots", async () => {
  const f = fixture(); await f.configure();
  const token = (await f.preview()).setupResult.reviewToken;
  const altered = pack(); altered.bookmarks[0].title = "Different";
  await assert.rejects(f.apply(altered, token), { code: "setupChanged" });
  await assert.rejects(f.apply(pack(), token), { code: "setupChanged" });
  const expired = (await f.preview()).setupResult.reviewToken; f.advance(300_001);
  await assert.rejects(f.apply(pack(), expired), { code: "setupChanged" });
  const changed = (await f.preview()).setupResult.reviewToken; f.find("local-bar").title = "Changed";
  await assert.rejects(f.apply(pack(), changed), { code: "setupChanged" }); assert.equal(f.writes.length, 0);
});

test("edit after preview invalidates review rather than silently converting it to conflicts", async () => {
  const f = fixture(); await f.configure(); await f.apply();
  const token = (await f.preview()).setupResult.reviewToken;
  f.find(f.receipt().items.home.id).title = "Manual";
  await assert.rejects(f.apply(pack(), token), { code: "setupChanged" });
});

test("changing root to synced after preview fails without a write", async () => {
  const f = fixture(); await f.configure(); const token = (await f.preview()).setupResult.reviewToken;
  f.find("local-bar").syncing = true;
  await assert.rejects(f.apply(pack(), token), { code: "setupRoot" }); assert.equal(f.writes.length, 0);
});

test("partial API failure returns partial counts and durable uncertainty blocks restart replay", async () => {
  const f = fixture(); await f.configure(); f.controls.failAt = 4;
  const result = await f.apply(); assert.equal(result.ok, false); assert.equal(result.error, "setupUncertain"); assert.equal(result.setupResult.create, 1);
  assert.ok(f.local.browserSetup.journal); f.restart();
  await assert.rejects(f.preview(), { code: "setupUncertain" }); assert.equal(f.writes.length, 4);
});

test("storage failure before intent means no Chrome write; after write leaves durable uncertainty", async () => {
  const f = fixture(); await f.configure();
  f.controls.saveFail = value => Boolean(value.browserSetup.journal);
  const before = await f.apply(); assert.equal(before.ok, false); assert.equal(f.writes.length, 0);
  f.controls.saveFail = value => !value.browserSetup.journal && f.writes.length > 0;
  const after = await f.apply(); assert.equal(after.error, "setupUncertain"); assert.equal(f.writes.length, 1); assert.ok(f.local.browserSetup.journal);
  f.controls.saveFail = null; f.restart(); await assert.rejects(f.preview(), { code: "setupUncertain" });
});

test("disconnect during write finishes receipt but performs no next write or success", async () => {
  const f = fixture(); await f.configure(); f.controls.beforeWrite = () => f.controller.cancel();
  const result = await f.apply(); assert.equal(result.ok, false); assert.equal(result.error, "setupUncertain"); assert.equal(f.writes.length, 1);
  assert.equal(f.local.browserSetup.journal, null); assert.ok(f.receipt().container);
});

test("concurrent commands are serialized by refusal and expired commands have no effects", async () => {
  const f = fixture(); await f.configure();
  let release; const get = f.api.bookmarks.getTree; f.api.bookmarks.getTree = () => new Promise(resolve => { release = async () => resolve(await get()); });
  const first = f.preview(); await new Promise(resolve => setImmediate(resolve));
  await assert.rejects(f.preview(), { code: "busy" }); await release(); await first;
  f.api.bookmarks.getTree = get;
  await assert.rejects(f.controller.command(f.message("setupPreview", pack(), { expiresAt: 999 })), { code: "timeout" }); assert.equal(f.writes.length, 0);
});

test("launch opens ordered new window without bookmark permission; duplicate IDs never replay after restart", async () => {
  const f = fixture(); f.controls.permission = false;
  const message = f.message("setupLaunch");
  const result = await f.controller.command(message); assert.equal(result.ok, true); assert.equal(result.setupResult.create, 2);
  assert.deepEqual(f.windows, [{ url: pack().launchURLs, type: "normal", focused: true, incognito: false }]);
  f.restart(); await assert.rejects(f.controller.command(message), { code: "setupUncertain" }); assert.equal(f.windows.length, 1);
});

test("uncertain launch is not retried and an empty launch list is rejected", async () => {
  const f = fixture(); f.controls.launchFail = true; const message = f.message("setupLaunch");
  await assert.rejects(f.controller.command(message), { code: "setupUncertain" });
  f.restart(); await assert.rejects(f.controller.command(message), { code: "setupUncertain" });
  const empty = pack(); empty.launchURLs = []; await assert.rejects(f.controller.command(f.message("setupLaunch", empty)), { code: "setupInvalid" }); assert.equal(f.windows.length, 1);
});


test("unexpected Chrome mutation result cannot become a trusted receipt", async () => {
  const f = fixture(); await f.configure(); const original = f.api.bookmarks.create;
  f.api.bookmarks.create = async input => ({ ...await original(input), title: "Unexpected change" });
  const result = await f.apply(); assert.equal(result.ok, false); assert.equal(result.error, "setupUncertain");
  assert.equal(f.writes.length, 1); assert.ok(f.local.browserSetup.journal); assert.equal(f.receipt(), undefined);
});

test("permission revoked after preview prevents apply and old worker tokens cannot survive restart", async () => {
  const f = fixture(); await f.configure(); const token = (await f.preview()).setupResult.reviewToken;
  f.controls.permission = false; await assert.rejects(f.apply(pack(), token), { code: "setupPermission" });
  f.controls.permission = true; f.restart(); await assert.rejects(f.apply(pack(), token), { code: "setupChanged" });
  assert.equal(f.writes.length, 0);
});
