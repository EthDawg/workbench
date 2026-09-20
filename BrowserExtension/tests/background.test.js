import test from "node:test";
import assert from "node:assert/strict";
import { ERRORS } from "../core.js";

const EXTENSION = "ajafaiojgpdgmeblldllnhhfnafiiieo";
const DESTINATION = "00000000-0000-4000-8000-000000000001";
const OTHER_PROFILE = "00000000-0000-4000-8000-000000000002";
const URL = "https://manager.example.test/home";
let sequence = 0;
function event() {
  const listeners = [];
  return { addListener: fn => listeners.push(fn), emit: value => listeners.forEach(fn => fn(value)), listeners };
}

async function fixture({ permission = true, saveNavigates = false, connectError } = {}) {
  const local = {};
  const session = {};
  let current = { id: 7, url: URL + "?private=removed#view", title: "Private customer title", active: true, windowId: 1, incognito: false };
  const destinations = [];
  const sent = [];
  const alarms = [];
  const ports = [];
  const api = {
    storage: {
      local: { get: async () => ({ ...local }), set: async value => Object.assign(local, value) },
      session: { get: async () => structuredClone(session), set: async value => Object.assign(session, structuredClone(value)) },
    },
    permissions: { contains: async () => permission },
    tabs: { query: async () => [{ ...current }] },
    alarms: { create: async (...args) => alarms.push(args), clear: async () => true, onAlarm: event() },
    runtime: {
      id: EXTENSION, getURL: path => `chrome-extension://${EXTENSION}/${path}`,
      onMessage: event(), onInstalled: event(), onStartup: event(),
      connectNative: () => {
        const port = { onMessage: event(), onDisconnect: event(),
          disconnect: () => port.onDisconnect.emit(),
          postMessage: message => {
            sent.push(message);
            queueMicrotask(() => {
              const result = { v: 1, id: message.id, type: "result", ok: true, destinations: [...destinations] };
              if (message.type === "hello" && connectError) { result.ok = false; result.error = connectError; }
              if (message.type === "save") {
                const destination = { id: message.destinationID ?? DESTINATION, title: message.title, url: message.url,
                  profileName: local.profileName, profileID: local.profileID, connected: true };
                const index = destinations.findIndex(item => item.id === destination.id);
                if (index < 0) destinations.push(destination); else destinations[index] = destination;
                result.destinationID = destination.id;
                result.destinations = [...destinations];
                if (saveNavigates) current = { ...current, url: "https://foreign.example.test/" };
              }
              if (message.type === "activate") result.status = "focused";
              port.onMessage.emit(result);
            });
          } };
        ports.push(port);
        return port;
      },
    },
  };
  globalThis.chrome = api;
  await import(`../background.js?fixture=${sequence++}`);
  const sender = { id: EXTENSION, url: api.runtime.getURL("popup.html") };
  const send = message => new Promise(resolve => {
    assert.equal(api.runtime.onMessage.listeners[0](message, sender, resolve), true);
  });
  const connect = () => send({ type: "connect", profileName: "Manager profile" });
  const save = extra => send({ type: "save", title: "Manager", url: URL, tabID: 7, ...extra });
  return { api, local, session, destinations, sent, alarms, ports, send, connect, save, sender,
    navigate: value => { current = { ...current, ...value }; } };
}

test("unpaired startup and popup state do not connect, activate, or copy current tab title", async () => {
  const f = await fixture();
  const state = await f.send({ type: "state" });
  assert.equal(state.paired, false);
  assert.equal(state.tab.url, URL);
  assert.equal(state.tab.stripped, true);
  assert.equal(JSON.stringify(state).includes("Private customer"), false);
  assert.equal(f.sent.length, 0);
  assert.deepEqual(f.local, {});
});

