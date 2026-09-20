import { FocusController, WorkbenchError, canonicalizeURL, cleanName, validID, permissionPattern, safeError } from "./core.js";
import { NativeClient } from "./native.js";

const RETRY_ALARM = "workbench-native-reconnect";
const focus = new FocusController(chrome);
const activeFocus = new Set();
const client = new NativeClient(chrome, {
  onFocus: async message => {
    const controller = new AbortController();
    activeFocus.add(controller);
    let timer;
    try {
      return await Promise.race([
        focus.focus(message, { signal: controller.signal }),
        new Promise((_, reject) => {
          timer = setTimeout(() => { controller.abort(); reject(new WorkbenchError("timeout")); }, 8_000);
        }),
      ]);
    } finally { clearTimeout(timer); activeFocus.delete(controller); }
  },
  onDisconnect: () => {
    for (const controller of activeFocus) controller.abort();
    void scheduleRetry();
  },
});

async function profileState() {
  const { profileID, profileName, paired } = await chrome.storage.local.get(["profileID", "profileName", "paired"]);
  return { profileID: validID(profileID) ? profileID.toLowerCase() : null,
    profileName: typeof profileName === "string" ? profileName : "", paired: paired === true && validID(profileID) };
}

async function scheduleRetry() {
  try { if ((await profileState()).paired) await chrome.alarms.create(RETRY_ALARM, { delayInMinutes: 0.5 }); }
  catch { /* Popup Retry remains available. */ }
}

async function reconnect() {
  const profile = await profileState();
  if (!profile.paired) return;
  try { await client.connect(profile); await chrome.alarms.clear(RETRY_ALARM); }
  catch { await scheduleRetry(); }
}

async function currentTab() {
  const [tab] = await chrome.tabs.query({ active: true, lastFocusedWindow: true });
  if (!tab || tab.incognito || !Number.isInteger(tab.id) || tab.id < 0) throw new WorkbenchError("tab");
  const rawURL = tab.pendingUrl || tab.url;
  const url = canonicalizeURL(rawURL);
  const allowed = await chrome.permissions.contains({ origins: [permissionPattern(url)] });
  return { tabID: tab.id, url, allowed, stripped: Boolean(new URL(rawURL).search || new URL(rawURL).hash) };
}

async function handle(message) {
  if (!message || typeof message !== "object") throw new WorkbenchError("invalidMessage");
  if (message.type === "state") {
    const profile = await profileState();
    let tab = null;
    try { tab = await currentTab(); } catch { /* Saving disabled for non-web tabs. */ }
    return { ok: true, ...profile, connected: client.ready, destinations: client.destinations, tab };
  }
  if (message.type === "connect") {
    const existing = await profileState();
    const profileName = existing.paired ? cleanName(existing.profileName) : cleanName(message.profileName);
    const profileID = existing.profileID ?? crypto.randomUUID();
    await chrome.storage.local.set({ profileID, profileName, paired: existing.paired });
    const result = await client.connect({ profileID, profileName });
    await chrome.storage.local.set({ profileID, profileName, paired: true });
    await chrome.alarms.clear(RETRY_ALARM);
    return { ...result, profileID, profileName, paired: true, connected: true };
  }
  if (message.type === "list") return client.request("list");
  if (message.type === "activate") {
    if (!validID(message.destinationID)) throw new WorkbenchError("invalidMessage");
    return client.request("activate", { destinationID: message.destinationID });
  }
  if (message.type === "save") {
    const profile = await profileState();
    if (!profile.paired || !client.ready) throw new WorkbenchError("profile");
    const title = cleanName(message.title);
    const url = canonicalizeURL(message.url);
    if (!Number.isInteger(message.tabID) || message.tabID < 0) throw new WorkbenchError("tab");
    if (message.destinationID !== undefined) {
      if (!validID(message.destinationID)) throw new WorkbenchError("invalidMessage");
      const existing = client.destinations.find(item => item.id === message.destinationID);
      if (!existing) throw new WorkbenchError("missing");
      if (existing.profileID !== profile.profileID) throw new WorkbenchError("wrongProfile");
    }
    if (!await chrome.permissions.contains({ origins: [permissionPattern(url)] })) throw new WorkbenchError("permission");
    const before = await currentTab();
    if (before.tabID !== message.tabID || before.url !== url) throw new WorkbenchError("changed");
    const payload = { title, url };
    if (message.destinationID !== undefined) payload.destinationID = message.destinationID;
    const result = await client.request("save", payload);
    let bound = false;
    try {
      const after = await currentTab();
      if (after.tabID === message.tabID && after.url === url) {
        await focus.remember(result.destinationID, message.tabID, url);
        bound = true;
      }
    } catch { /* The saved destination is authoritative even if its tab just closed. */ }
    return { ...result, bound };
  }
  throw new WorkbenchError("invalidMessage");
}

chrome.runtime.onMessage.addListener((message, sender, sendResponse) => {
  if (sender.id !== chrome.runtime.id || sender.url !== chrome.runtime.getURL("popup.html")) return false;
  handle(message).then(sendResponse, error => sendResponse({ ok: false, error: safeError(error) }));
  return true;
});
chrome.runtime.onStartup.addListener(() => { void reconnect(); });
chrome.runtime.onInstalled.addListener(() => { void reconnect(); });
chrome.alarms.onAlarm.addListener(alarm => { if (alarm.name === RETRY_ALARM) void reconnect(); });

// A worker restarted by a popup also reattaches a previously paired profile.
// No automatic command activates a destination or creates a tab.
void reconnect();
