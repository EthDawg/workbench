import { readDefaultTab, saveDefaultTab, openDefaultTab } from "./default-tab.js";
import { safeError } from "./core.js";

const element = id => document.getElementById(id);
const form = element("default-tab-form");
const status = element("default-tab-feedback");
let busy = false;
function feedback(text, error = false) {
  status.textContent = text; status.hidden = !text;
  status.dataset.error = String(error); status.setAttribute("role", error ? "alert" : "status");
}
async function perform(action) {
  if (busy) return;
  busy = true;
  for (const control of form.querySelectorAll("button,input")) control.disabled = true;
  try { await action(); }
  catch (error) { feedback(safeError(error, "defaultTabFailed"), true); }
  finally {
    busy = false;
    for (const control of form.querySelectorAll("button,input")) control.disabled = false;
  }
}
function render(value) {
  element("default-url").value = value.url;
  element("redirect-new-tabs").checked = value.redirectNewTabs;
  element("open-on-startup").checked = value.openOnStartup;
}
form.addEventListener("submit", event => {
  event.preventDefault();
  void perform(async () => {
    const value = await saveDefaultTab(chrome, { version: 1, url: element("default-url").value.trim(),
      redirectNewTabs: element("redirect-new-tabs").checked, openOnStartup: element("open-on-startup").checked });
    render(value); feedback("Saved for this Chrome profile. Existing tabs have not changed.");
  });
});
element("open-default-tab").addEventListener("click", () => { void perform(async () => {
  await openDefaultTab(chrome); feedback("Opened the saved default address in a new tab.");
}); });
element("clear-default-tab").addEventListener("click", () => { void perform(async () => {
  render(await saveDefaultTab(chrome, { version: 1, url: "", redirectNewTabs: false, openOnStartup: false }));
  feedback("Address cleared and automatic opening stopped. New Tab still shows the Workbench page.");
}); });
void perform(async () => { render(await readDefaultTab(chrome)); });
