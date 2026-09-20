# Workbench distribution website

Public site: https://workbench-mac.vercel.app

A small static website for downloading Workbench, learning its jobs and controls, trying a real workflow, and preparing a user-experience report or coding-agent handoff. Voice and StageMark are modules in one native app. GitHub Releases own binaries and issues own feedback. No browser reimplementation, backend, analytics, or stored feedback.

The working guide is `guide/index.html`. The product handbook is `handbook/index.html`: two independent visual journeys, lifecycle exploration, native boundaries and contributor entry points. `handbook/contract.json` is the single structured source for its capability records, lifecycle rules, acceptance scenarios and generated agent brief. Edit that source rather than separately updating human and agent copies. The repository-wide product contract remains `../docs/workbench.md`.

`assets/guide/` contains explicitly labelled generated studies and separate actual native screenshots. Generation prompts and critique live in `../docs/design-images.md`. The build uses an explicit file allowlist; it publishes no source tests, rendering helper, environment files or local deployment state. No backend, agent endpoint or wallpaper automation is added by the handbook.

For new collateral, start with the [asset reuse guide and waveform example](../docs/design-images.md#reuse-the-work-before-generating-again). Keep a concept label visible where an illustration appears; use a capture of the relevant implemented state for current UI instructions. A native panel preview or Simulator capture retains its original evidence limits when reused.

## Local development

Requires Node.js 22+ for checks/build and Python 3 for the local web server. No dependency installation is needed.

```sh
cd site
node --test tests/*.test.mjs
node build.mjs
python3 -m http.server 4173 --directory public --bind 127.0.0.1
```

Open http://127.0.0.1:4173. Check desktop/mobile layout, keyboard tab switching, trial checkboxes, report validation, per-app issue routing, and copy actions. For the handbook, check every lifecycle event, keyboard activation, expanded capability records and the matching JSON/agent brief. Read the fallback lifecycle table with JavaScript unavailable. Use synthetic feedback and do not submit QA issues to GitHub. Edit source files, then rebuild; do not edit `public/` output.

## Publish

Vercel project: `less-go/workbench-mac`, framework Other. Direct CLI deployment uploads `site/` as the project root. When connecting GitHub later, set Root Directory to `site`. `vercel.json` defines the build and static output. Direct CLI deployment is the current publication path; automatic GitHub deployment needs a GitHub Login Connection in the Vercel account before this repository can be linked. Once connected, use `main` for production and PRs for previews. Do not expose a preview to the general audience in place of the production alias. The existing Vercel workspace is `less-go`; its member list was checked and contained only the maintainer as owner.

Publish reviewed source with `vercel deploy --prod --yes --scope less-go --cwd site` from the repository root. Do not upload `.env` files.

The build publishes only an explicit allowlist. Binaries remain on GitHub. Update the versioned download links, checksum links, and `apps` versions in `report.mjs` together, after verifying the release assets. Do not use a moving latest-download URL for a checksum or version-specific trial.

Feedback remains in page memory until the user copies it or explicitly opens GitHub. Generated report content is rendered with `textContent`, not HTML. Editing a field invalidates an earlier preview. A long issue URL falls back to copy/paste. Clipboard-denied environments get a selectable fallback. No actual issue is submitted by the website.