test("explicit pairing keeps only profile identity in local storage and preserves UUID on Retry", async () => {
  const f = await fixture();
  const first = await f.connect();
  assert.equal(first.ok, true);
  assert.equal(f.local.paired, true);
  assert.deepEqual(Object.keys(f.local).sort(), ["paired", "profileID", "profileName"]);
  const second = await f.send({ type: "connect", profileName: "Different name" });
  assert.equal(second.profileID, first.profileID);
  assert.equal(second.profileName, "Manager profile");
  assert.equal(f.ports.length, 1);
});

test("unsuccessful pairing never marks profile paired", async () => {
  const f = await fixture({ connectError: "unavailable" });
  const result = await f.connect();
  assert.equal(result.ok, false);
  assert.equal(result.error, ERRORS.unavailable);
  assert.equal(f.local.paired, false);
  assert.equal(f.alarms.length, 0);
});

test("save binds only successful active tab and never durably stores tab ID or URL", async () => {
  const f = await fixture();
  await f.connect();
  const saved = await f.save();
  assert.equal(saved.ok, true);
  assert.equal(saved.bound, true);
  assert.deepEqual(f.session.destinationTabs[DESTINATION], { tabID: 7, savedURL: URL });
  assert.equal(f.local.url, undefined);
  assert.equal(f.local.tabID, undefined);
  const message = f.sent.find(message => message.type === "save");
  assert.equal(message.url, URL);
  assert.equal(message.title, "Manager");
  assert.equal(message.destinationID, undefined);
});

test("save after denied host access cannot write native destination", async () => {
  const f = await fixture({ permission: false });
  await f.connect();
  assert.equal((await f.save()).error, ERRORS.permission);
  assert.equal(f.sent.some(message => message.type === "save"), false);
});

test("tab change before save prevents native mutation", async () => {
  const f = await fixture();
  await f.connect();
  f.navigate({ url: "https://foreign.example.test/" });
  assert.equal((await f.save()).error, ERRORS.changed);
  assert.equal(f.sent.some(message => message.type === "save"), false);
});

test("tab change during native save retains saved destination but does not bind wrong tab", async () => {
  const f = await fixture({ saveNavigates: true });
  await f.connect();
  const result = await f.save();
  assert.equal(result.ok, true);
  assert.equal(result.bound, false);
  assert.equal(f.destinations.length, 1);
  assert.equal(f.session.destinationTabs, undefined);
});

test("same-profile update preserves ID; wrong-profile update never reaches native", async () => {
  const f = await fixture();
  await f.connect();
  await f.save();
  const own = await f.save({ title: "Updated manager", destinationID: DESTINATION });
  assert.equal(own.destinationID, DESTINATION);
  assert.equal(f.destinations.length, 1);
  const count = f.sent.filter(message => message.type === "save").length;
  f.destinations[0].profileID = OTHER_PROFILE;
  await f.send({ type: "list" });
  assert.equal((await f.save({ destinationID: DESTINATION })).error, ERRORS.wrongProfile);
  assert.equal(f.sent.filter(message => message.type === "save").length, count);
});

test("messages from tab content or another extension are rejected", async () => {
  const f = await fixture();
  const callback = f.api.runtime.onMessage.listeners[0];
  let answered = false;
  assert.equal(callback({ type: "connect" }, { id: EXTENSION, url: URL }, () => { answered = true; }), false);
  assert.equal(callback({ type: "connect" }, { ...f.sender, id: "other-extension" }, () => { answered = true; }), false);
  assert.equal(answered, false);
});

test("paired disconnect schedules one 30-second alarm without retrying activation", async () => {
  const f = await fixture();
  await f.connect();
  f.ports[0].disconnect();
  await Promise.resolve();
  await Promise.resolve();
  assert.deepEqual(f.alarms, [["workbench-native-reconnect", { delayInMinutes: 0.5 }]]);
  assert.equal(f.sent.some(message => message.type === "activate"), false);
  assert.equal((await f.send({ type: "state" })).connected, false);
});
