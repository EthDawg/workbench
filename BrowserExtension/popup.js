import { ERRORS, WorkbenchError, cleanName, permissionPattern, safeError } from "./core.js";

const element = id => document.getElementById(id);
let state = { paired: false, connected: false, destinations: [], tab: null };
let busy = false;

function feedback(message = "", error = false) {
  const target = element("feedback");
  target.textContent = message;
  target.hidden = !message;
  target.dataset.error = String(error);
  target.setAttribute("role", error ? "alert" : "status");
}

async function request(message) {
  let result;
  try { result = await chrome.runtime.sendMessage(message); } catch { throw new WorkbenchError("unavailable"); }
  if (!result?.ok) {
    const known = Object.entries(ERRORS).find(([, text]) => text === result?.error);
    throw new WorkbenchError(known?.[0] ?? "failed");
  }
  return result;
}

function setBusy(value) {
  busy = value;
  for (const control of document.querySelectorAll("button,input,select")) control.disabled = value;
  if (!value) {
    element("save-button").disabled = !state.connected || !state.tab;
    element("refresh").disabled = !state.connected;
    for (const button of element("destinations").querySelectorAll("button")) button.disabled = !state.connected;
  }
  document.body.setAttribute("aria-busy", String(value));
}

function renderDestinations() {
  const term = element("search").value.trim().toLocaleLowerCase();
  const items = state.destinations.filter(item => `${item.title} ${item.profileName}`.toLocaleLowerCase().includes(term));
  const list = element("destinations");
  list.replaceChildren();
  for (const item of items) {
    const row = document.createElement("li");
    const button = document.createElement("button");
    button.type = "button";
    button.className = "destination";
    button.disabled = busy || !state.connected;
    button.setAttribute("aria-label", `Open ${item.title} in ${item.profileName}${item.connected ? "" : ", profile offline"}`);
    const icon = document.createElement("span");
    icon.className = "destination-icon";
    icon.textContent = "↗";
    icon.setAttribute("aria-hidden", "true");
    const copy = document.createElement("span");
    copy.className = "destination-copy";
    const title = document.createElement("span");
    title.className = "destination-title";
    title.textContent = item.title;
    const detail = document.createElement("span");
    detail.className = "destination-detail";
    detail.textContent = `${item.profileName} · ${item.connected ? "Connected" : "Open this profile to connect"}`;
    copy.append(title, detail);
    const arrow = document.createElement("span");
    arrow.className = "destination-arrow";
    arrow.textContent = "›";
    arrow.setAttribute("aria-hidden", "true");
    button.append(icon, copy, arrow);
    button.addEventListener("click", () => activate(item));
    row.append(button);
    list.append(row);
  }
  element("empty").hidden = items.length > 0 || !state.connected;
  element("empty").textContent = term ? "No destinations match that search."
    : "No destinations yet. Save a tab below to make your first shortcut.";
}

function renderSave() {
  const select = element("save-mode");
  const selected = select.value;
  select.replaceChildren(new Option("Create a new destination", ""));
  for (const item of state.destinations.filter(item => item.profileID === state.profileID)) select.add(new Option(`Update ${item.title}`, item.id));
  if ([...select.options].some(option => option.value === selected)) select.value = selected;
  element("save-profile").textContent = state.profileName;
  element("current-url").textContent = state.tab?.url ?? "No web address available";
  element("stripped").hidden = !state.tab?.stripped;
  element("tab-unavailable").hidden = Boolean(state.tab);
  updateSaveSelection(false);
}

function updateSaveSelection(copyTitle = true) {
  const item = state.destinations.find(item => item.id === element("save-mode").value && item.profileID === state.profileID);
  element("old-address").hidden = !item;
  element("old-url").textContent = item?.url ?? "";
  element("new-address-label").textContent = item ? "New address" : "Address to save";
  element("save-button").textContent = state.tab && !state.tab.allowed ? "Allow this site" : item ? "Update to this tab" : "Save destination";
  element("permission-step").hidden = !state.tab || state.tab.allowed;
  if (copyTitle) element("destination-title").value = item?.title ?? "";
}

function render() {
  element("setup").hidden = state.paired;
  element("paired").hidden = !state.paired;
  element("connection-state").textContent = state.connected ? "Connected" : "Not connected";
  element("connection-state").dataset.connected = String(state.connected);
  element("current-profile").textContent = state.profileName || "Chrome connection";
  element("offline").hidden = state.connected;
  if (!state.paired && !element("profile-name").value) element("profile-name").value = state.profileName || "";
  renderDestinations();
  renderSave();
  setBusy(busy);
}

async function perform(action) {
  if (busy) return;
  setBusy(true);
  try { await action(); }
  catch (error) {
    // Connection status can change while an action is pending. Read current
    // adapter state before rendering recovery; never repeat the action.
    try {
      const latest = await chrome.runtime.sendMessage({ type: "state" });
      if (latest?.ok) { state = latest; render(); }
    } catch { state.connected = false; render(); }
    feedback(safeError(error), true);
  }
  finally {
    setBusy(false);
    if (document.activeElement === document.body) (state.paired ? element("search") : element("profile-name")).focus();
  }
}

