import { WorkbenchError } from "./core.js";
import { setupURL } from "./setup.js";

const KEY = "defaultTab";
const empty = () => ({ version: 1, url: "", redirectNewTabs: false, openOnStartup: false });

export function cleanDefaultTab(value) {
  try {
    if (!value || typeof value !== "object" || Array.isArray(value)
        || Object.keys(value).some(key => !["version", "url", "redirectNewTabs", "openOnStartup"].includes(key))
        || value.version !== 1 || typeof value.url !== "string"
        || typeof value.redirectNewTabs !== "boolean" || typeof value.openOnStartup !== "boolean") throw new Error();
    const url = value.url === "" ? "" : setupURL(value.url);
    if (!url && (value.redirectNewTabs || value.openOnStartup)) throw new Error();
    return { version: 1, url, redirectNewTabs: value.redirectNewTabs, openOnStartup: value.openOnStartup };
  } catch { throw new WorkbenchError("defaultTabInvalid"); }
}

export async function readDefaultTab(api) {
  const value = (await api.storage.local.get(KEY))[KEY];
  return value === undefined ? empty() : cleanDefaultTab(value);
}

export async function saveDefaultTab(api, value) {
  const settings = cleanDefaultTab(value);
  await api.storage.local.set({ [KEY]: settings });
  return settings;
}

export async function openDefaultTab(api, { startup = false } = {}) {
  const settings = await readDefaultTab(api);
  if (startup && !settings.openOnStartup) return false;
  if (!settings.url) throw new WorkbenchError("defaultTabMissing");
  // No tabs permission or site access is needed to create a tab. Never inspect
  // or replace existing tabs; a startup failure is never retried on reconnect.
  await api.tabs.create({ url: settings.url, active: !startup });
  return true;
}

export async function redirectNewTab(api, location) {
  const settings = await readDefaultTab(api);
  if (!settings.redirectNewTabs) return false;
  // This runs only inside our bundled New Tab page, not a content script.
  location.replace(settings.url);
  return true;
}
