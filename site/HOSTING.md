# Where the website lives

This document owns the website's host, addresses, publishing and review. [README.md](README.md) is the contributor guide; this is the reasoning and the move to `workbench.mwdm.cloud`.

## The decisions

- **The host stays.** The site keeps the existing Vercel project, `less-go/workbench-mac`.
- **People use the new domain.** `https://workbench.mwdm.cloud` becomes the address people read and share. It is Matt's domain.
- **Installed apps and stores keep the old address.** `https://workbench-mac.vercel.app` serves the same deployment under a second name, permanently. The update feed, the privacy policy and every link compiled into a shipped build stay on it.
- **Contributors change the site through pull requests.** The Site check and review gate every change; merging publishes once Vercel is connected to GitHub.
- **One decision is open: Vercel Hobby or Pro.** It decides whether contributors get preview links. See [Hobby or Pro](#hobby-or-pro).

## Why Vercel, and why it stays

No decision record existed when this was written, so this reconstructs the reasons from what the configuration relies on.

- **Response headers.** `vercel.json` sends a strict Content Security Policy (`connect-src 'none'`, `form-action 'none'`, `frame-ancestors 'none'`) and a Permissions-Policy denying camera, microphone and location. The feedback page renders what people type and builds GitHub issue links, so those headers do real work. GitHub Pages cannot send response headers, and `frame-ancestors` cannot be set from a `<meta>` tag.
- **The update feed has its own headers.** Sparkle feeds are served as `application/xml` with a five-minute cache, so a corrected feed reaches installed apps within minutes.
- **The build runs the tests first.** The build command is `node --test tests/*.test.mjs && node build.mjs`, so a failing test stops a deploy.
- **Previews.** Once connected to GitHub, each pull request can get its own address.
- **It is portable.** The site is static, dependency-free and built from an explicit allowlist, so it could move hosts. That is also why changing the domain does not require changing the host.

The deciding reason is the installed base. `workbench-mac.vercel.app` is compiled into released Mac, iOS and Chrome builds, is the base of the Sparkle feed and is registered with the Chrome Web Store. Any other host would be a second host to run forever alongside this one, not a replacement for it.

## One deployment, two names

Both names serve the same files from the same deployment. Links people read go to the domain people use; links that machines and stores check stay on the host the release owner controls.

| Link | Where it is set | After the move |
| --- | --- | --- |
| Canonical links, agent brief, handbook pages | `site/origin.mjs` (`SITE_ORIGIN`) | New domain, one-line change at cutover |
| Mac Help → Guide | `Sources/LocalVoice/main.swift:360` | New domain in the next release |
| Phone presenting help | `Sources/StageKit/NativePresentationApps.swift:125,130` | New domain in the next release |
| iOS mobile guide | `Mobile/Workbench/WorkbenchApp.swift:216` | New domain in the next release |
| Chrome homepage and companion links | `BrowserExtension/manifest.json:6`, `popup.html:22`, `privacy.html:13` | New domain in the next extension release |
| Chrome Web Store "Website" field | `BrowserExtension/store/listing.md:21,33` | New domain when the listing is next edited |
| Repository docs | `git grep workbench-mac.vercel.app` | New domain at cutover |
| Sparkle feed (`SUFeedURL`) | `scripts/release/updates.json:4` (`feed_base`) | **Stays** |
| Privacy policy, Chrome Web Store | `BrowserExtension/store/listing.md:25` | **Stays** |
| Privacy policy, iOS app and footer | `Mobile/Workbench/WorkbenchApp.swift:214`, `BrowserExtension/privacy.html:39`, and App Store Connect if entered there | **Stays** |

Why the feed stays: Sparkle checks the feed's and the archive's EdDSA signatures against `SUPublicEDKey` before it extracts anything, so update trust never depended on DNS. What a feed depends on is its name staying alive. `workbench-mac.vercel.app` lives as long as the project does, and the release owner controls both. A registered domain can lapse, and its DNS lives in someone else's account. If `mwdm.cloud` ever lapses or its record changes, only the new address goes dark: updates, the privacy policy and every compiled-in link keep working.

## Never

- **Delete the Vercel project, or remove `workbench-mac.vercel.app` from its Domains.** A deleted project's `vercel.app` name can be claimed by someone else, and every installed copy points there.
- **Use the dashboard's "Redirect to" on `workbench-mac.vercel.app`.** It redirects the whole host, feed and privacy policy included, onto a domain the release owner does not control. Redirects belong in `vercel.json`, where they are reviewed and can exclude the paths below.
- **Set Deployment Protection to All Deployments.** [Standard Protection](https://vercel.com/docs/deployment-protection) protects every deployment except production domains, which keeps both names public. All Deployments would put the feed and privacy policy behind a Vercel login.
- **Proxy the Cloudflare record (orange cloud).** Vercel [does not support a reverse proxy in front of it](https://vercel.com/kb/guide/cloudflare-with-vercel), and certificate issuance fails behind one. The record must be DNS only.
- **Change `DURABLE_ORIGIN` or `feed_base`.** `site/tests/origin.test.mjs` fails if you try, and explains why.
- **Edit a signed feed by hand.** `scripts/release` writes `site/updates/` after reading back the public asset.

The **Durable host keeps its promises** job in `.github/workflows/site.yml` checks daily that the privacy policy and every signed feed answer directly on the durable host. It notices a broken promise before people stop receiving updates.

## Hobby or Pro

This is the one decision the release owner has to make, because it changes what contributors can do.

- **Hobby.** [Git deployments are blocked when the commit author is not the owner of the Hobby team](https://vercel.com/docs/deployments/troubleshoot-project-collaboration). Matt's pushes would produce blocked deployments rather than previews, and a merge publishes only if the release owner made the merge commit. The same check applies to CLI deploys from CI, so do not route around it by rewriting commit authors: that sidesteps the plan's terms and breaks when Vercel tightens the check.
- **Pro.** [$20 a month includes one deploying seat; each further Member seat is $20 a month](https://vercel.com/docs/plans/pro-plan). Viewer seats are free and can comment on previews, but cannot deploy. Adding Matt as a Member, about $40 a month for both, gives him a preview on every push.

Everything else in this document works the same on either plan.

Choose Pro if contributors will change the site regularly, because a preview link is what makes their review take a minute. Stay on Hobby if changes will be occasional: contributors attach screenshots, and the release owner merges, which publishes.

## How a change gets reviewed

- **The Site check** runs the tests and the build on every pull request, on Linux, in seconds. It needs no Mac and no Vercel account.
- **The preview** is the review. On Pro it appears on the pull request; on Hobby the author attaches screenshots at desktop and phone width.
- **`.github/CODEOWNERS`** requests the other maintainer for any website change, and the release owner for the paths listed in the README.

Two repository settings make this binding. They live outside the repository, so the release owner applies them under **Settings → Branches → main**:

1. Add **Site** to the required status checks, next to **Build and test**.
2. Turn on **Require review from Code Owners**. Pull requests that touch an owned path then need an owner's approval.

Administrators are not bound by these rules here, so the release owner can still merge the feed and download record that `scripts/release` stages.

## Moving to workbench.mwdm.cloud

Each step has one owner and a check. On 24 September 2026, `workbench.mwdm.cloud` did not resolve, `mwdm.cloud` used Cloudflare nameservers and had no CAA records, and the durable host served Preview 4 from a deployment older than `main`.

0. **Anyone: merge this change.** Visitors see nothing new: canonical links name the current address. **Check:** the Site check passes.
1. **Release owner: choose Hobby or Pro.** On Pro, invite Matt as a Member.
2. **Release owner: connect GitHub.** Vercel → `workbench-mac` → Settings → Git: connect `EthDawg/workbench`, Root Directory `site`, production branch `main`. The first deploy publishes `main`, whose release record is Preview 4, the same download people get today. **Check:** build `main` locally, then `node site/scripts/verify-host.mjs` reports every file as built. Before this step it reports `release.mjs` and `updates/` missing, because the last CLI deploy predates them.
3. **Release owner: add the domain.** Vercel → Domains → add `workbench.mwdm.cloud`, assigned to Production. Leave `workbench-mac.vercel.app` exactly as it is. Send Matt the record Vercel shows, exactly as shown.
4. **Matt: add one DNS record.** Cloudflare → `mwdm.cloud` → DNS → add a **CNAME** named `workbench` with the target Vercel showed, **Proxy status: DNS only**, TTL Auto. Add the TXT record too, if Vercel asked for one. If CAA records are ever added to `mwdm.cloud`, include `letsencrypt.org`.
5. **Release owner: confirm both names serve one deployment.** Wait for Vercel to show Valid Configuration and a certificate. **Check:** `node site/scripts/verify-host.mjs https://workbench.mwdm.cloud --same-as https://workbench-mac.vercel.app` reports every file identical on both names.
6. **Anyone, release owner approves: switch the canonical address.** One line in `site/origin.mjs`: `SITE_ORIGIN = 'https://workbench.mwdm.cloud'`, plus the repository docs from `git grep`. Merging publishes. **Check:** the step 5 command again, now reporting the new canonical address on both names.
7. **Next releases: move the people-facing links** in the table to the new domain. Leave every link marked **Stays**.
8. **Optional, after a few stable weeks: redirect pages, never promises.** If one address in the browser bar matters more than keeping the durable host independent of `mwdm.cloud`, add this to `vercel.json` in a reviewed pull request:

   ```json
   "redirects": [{
     "source": "/:path((?!updates/|privacy\\.html).*)",
     "has": [{ "type": "host", "value": "workbench-mac.vercel.app" }],
     "destination": "https://workbench.mwdm.cloud/:path",
     "permanent": true
   }]
   ```

   **Check:** `node site/scripts/verify-host.mjs --promises` still passes. It fails if the feed or the privacy policy is redirected.

**Rollback.** No step touches the durable host, so every step can be undone without anything installed noticing: remove the domain in Vercel, revert `SITE_ORIGIN`, delete the redirect, and Matt deletes the CNAME.

**Ownership.** Matt keeps `mwdm.cloud` on auto-renew. The release owner keeps the Vercel project, the signing key and the durable host.
