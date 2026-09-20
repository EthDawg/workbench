export const HOST_NAME = "com.ethdawg.workbench.browser";
export const MAX_PACKET_BYTES = 65_536;
export const ERRORS = Object.freeze({
  unavailable: "Open Workbench and enable Chrome connection in Saved resources, then Retry.",
  invalidURL: "Choose a complete http or https address without a username or password.",
  invalidName: "Enter a name of 1–80 characters without control characters.",
  invalidMessage: "Workbench could not read this request. Retry after updating the app and extension.",
  permission: "Open this destination in its paired profile, then save or update it to allow this address.",
  ambiguous: "Several tabs match. Open the right tab, then update this destination in Workbench.",
  busy: "Finish the current recording, keyboard practice, switch or resource edit, then try again.",
  timeout: "Opening could not be confirmed. Check Chrome before trying again.",
  changed: "The tab changed while opening. Open the right tab, then update this destination.",
  failed: "Chrome could not focus this destination. Check the browser, then try again.",
  profile: "Connect this Chrome profile before saving a destination.",
  wrongProfile: "Update this destination from its paired Chrome profile.",
  tab: "Open a regular web tab in this profile, then reopen Workbench.",
  offline: "Open the destination’s Chrome profile and connect Workbench there, then try again.",
  missing: "This destination is no longer saved. Refresh the list in Workbench.",
  invalid: "Workbench could not read this request. Retry after updating the app and extension.",
  saveFailed: "Workbench could not save this destination. Open Saved resources and check the connection.",
  duplicateProfile: "This profile is already connected elsewhere. Close its other Workbench connection, then Retry.",
  capacity: "The Chrome destination list is too large. Remove unused destinations or shorten their saved addresses in Saved resources.",
});

export class WorkbenchError extends Error {
  constructor(code) { super(ERRORS[code] ?? ERRORS.failed); this.code = code; }
}

export function safeError(error, fallback = "failed") {
  return error instanceof WorkbenchError ? error.message : ERRORS[fallback];
}

export function validID(value) {
  return typeof value === "string" && /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i.test(value);
}

export function cleanName(value) {
  if (typeof value !== "string") throw new WorkbenchError("invalidName");
  const name = value.trim();
  if (!name || [...name].length > 80 || /[\u0000-\u001f\u007f]/u.test(name)) throw new WorkbenchError("invalidName");
  return name;
}

