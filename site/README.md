# Workbench website

Public site: https://workbench-mac.vercel.app, moving to https://workbench.mwdm.cloud. [HOSTING.md](HOSTING.md) owns where it lives, why, and the move.

A small static website for downloading Workbench, learning its jobs and controls, trying a real workflow, and preparing a user-experience report or coding-agent handoff. Voice and StageMark are modules in one native app. GitHub Releases own binaries and issues own feedback. No browser reimplementation, backend, analytics, or stored feedback.

The working guide is `guide/index.html`. The product handbook is `handbook/index.html`: two independent visual journeys, lifecycle exploration, native boundaries and contributor entry points. `handbook/contract.json` is the single structured source for its capability records, lifecycle rules, acceptance scenarios and generated agent brief. Edit that source rather than separately updating human and agent copies. The repository-wide product contract remains `../docs/workbench.md`.

`assets/guide/` contains explicitly labelled generated studies and separate actual native screenshots. Generation prompts and critique live in `../docs/design-images.md`. The build uses an explicit file allowlist; it publishes no source tests, rendering helper, environment files or local deployment state.

## Change the website

1. Branch from `main` and edit source files here. Never edit `public/`; the build replaces it.
2. Run the checks and look at the result locally (below).
3. Open a pull request. The **Site** check runs the tests and build on every pull request in seconds, without a Mac.
4. `.github/CODEOWNERS` asks the other maintainer to review. Changes to what the site promises go to the release owner (next section).
5. Show what changed: the preview link on the pull request, or screenshots at desktop and phone width while previews are unavailable. Use synthetic content.

Merging to `main` publishes the site once the Vercel project is connected to GitHub. Until then the release owner publishes with the CLI (see Publish).

## What needs the release owner

Most of the site is words, layout and images, and any maintainer can review those. These paths decide what people download, what the site promises and what agents are told, so `.github/CODEOWNERS` routes them to the release owner:

- `updates/`: signed Sparkle feeds and the download record. `scripts/release` writes them after reading back the public asset. Never edit a signed XML file by hand.
- `vercel.json`: security headers, the feed's content type and cache, and the build command.
- `build.mjs`: the allowlist of files that ship. A new page is added here.
- `origin.mjs`: the site's two addresses. Nothing else names them; a test enforces it.
- `handbook/contract.json`: capability status, which the agent brief repeats as fact.

## Local development

Requires Node.js 22+ for checks/build and Python 3 for the local web server. No dependency installation is needed.

```sh
cd site
node --test tests/*.test.mjs
node build.mjs
python3 -m http.server 4173 --directory public --bind 127.0.0.1
```

Open http://127.0.0.1:4173. Check desktop/mobile layout, keyboard tab switching, trial checkboxes, report validation, per-app issue routing, and copy actions. For the handbook, check every lifecycle event, keyboard activation, expanded capability records and the matching JSON/agent brief. Read the fallback lifecycle table with JavaScript unavailable. Use synthetic feedback and do not submit QA issues to GitHub.

## Publish

The app page is `/`, everyday instructions are `/guide/`, and `/handbook/` is the deeper capability/lifecycle reference. Keep design studies, development history and QA detail in the repository or reference pages, not in the getting-started flow. GitHub issues remain the only work queue.

Download links, checksum links and app versions all derive from the release record in `updates/`, which only the release tooling writes. Never point a checksum or a version-specific trial at a moving latest-download URL.

Until Vercel is connected to GitHub, the release owner publishes reviewed `main` with `vercel deploy --prod --yes --scope less-go --cwd site` from the repository root. Do not upload `.env` files. After connecting, merging to `main` publishes and pull requests get previews; [HOSTING.md](HOSTING.md) has the steps.

To check a live host against this checkout, build first and then run `node scripts/verify-host.mjs`. It confirms every built file answers directly with the headers in `vercel.json` and one agreed canonical address.

Feedback remains in page memory until the user copies it or explicitly opens GitHub. Generated report content is rendered with `textContent`, not HTML. Editing a field invalidates an earlier preview. A long issue URL falls back to copy/paste. Clipboard-denied environments get a selectable fallback. No actual issue is submitted by the website.
