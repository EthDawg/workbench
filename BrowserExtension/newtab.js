import { openDefaultTab, redirectNewTab } from "./default-tab.js";
import { safeError } from "./core.js";
const button = document.getElementById("open-default-tab");
function feedback(error) {
  const status = document.getElementById("feedback");
  status.textContent = safeError(error, "defaultTabFailed"); status.hidden = false;
  status.dataset.error = "true"; status.setAttribute("role", "alert");
}
button.addEventListener("click", async () => {
  button.disabled = true;
  try { await openDefaultTab(chrome); } catch (error) { feedback(error); }
  finally { button.disabled = false; }
});
void redirectNewTab(chrome, window.location).catch(feedback);