export function canonicalizeURL(value) {
  if (typeof value !== "string" || value.length > 4096 || !/^https?:\/\/[^/?#]+/i.test(value) || /[\s\u0000-\u001f\u007f\\]/u.test(value)) {
    throw new WorkbenchError("invalidURL");
  }
  let url;
  try { url = new URL(value); } catch { throw new WorkbenchError("invalidURL"); }
  const authority = value.slice(value.indexOf("//") + 2).split(/[/?#]/, 1)[0];
  if (!url.hostname || authority.includes("@") || url.username || url.password || !["http:", "https:"].includes(url.protocol)) throw new WorkbenchError("invalidURL");
  url.search = "";
  url.hash = "";
  if (url.href.length > 4096) throw new WorkbenchError("invalidURL");
  return url.href;
}

// Chrome host grants are per scheme and hostname. Every tab decision below
// separately checks URL.origin, so a different port never matches a destination.
export function permissionPattern(value) {
  const url = new URL(canonicalizeURL(value));
  return `${url.protocol}//${url.hostname}/*`;
}

function safeCanonicalURL(value) {
  try { return canonicalizeURL(value); } catch { return null; }
}

function effectiveTabURL(tab) {
  // A pending navigation takes priority over the old document. A foreign or
  // hidden pending address must not be mistaken for the still-visible old URL.
  return tab?.pendingUrl || tab?.url;
}

export function matchesRememberedTab(tab, savedURL) {
  if (!tab || tab.incognito || !Number.isInteger(tab.id) || tab.id < 0) return false;
  const current = safeCanonicalURL(effectiveTabURL(tab));
  const saved = safeCanonicalURL(savedURL);
  return Boolean(current && saved && new URL(current).origin === new URL(saved).origin);
}

export function matchesExactTab(tab, savedURL) {
  return matchesRememberedTab(tab, savedURL) && safeCanonicalURL(effectiveTabURL(tab)) === safeCanonicalURL(savedURL);
}

export function validEnvelope(message) {
  try {
    return Boolean(message && !Array.isArray(message) && message.v === 1 && validID(message.id)
      && typeof message.type === "string" && new TextEncoder().encode(JSON.stringify(message)).length <= MAX_PACKET_BYTES);
  } catch { return false; }
}

export function cleanDestinations(value) {
  if (!Array.isArray(value) || value.length > 250) throw new WorkbenchError("invalidMessage");
  return value.map(item => {
    if (!item || !validID(item.id) || !validID(item.profileID) || typeof item.connected !== "boolean") throw new WorkbenchError("invalidMessage");
    return { id: item.id.toLowerCase(), title: cleanName(item.title), profileName: cleanName(item.profileName),
      profileID: item.profileID.toLowerCase(), url: canonicalizeURL(item.url), connected: item.connected };
  });
}

export class FocusController {
  constructor(api, { timeoutMS = 8_000, now = Date.now } = {}) {
    this.api = api;
    this.timeoutMS = timeoutMS;
    this.now = now;
    this.busy = false;
    this.bindingWrite = Promise.resolve();
  }

  async bindings() {
    const data = await this.api.storage.session.get("destinationTabs");
    return data.destinationTabs && typeof data.destinationTabs === "object" && !Array.isArray(data.destinationTabs)
      ? { ...data.destinationTabs } : {};
  }

  async remember(destinationID, tabID, savedURL) {
    if (!validID(destinationID) || !Number.isInteger(tabID) || tabID < 0) throw new WorkbenchError("invalidMessage");
    destinationID = destinationID.toLowerCase();
    const canonicalURL = canonicalizeURL(savedURL);
    return this.mutateBindings(bindings => { bindings[destinationID] = { tabID, savedURL: canonicalURL }; });
  }

  async forget(destinationID) {
    return this.mutateBindings(bindings => { delete bindings[destinationID]; });
  }

  mutateBindings(change) {
    const job = this.bindingWrite.then(async () => {
      const bindings = await this.bindings();
      change(bindings);
      await this.api.storage.session.set({ destinationTabs: bindings });
    });
    this.bindingWrite = job.catch(() => {});
    return job;
  }

  async focus({ destinationID, url, expiresAt }, { signal } = {}) {
    if (!validID(destinationID)) throw new WorkbenchError("invalidMessage");
    destinationID = destinationID.toLowerCase();
    const savedURL = canonicalizeURL(url);
    if (this.busy) throw new WorkbenchError("busy");
    const startedAt = this.now();
    if (expiresAt !== undefined && (!Number.isFinite(expiresAt) || expiresAt <= startedAt || expiresAt > startedAt + 10_000)) {
      throw new WorkbenchError("timeout");
    }
    this.busy = true;
    const deadline = Math.min(startedAt + this.timeoutMS, expiresAt ?? Infinity);
    const check = () => {
      if (signal?.aborted || this.now() >= deadline) throw new WorkbenchError("timeout");
    };
    try {
      check();
      if (!await this.api.permissions.contains({ origins: [permissionPattern(savedURL)] })) throw new WorkbenchError("permission");
      check();
      const bindings = await this.bindings();
      check();
      const remembered = bindings[destinationID];
      let tab;
      if (remembered?.savedURL === savedURL && Number.isInteger(remembered.tabID)) {
        try { tab = await this.api.tabs.get(remembered.tabID); } catch { /* Closed tab: resolve the exact saved address. */ }
        check();
        if (!matchesRememberedTab(tab, savedURL)) tab = undefined;
      }
      if (!tab) {
        await this.forget(destinationID);
        check();
        const candidates = await this.api.tabs.query({ url: permissionPattern(savedURL) });
        check();
        const matches = candidates.filter(candidate => matchesExactTab(candidate, savedURL));
        if (matches.length > 1) throw new WorkbenchError("ambiguous");
        tab = matches[0];
      }
      let status = "focused";
      if (!tab) {
        check();
        tab = await this.api.tabs.create({ url: savedURL, active: true });
        status = "opened";
        check();
      }
      // Re-read before any focus mutation: a tab may have closed or navigated
      // after the query. Never send an update containing a URL to an old tab.
      tab = await this.api.tabs.get(tab.id);
      check();
      if (!matchesRememberedTab(tab, savedURL)) throw new WorkbenchError("changed");
      const window = await this.api.windows.get(tab.windowId);
      check();
      if (window.incognito) throw new WorkbenchError("changed");
      await this.api.tabs.update(tab.id, { active: true });
      check();
      await this.api.windows.update(tab.windowId, window.state === "minimized"
        ? { focused: true, state: "normal" } : { focused: true });
      check();
      const verifiedTab = await this.api.tabs.get(tab.id);
      check();
      const verifiedWindow = await this.api.windows.get(tab.windowId);
      check();
      if (!verifiedTab.active || !verifiedWindow.focused || verifiedTab.windowId !== tab.windowId
        || verifiedWindow.incognito || !matchesRememberedTab(verifiedTab, savedURL)) throw new WorkbenchError("changed");
      await this.remember(destinationID, tab.id, savedURL);
      check();
      return { ok: true, status };
    } catch (error) {
      if (error instanceof WorkbenchError) throw error;
      throw new WorkbenchError("failed");
    } finally {
      this.busy = false;
    }
  }
}