async function connect() {
  feedback("Connecting this profile…");
  const result = await request({ type: "connect", profileName: element("profile-name").value });
  state = { ...state, ...result };
  render();
  feedback("Profile connected. Choose a destination or save this tab.");
  element("search").focus();
}

async function activate(item) {
  await perform(async () => {
    feedback(`Opening ${item.title} in ${item.profileName}…`);
    const result = await request({ type: "activate", destinationID: item.id });
    feedback(result.status === "opened" ? "Opened the saved address. Chrome confirmed the tab and window are active."
      : "Chrome confirmed the destination tab and window are active.");
  });
}

element("connect-form").addEventListener("submit", event => { event.preventDefault(); void perform(connect); });
element("retry").addEventListener("click", () => { void perform(connect); });
element("refresh").addEventListener("click", () => { void perform(async () => {
  const result = await request({ type: "list" });
  state.destinations = result.destinations;
  render();
  feedback("Destinations refreshed.");
}); });
element("save-mode").addEventListener("change", () => updateSaveSelection());
element("search").addEventListener("input", renderDestinations);
element("search").addEventListener("keydown", event => {
  if (event.key === "ArrowDown") { event.preventDefault(); element("destinations").querySelector("button")?.focus(); }
  if (event.key === "Enter") { event.preventDefault(); element("destinations").querySelector("button")?.click(); }
});
element("destinations").addEventListener("keydown", event => {
  if (!["ArrowUp", "ArrowDown"].includes(event.key)) return;
  const buttons = [...element("destinations").querySelectorAll("button")];
  const index = buttons.indexOf(document.activeElement);
  if (index < 0) return;
  event.preventDefault();
  if (event.key === "ArrowUp" && index === 0) element("search").focus();
  else buttons[Math.min(buttons.length - 1, Math.max(0, index + (event.key === "ArrowDown" ? 1 : -1)))]?.focus();
});
document.addEventListener("keydown", event => { if (event.key === "Escape") window.close(); });
element("save-form").addEventListener("submit", event => {
  event.preventDefault();
  if (busy || !state.tab || !state.connected) return;
  let title;
  try { title = cleanName(element("destination-title").value); } catch (error) { feedback(safeError(error), true); return; }
  const tab = { ...state.tab };
  const destinationID = element("save-mode").value;
  if (!tab.allowed) {
    // Permission UI destroys an action popup. Keep only this explicit, temporary
    // draft, never a queued save that could run after a denied permission.
    void chrome.storage.session.set({ saveDraft: { title, destinationID, url: tab.url, tabID: tab.tabID, expiresAt: Date.now() + 900_000 } });
    const permission = chrome.permissions.request({ origins: [permissionPattern(tab.url)] });
    void perform(async () => {
      if (!await permission) throw new WorkbenchError("permission");
      state.tab.allowed = true; renderSave();
      feedback("Site allowed. Save the destination when you are ready.");
    });
    return;
  }
  // This request is made directly in the Save gesture, before messaging or
  // any other async work; Chrome owns the per-host permission prompt.
  const permission = chrome.permissions.request({ origins: [permissionPattern(tab.url)] });
  void perform(async () => {
    if (!await permission) throw new WorkbenchError("permission");
    feedback(destinationID ? "Updating destination…" : "Saving destination…");
    const message = { type: "save", title, url: tab.url, tabID: tab.tabID };
    if (destinationID) message.destinationID = destinationID;
    const result = await request(message);
    await chrome.storage.session.remove("saveDraft");
    state.destinations = result.destinations;
    element("destination-title").value = "";
    element("save-mode").value = "";
    render();
    feedback(result.bound ? `${title} ${destinationID ? "updated" : "saved"} in ${state.profileName}.`
      : "Destination saved. The tab changed before it could be linked; update from the right tab if several match.");
  });
});

render();
void perform(async () => {
  state = await request({ type: "state" });
  render();
  // Opening the popup refreshes names only. It never activates a destination.
  if (state.connected) {
    const result = await request({ type: "list" });
    state.destinations = result.destinations;
    render();
  }
  const { saveDraft } = await chrome.storage.session.get("saveDraft");
  if (saveDraft && saveDraft.expiresAt > Date.now() && state.tab?.tabID === saveDraft.tabID && state.tab?.url === saveDraft.url) {
    element("save-details").open = true;
    element("save-mode").value = saveDraft.destinationID || "";
    element("destination-title").value = saveDraft.title;
    updateSaveSelection(false);
    feedback(state.tab.allowed ? "Site allowed. Save the destination to finish." : "Your draft is ready. Allow this site to continue.");
  }
  (state.paired ? element("search") : element("profile-name")).focus();
});
