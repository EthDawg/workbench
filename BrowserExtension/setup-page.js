import { ERRORS, safeError, WorkbenchError } from "./core.js";
const element = id => document.getElementById(id);
let busy = false;
let recovery = null;
function feedback(text, error = false) {
  const target = element("feedback"); target.textContent = text; target.hidden = !text;
  target.dataset.error = String(error); target.setAttribute("role", error ? "alert" : "status");
}
async function request(message) {
  const reply = await chrome.runtime.sendMessage(message);
  if (!reply?.ok) throw new WorkbenchError(Object.entries(ERRORS).find(([, value]) => value === reply?.error)?.[0] ?? "setupUncertain");
  return reply;
}
async function refresh() {
  recovery = null; element("recover").hidden = true;
  const state = await request({ type: "setupState" });
  element("profile").textContent = state.profileName || "This Chrome profile · connect using the toolbar popup";
  element("grant").hidden = state.permission;
  element("root-controls").hidden = !state.permission;
  element("root").replaceChildren(new Option("Choose a location…", ""));
  for (const root of state.roots) element("root").add(new Option(root.title, root.id));
  element("root").value = state.rootID ?? "";
  element("uncertain").hidden = !state.uncertain;
  recovery = state.recovery;
  element("recover").hidden = !recovery;
  if (state.uncertain) feedback(ERRORS.setupUncertain, true);
  else if (state.permission && !state.roots.length) feedback("No writable local bookmark location is available. Use Chrome Sync for synced bookmarks.", true);
}
async function perform(action) {
  if (busy) return; busy = true;
  for (const control of document.querySelectorAll("button,select")) control.disabled = true;
  try { await action(); } catch (error) { feedback(safeError(error, "setupUncertain"), true); }
  finally { busy = false; for (const control of document.querySelectorAll("button,select")) control.disabled = false; }
}
element("grant").addEventListener("click", () => {
  if (busy) return;
  // Request directly in the click handler. No native command can grant this.
  const permission = chrome.permissions.request({ permissions: ["bookmarks"] });
  void perform(async () => {
    if (!await permission) throw new WorkbenchError("setupPermission");
    feedback("Bookmark access allowed. Choose a local location; no pack has been applied."); await refresh();
  });
});
element("save-root").addEventListener("click", () => { void perform(async () => {
  await request({ type: "setupRoot", rootID: element("root").value });
  feedback("Location saved. Review your pack in Workbench before applying bookmarks."); await refresh();
}); });
element("recover").addEventListener("click", () => {
  if (busy || !recovery) return;
  const selected = { ...recovery };
  const confirmed = window.confirm("Keep ALL existing Chrome bookmarks and forget Workbench ownership of ONLY the interrupted pack?\n\nNothing in Chrome will be deleted or changed now. Workbench will stop managing this pack's existing copy. The next review will offer a fresh copy and applying it can DUPLICATE links already kept. Other packs and settings are preserved.\n\nContinue with a fresh copy?");
  if (!confirmed) return;
  void perform(async () => {
    await request({ type: "setupRecover", ...selected, confirmed: true });
    feedback("Existing bookmarks kept. Review this pack again in Workbench: applying a fresh copy can duplicate the kept links.");
    await refresh();
  });
});
element("refresh").addEventListener("click", () => { void perform(async () => { feedback(""); await refresh(); }); });
for (const button of document.querySelectorAll("[data-chrome]")) button.addEventListener("click", () => {
  void perform(async () => { await chrome.tabs.create({ url: button.dataset.chrome }); });
});
void perform(refresh);
