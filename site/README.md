# Workbench distribution website

Public site: https://workbench-mac.vercel.app

A small static website with one job: help someone who has never heard of Workbench understand it and download it. Every page shares one design (`site.css`, `site.mjs`) and one menu bar and footer (`partials/`), which `build.mjs` stamps into each page.

- `/` (`index.html`, `home.css`, `home.mjs`, `home-boot.js`): what it is, who it is for, that it is free, and how to get it. The hero is a Mac desktop whose menu bar is the site navigation; `home.mjs` plays Say it, Snap it, Mark it and Show it as a pure function of time, with a finished still frame when motion is reduced. It never names other apps.
- `/guide/`: a short welcome, closer to an unboxing than a manual. Three setup steps, where things live, and a line or two per tool. It deliberately avoids shortcut lists and button-by-button steps, which go stale and which people customise; the app itself teaches the details. Old anchors (`#servicenow-pack`, `#presenting`, `#phone-share`, `#scenes`, `#persona`, `#mac-only`) still resolve.
- `/privacy.html`: five promises up front, then every audited data, permission and storage fact, with the fine print in collapsed sections.
- `/contribute/`: feedback report, coding-agent handoff and source links, for people who already like the app (`app.mjs`, `report.mjs`).
- `/packs/`: opens a shared team pack in the app (`packs/open.mjs`).
- `/handbook/`: the contributor reference generated from `handbook/contract.json`, linked from Contribute. It keeps its own body styles in light mode.

The earlier feature essays (`/scenes/`, `/scenes/ambient/`, `/personas/`, `/phone-presenting/`, `/handoff/`, `/mobile/`) are retired. `vercel.json` redirects each to its Guide section, so links from installed apps and docs still land. Their history and evidence remain in git and `docs/`.

Headline and handwriting fonts (Bricolage Grotesque and Caveat, SIL Open Font License, files and licences in `assets/fonts/`) are self-hosted because the Content Security Policy allows no font host. Hero persona, backdrops and portraits are resized copies of the app's bundled resources in `assets/home/`. GitHub Releases own binaries and issues own feedback. No backend, analytics or stored feedback.

## Local development

Requires Node.js 22+ for checks/build and Python 3 for the local web server. No dependency installation is needed.

```sh
cd site
node --test tests/*.test.mjs
node build.mjs
python3 -m http.server 4173 --directory public --bind 127.0.0.1
```

Open http://127.0.0.1:4173. Check every page at desktop and phone width in light and dark, the hero loop and its reduced-motion still frame, the retired-page redirects, and on `/contribute/` report validation, per-area issue routing and copy actions. For the handbook, check lifecycle events, expanded capability records and the matching JSON and agent brief. Use synthetic feedback and do not submit QA issues to GitHub. Edit source files, then rebuild; do not edit `public/` output.

## Publish

Keep design studies, development history and QA detail in the repository, not on the public pages. GitHub issues remain the only work queue.

The custom domain `workbench.mwdm.cloud` and any domain migration are deferred. The existing `https://workbench-mac.vercel.app` site on `less-go/workbench-mac` remains the canonical website and signed-update-feed host until a separate hosting decision. No domain, DNS or redirect migration is part of the current Mac release work.

Vercel project: `less-go/workbench-mac`, framework Other. Direct CLI deployment uploads `site/` as the project root. When connecting GitHub later, set Root Directory to `site`. `vercel.json` defines the build and static output. Direct CLI deployment is the current publication path; automatic GitHub deployment needs a GitHub Login Connection in the Vercel account before this repository can be linked. Once connected, use `main` for production and PRs for previews. Do not expose a preview to the general audience in place of the production alias. The existing Vercel workspace is `less-go`; its member list was checked and contained only the maintainer as owner.

Publish reviewed source with `bash scripts/deploy-site.sh` from a clean checkout. It pins `less-go/workbench-mac` by its organisation and project IDs, so an unlinked checkout or worktree cannot create a new Vercel project, and it never runs `vercel link`, which would download `site/.env.local`. A bare `vercel deploy` from a checkout without `site/.vercel` silently creates a new project instead of updating this one. Do not upload `.env` files.

The build publishes only an explicit allowlist. Binaries remain on GitHub. `scripts/release/publish_update.py` verifies the released package and public download before staging each edition's signed XML feed and JSON record in `updates/`. Those records own the download, version, release notes, checksum and feedback source links. Do not edit versions in HTML or `report.mjs`, synthesize a release record, or edit signed XML.

`production.json` selects **Workbench** as the public product as soon as it exists. The build validates its edition, version, immutable archive URL, source, checksum and exact signed-feed digest; an invalid or incomplete production record stops the build. Preview retains its own record and feed for contributors. Before the first production release, an ordinary build truthfully retains the existing Preview download.

For production promotion, run `node --test tests/*.test.mjs` and `node build.mjs --require-production` from `site/`. The explicit gate refuses a Preview fallback. Commit the verified `production.json` and `production.xml` together, deploy that commit to the existing production site, then check the public ZIP digest, `/updates/production.xml`, download link and feedback source version agree. The generated browser `release.mjs` and HTML use the same selected record; no browser fetch or separate version edit is needed. Keep the published ZIP immutable and never use a moving latest-download URL for a checksum or trial.

Feedback remains in page memory until the user copies it or explicitly opens GitHub. Generated report content is rendered with `textContent`, not HTML. Editing a field invalidates an earlier preview. A long issue URL falls back to copy/paste. Clipboard-denied environments get a selectable fallback. No actual issue is submitted by the website.
