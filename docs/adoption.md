# Adoption evidence

Workbench sends nothing home and the website keeps its promise of no analytics, so the adoption evidence is whatever is already public. This page says what can be counted, what each count means, and where things stood when counting started.

## What can be counted

| Evidence | Where | What it means |
| --- | --- | --- |
| Downloads of each release ZIP | `python3 scripts/release/adoption.py`, from GitHub's public release counts | Archive downloads, including updates, repeat downloads and automated checks. They do not establish unique Macs, installed copies or active people. |
| Repository views and unique visitors | GitHub Insights → Traffic, maintainers only, last 14 days | People who looked at the source. Referrers show where they came from. |
| Repository clones | Same page | Mostly CI and agent worktrees. Clone spikes land on build days, not on launches. Ignore them for adoption. |
| Team pack access | Collaborators and pending invitations on the pack repository | People who can open a team pack. An accepted invitation is the only sign that a colleague got as far as the pack. |

The ZIP counts include the maintainers' own installs, the shared Preview and the link checks agents run after each publication. Their share of the total cannot be inferred from this count. Watch the trend across releases rather than the digits. `--snapshot` keeps a dated CSV when a decision needs the curve; keep that file outside the repository unless the decision itself goes on record.

Nothing here identifies a person, and nothing is collected that GitHub does not already publish. Adding any other measurement, including privacy-preserving web analytics, changes the [privacy page](../site/privacy.html) and needs its own decision.

## Baseline, 5 October 2026

Counting started with Workbench 2.4.0, four days after its release.

| Signal | Value |
| --- | --- |
| Workbench 2.4.0 ZIP downloads | 8 in 4.3 days |
| 2.3.1, 2.3.0, 2.2.0 ZIP downloads | 5, 4, 3 |
| Unique repository visitors, 21 September to 4 October | 6, no referring sites |
| Stars, watchers, forks | 0, 0, 1 |
| People with access to the ServiceNow team pack | 2 maintainers, no pending invitations |
| Website | No custom domain, no share image on any page, no robots or sitemap |

These recorded counts do not establish whether anyone outside the maintainers installed Workbench. Repository traffic does not measure website traffic. With no website analytics, arrivals at the website are unknown.

## What would change the picture

The first cohort is colleagues who present on screen and have a team pack waiting for them. For a month after the first ten invitations, the numbers to watch are the newest release's ZIP downloads, pack invitations accepted, and what those people say. Download growth is a distribution signal. Evidence of adoption needs direct user feedback or another explicitly approved measurement; these counts cannot identify returning users.
