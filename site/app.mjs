import { createReport, agentHandoff } from './report.mjs';
let report;
const form = document.getElementById('feedback-form');
const result = document.getElementById('report-result');
const appSelect = document.getElementById('feedback-app');
function invalidateReport() { result.hidden = true; report = undefined; document.getElementById('copy-status').textContent = ''; }
function selectFeedback(app) { appSelect.value = app; invalidateReport(); }
appSelect.addEventListener('change', () => selectFeedback(appSelect.value));
form.addEventListener('input', invalidateReport);
form.addEventListener('change', invalidateReport);
form.addEventListener('submit', event => {
  event.preventDefault();
  try {
    report = createReport(Object.fromEntries(new FormData(form)));
    document.getElementById('report-preview').textContent = report.body;
    const link = document.getElementById('github-report');
    // Avoid silent truncation by browsers/proxies for unusually long issue URLs.
    const fits = report.url.length <= 7500;
    link.href = fits ? report.url : `https://github.com/EthDawg/${report.app.repo}/issues/new`;
    link.textContent = fits ? 'Review on GitHub ↗' : 'Open GitHub, then paste report ↗';
    if (!fits) document.getElementById('copy-status').textContent = 'This draft is long. Copy it, then paste it into a new GitHub issue.';
    result.hidden = false;
    document.getElementById('report-title').focus();
  } catch (error) { document.getElementById('copy-status').textContent = error.message; }
});
async function copy(text, statusId) {
  const status = document.getElementById(statusId);
  try {
    await navigator.clipboard.writeText(text);
    status.textContent = 'Copied. Ready to paste.';
  } catch {
    const fallback = document.createElement('textarea');
    fallback.value = text; fallback.readOnly = true;
    fallback.setAttribute('aria-label', 'Text to copy manually');
    status.replaceChildren(document.createTextNode('Clipboard access is unavailable. Select and copy this text:'), fallback);
    fallback.focus(); fallback.select();
  }
}
document.getElementById('copy-report').addEventListener('click', () => { if (report) copy(report.body, 'copy-status'); });
document.getElementById('copy-feedback-agent').addEventListener('click', () => { if (report) copy(agentHandoff(report), 'copy-status'); });
document.getElementById('copy-agent').addEventListener('click', () => copy(agentHandoff(), 'agent-status'));
