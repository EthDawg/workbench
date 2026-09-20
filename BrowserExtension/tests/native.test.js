import test from "node:test";
import assert from "node:assert/strict";
import { NativeClient, nativeError } from "../native.js";
import { HOST_NAME, ERRORS, WorkbenchError } from "../core.js";

const PROFILE = { profileID: "00000000-0000-4000-8000-000000000001", profileName: "Manager" };
const DESTINATION = { id: "00000000-0000-4000-8000-000000000002", profileID: PROFILE.profileID,
  profileName: "Manager", title: "Start", url: "https://manager.example.test/", connected: true };
const event = () => {
  const listeners = [];
  return { addListener: fn => listeners.push(fn), emit: value => { for (const listener of listeners) listener(value); } };
};
function fixture(options = {}) {
  let sequence = 10;
  const sent = [];
  const ports = [];
  const api = { runtime: { connectNative: name => {
    assert.equal(name, HOST_NAME);
    const port = { onMessage: event(), onDisconnect: event(),
      postMessage: message => sent.push(message), disconnect() { this.onDisconnect.emit(); } };
    ports.push(port);
    return port;
  } } };
  const client = new NativeClient(api, { timeoutMS: 100, uuid: () => `00000000-0000-4000-8000-${String(sequence++).padStart(12, "0")}`, ...options });
  const reply = (request, payload = {}, port = ports.at(-1)) => port.onMessage.emit({ v: 1, id: request.id, type: "result", ok: true, ...payload });
  const connect = async () => { const pending = client.connect(PROFILE); reply(sent.at(-1), { destinations: [DESTINATION] }); return pending; };
  return { client, api, sent, ports, reply, connect };
}

test("native port sends hello first and shares one connection across callers", async () => {
  const f = fixture();
  const first = f.client.connect(PROFILE);
  const second = f.client.connect(PROFILE);
  assert.equal(f.ports.length, 1);
  assert.equal(f.sent[0].type, "hello");
  assert.equal(f.sent[0].profileID, PROFILE.profileID);
  await assert.rejects(f.client.request("list"), { code: "unavailable" });
  f.reply(f.sent[0], { destinations: [DESTINATION] });
  await Promise.all([first, second]);
  assert.equal(f.client.ready, true);
  assert.deepEqual(f.client.destinations, [DESTINATION]);
});

test("focus before accepted hello is ignored", async () => {
  let focuses = 0;
  const f = fixture({ onFocus: async () => { focuses++; } });
  const connection = f.client.connect(PROFILE);
  f.ports[0].onMessage.emit({ v: 1, id: DESTINATION.id, type: "focus", destinationID: DESTINATION.id, url: DESTINATION.url });
  f.reply(f.sent[0], { destinations: [] });
  await connection;
  assert.equal(focuses, 0);
});

test("result matches request IDs and validates its typed payload", async () => {
  const f = fixture();
  await f.connect();
  const list = f.client.request("list");
  const request = f.sent.at(-1);
  f.reply({ id: DESTINATION.id }, { destinations: [] });
  assert.equal(f.client.pending.size, 1);
  f.reply(request, { destinations: [DESTINATION] });
  assert.deepEqual((await list).destinations, [DESTINATION]);
  const save = f.client.request("save", { title: "Start", url: DESTINATION.url });
  f.reply(f.sent.at(-1), { destinations: [], destinationID: "invalid" });
  await assert.rejects(save, { code: "invalidMessage" });
});

test("native error allowlist protects UI from raw payloads", () => {
  assert.equal(nativeError("offline").message, ERRORS.offline);
  assert.equal(nativeError(ERRORS.ambiguous).message, ERRORS.ambiguous);
  assert.equal(nativeError("file path /private/secrets").message, ERRORS.failed);
});

test("native disconnect rejects activation as uncertain, other work as unavailable", async () => {
  let disconnected = 0;
  const f = fixture({ onDisconnect: () => disconnected++ });
  await f.connect();
  const activate = f.client.request("activate", { destinationID: DESTINATION.id });
  const list = f.client.request("list");
  const checked = Promise.all([assert.rejects(activate, { code: "timeout" }), assert.rejects(list, { code: "unavailable" })]);
  f.ports[0].disconnect();
  await checked;
  assert.equal(f.client.ready, false);
  assert.equal(f.client.pending.size, 0);
  assert.equal(disconnected, 1);
  assert.deepEqual(f.client.destinations, []);
});

test("request times out without retrying an uncertain activation", async () => {
  const f = fixture({ timeoutMS: 10 });
  await f.connect();
  await assert.rejects(f.client.request("activate", { destinationID: DESTINATION.id }), { code: "timeout" });
  assert.equal(f.sent.filter(message => message.type === "activate").length, 1);
  assert.equal(f.client.pending.size, 0);
});

test("twenty pending requests are bounded", async () => {
  const f = fixture();
  await f.connect();
  const requests = Array.from({ length: 20 }, () => f.client.request("list"));
  await assert.rejects(f.client.request("list"), { code: "busy" });
  for (const message of f.sent.slice(1)) f.reply(message, { destinations: [] });
  await Promise.all(requests);
});

test("focus result returns same wire ID and known error code", async () => {
  const f = fixture({ onFocus: async () => { throw new WorkbenchError("ambiguous"); } });
  await f.connect();
  await f.client.receive({ v: 1, id: DESTINATION.id, type: "focus", destinationID: DESTINATION.id, url: DESTINATION.url }, f.ports[0]);
  assert.deepEqual(f.sent.at(-1), { v: 1, id: DESTINATION.id, type: "focused", ok: false, error: "ambiguous" });
});

test("focus finishing after disconnect cannot report success to new connection", async () => {
  let complete;
  const f = fixture({ onFocus: () => new Promise(resolve => { complete = resolve; }) });
  await f.connect();
  const response = f.client.receive({ v: 1, id: DESTINATION.id, type: "focus", destinationID: DESTINATION.id, url: DESTINATION.url }, f.ports[0]);
  f.ports[0].disconnect();
  await f.connect();
  complete({ ok: true, status: "focused" });
  await response;
  assert.equal(f.sent.some(message => message.type === "focused"), false);
});

test("stale port replies cannot satisfy new connection requests", async () => {
  const f = fixture();
  await f.connect();
  const oldPort = f.ports[0];
  oldPort.disconnect();
  await f.connect();
  const list = f.client.request("list");
  const request = f.sent.at(-1);
  f.reply(request, { destinations: [] }, oldPort);
  assert.equal(f.client.pending.size, 1);
  f.reply(request, { destinations: [DESTINATION] });
  assert.equal((await list).destinations.length, 1);
});

test("invalid or oversized native messages are ignored", async () => {
  const f = fixture();
  await f.connect();
  const pending = f.client.request("list");
  const message = f.sent.at(-1);
  f.ports[0].onMessage.emit({ ...message, type: "result", ok: true, v: 2, destinations: [] });
  f.ports[0].onMessage.emit({ ...message, type: "result", ok: true, destinations: [], excess: "x".repeat(65_536) });
  assert.equal(f.client.pending.size, 1);
  f.reply(message, { destinations: [] });
  await pending;
});

test("failed hello leaves no ready connection and supports explicit retry", async () => {
  const f = fixture();
  const first = f.client.connect(PROFILE);
  f.reply(f.sent[0], { ok: false, error: "duplicateProfile" });
  await assert.rejects(first, { code: "duplicateProfile" });
  assert.equal(f.client.ready, false);
  assert.equal(f.client.port, null);
  await f.connect();
  assert.equal(f.client.ready, true);
});
