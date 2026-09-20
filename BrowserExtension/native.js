import { HOST_NAME, ERRORS, WorkbenchError, validEnvelope, validID, cleanName, cleanDestinations } from "./core.js";

export function nativeError(value, fallback = "failed") {
  if (typeof value === "string" && Object.hasOwn(ERRORS, value)) return new WorkbenchError(value);
  const entry = Object.entries(ERRORS).find(([, message]) => message === value);
  return new WorkbenchError(entry?.[0] ?? fallback);
}

export class NativeClient {
  constructor(api, { onFocus, onDisconnect = () => {}, timeoutMS = 15_000, uuid = () => crypto.randomUUID() } = {}) {
    this.api = api;
    this.onFocus = onFocus;
    this.onDisconnect = onDisconnect;
    this.timeoutMS = timeoutMS;
    this.uuid = uuid;
    this.port = null;
    this.ready = false;
    this.connecting = null;
    this.pending = new Map();
    this.destinations = [];
  }

  connect(profile) {
    if (this.ready) return Promise.resolve({ ok: true, destinations: this.destinations });
    if (this.connecting) return this.connecting;
    if (!validID(profile.profileID)) return Promise.reject(new WorkbenchError("profile"));
    let profileName;
    try { profileName = cleanName(profile.profileName); } catch (error) { return Promise.reject(error); }
    const job = (async () => {
      let port;
      try { port = this.api.runtime.connectNative(HOST_NAME); } catch { throw new WorkbenchError("unavailable"); }
      this.port = port;
      port.onMessage.addListener(message => { void this.receive(message, port); });
      port.onDisconnect.addListener(() => {
        // Consume lastError without copying host paths or raw diagnostics into UI.
        void this.api.runtime.lastError;
        this.disconnected(port);
      });
      try {
        const result = await this.send("hello", { profileID: profile.profileID, profileName }, true);
        if (this.port !== port) throw new WorkbenchError("unavailable");
        this.ready = true;
        return result;
      } catch (error) {
        this.disconnected(port);
        try { port.disconnect(); } catch { /* Already disconnected. */ }
        throw error;
      }
    })();
    this.connecting = job;
    job.then(() => { if (this.connecting === job) this.connecting = null; }, () => { if (this.connecting === job) this.connecting = null; });
    return job;
  }

  disconnected(port) {
    if (this.port !== port) return;
    this.ready = false;
    this.port = null;
    this.destinations = [];
    for (const pending of this.pending.values()) {
      clearTimeout(pending.timer);
      pending.reject(new WorkbenchError(pending.type === "activate" ? "timeout" : "unavailable"));
    }
    this.pending.clear();
    this.onDisconnect();
  }

  request(type, payload = {}) {
    if (!["list", "save", "activate"].includes(type)) return Promise.reject(new WorkbenchError("invalidMessage"));
    return this.send(type, payload, false);
  }

  send(type, payload, handshake) {
    if (!this.port || (!this.ready && !handshake)) return Promise.reject(new WorkbenchError("unavailable"));
    if (this.pending.size >= 20) return Promise.reject(new WorkbenchError("busy"));
    const id = this.uuid();
    const message = { ...payload, v: 1, id, type };
    if (!validEnvelope(message)) return Promise.reject(new WorkbenchError("invalidMessage"));
    return new Promise((resolve, reject) => {
      const timer = setTimeout(() => {
        this.pending.delete(id);
        reject(new WorkbenchError(type === "activate" ? "timeout" : "unavailable"));
      }, this.timeoutMS);
      this.pending.set(id, { resolve, reject, timer, type });
      try { this.port.postMessage(message); } catch {
        clearTimeout(timer);
        this.pending.delete(id);
        reject(new WorkbenchError(type === "activate" ? "timeout" : "unavailable"));
      }
    });
  }

  async receive(message, port) {
    if (port !== this.port || !validEnvelope(message)) return;
    if (message.type === "result") {
      const pending = this.pending.get(message.id);
      if (!pending) return;
      this.pending.delete(message.id);
      clearTimeout(pending.timer);
      if (message.ok !== true) {
        pending.reject(nativeError(message.error, pending.type === "hello" ? "unavailable" : "failed"));
        return;
      }
      try {
        const result = { ok: true };
        if (["hello", "list", "save"].includes(pending.type)) {
          result.destinations = cleanDestinations(message.destinations);
          this.destinations = result.destinations;
        }
        if (pending.type === "save") {
          if (!validID(message.destinationID)) throw new WorkbenchError("invalidMessage");
          result.destinationID = message.destinationID.toLowerCase();
        }
        if (pending.type === "activate") {
          if (!["focused", "opened"].includes(message.status)) throw new WorkbenchError("invalidMessage");
          result.status = message.status;
        }
        pending.resolve(result);
      } catch { pending.reject(new WorkbenchError("invalidMessage")); }
      return;
    }
    if (message.type !== "focus" || !this.ready || !this.onFocus) return;
    let result;
    try { result = await this.onFocus(message); }
    catch (error) { result = { ok: false, error: error instanceof WorkbenchError ? error.code : "failed" }; }
    if (this.port !== port || !this.ready) return;
    try { port.postMessage({ ...result, v: 1, id: message.id, type: "focused" }); }
    catch { /* Disconnect handler owns pending requests and recovery. */ }
  }
}
