import { currentRelease } from './release.mjs';
const version = currentRelease.tag.slice(1);
const source = `https://github.com/EthDawg/workbench/tree/v${version}`;
const documents = `https://github.com/EthDawg/workbench/blob/v${version}`;
const guide = `${documents}/CONTRIBUTING.md`;
export const apps = Object.freeze({
  voice: { name: 'Workbench · Speech', repo: 'workbench', version, guide },
  stagemark: { name: 'Workbench · Annotation and presentation', repo: 'workbench', version, guide }
});
const fields = ['app', 'version', 'environment', 'task', 'expected', 'observed', 'impact', 'help'];
export function normalizeReport(input) {
  const data = Object.fromEntries(fields.map(key => [key, String(input[key] ?? '').trim()]));
  if (!Object.hasOwn(apps, data.app)) throw new Error('Choose a Workbench area.');
  for (const key of ['version', 'environment', 'task', 'expected', 'observed']) {
    if (!data[key]) throw new Error('Complete the app, version, Mac, task, expected and observed fields.');
  }
  const limits = { version: 1200, environment: 160, task: 200, expected: 1000, observed: 1500, impact: 100, help: 100 };
  for (const [key, limit] of Object.entries(limits)) if (data[key].length > limit) throw new Error(`${key} is too long. Please keep the report concise.`);
  return data;
}
export function createReport(input) {
  const data = normalizeReport(input);
  const app = apps[data.app];
  const title = `[User experience] ${data.task.replace(/[\r\n]+/g, ' ').slice(0, 180)}`;
  const body = `## App and environment\n${app.name} ${data.version}\n${data.environment}\n\n## What I was trying to do\n${data.task}\n\n## What I expected\n${data.expected}\n\n## What I observed\n${data.observed}\n\n## Impact\n${data.impact || 'Not specified'}\n\n## How I can help\n${data.help || 'Not specified'}\n\n---\nReported through the Workbench guided trial. This is a user observation, not a confirmed diagnosis.\n`;
  const url = new URL(`https://github.com/EthDawg/${app.repo}/issues/new`);
  url.searchParams.set('title', title);
  url.searchParams.set('body', body);
  url.searchParams.set('labels', 'user feedback');
  return { title, body, url: url.href, app };
}
export function agentHandoff(report) {
  const intro = `Help me make a useful contribution to Workbench, a free MIT-licensed native Apple Silicon Mac app.\n\nThis website offers Workbench ${version}.\nSource for this release: ${source}\n\nRead ${guide} and the product contract at ${documents}/docs/workbench.md. Use the matching release to reproduce a report; branch from current main for new contributions. If my report concerns a different version, identify that release first and compare it with this release. Work on iPhone, iPad and the Chrome extension is paused while the Mac experience is refined. First help me install the Mac app and try a real workflow. Do not treat the website or a successful build as native-app usability testing. Ask me to carry out any Mac interaction you cannot verify.\n\n`;
  const observation = report ? `Here is my observation from using ${report.app.name}:\n\n${report.body}\n` : `Ask what felt awkward or surprising in my trial. If I have no observation yet, help me choose a small unassigned good first issue in the Workbench repository.\n\n`;
  return intro + observation + `Search existing issues before creating another. Agree a small scope with me, comment on the issue to coordinate, use a feature branch in Workbench or your fork, reproduce the behavior with synthetic data, and make one focused change. Run the documented checks and report relevant manual results and limits. Open a PR for maintainer review. Do not alter unrelated code, private user data, signing credentials, or repository settings. Do not claim observations or test results you did not verify.\n`;
}
