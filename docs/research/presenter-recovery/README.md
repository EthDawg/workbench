# Recover the unfinished presenter experiment

**Decision, 21 September 2026:** retain the source and reuse it selectively. Start with opening an existing Chrome bookmark in its selected profile. Validate profile cues next; keep private notes under [issue #38](https://github.com/EthDawg/workbench/issues/38). Do not reintroduce a broad launcher or merge the old experiment wholesale.

The job is concrete: during a prepared demo, reach the right screen and keep track of which role is being demonstrated without rebuilding the preparation in another library. The current Switch to implementation already handles named destinations. [PR #55](https://github.com/EthDawg/workbench/pull/55) owns setup packs, launch sets and default tabs. This recovery concerns different, unfinished work.

## What was recovered

[presenter-experiment.patch](presenter-experiment.patch) preserves 33 source/test files from the uncommitted `feature/presenter-destinations` experiment on base `887a6e067a9f45e2e91054eb6bc2f110c77117b7`. [Provenance](provenance.json) gives each resulting file's hash. The original worktree was left intact. Store materials, signing files, personal records and historical publication claims are excluded.

| Capability | Recovered source | Useful outcome / limit |
| --- | --- | --- |
| Optional bookmark search/open | `BrowserExtension/bookmarks.js`, its tests, native protocol/bridge/picker changes | Find an existing bookmarked demo route in the intended profile, preserving its query/fragment inside Chrome. Chrome remains the bookmark owner. |
| Profile activity | `BrowserExtension/profile-focus.js`, tests, `PresenterBridge.swift` | Observe a paired profile's focus without sending its tab content or URL. This does not establish the signed-in account. |
| Profile artwork | `PresenterProfileCoordinator.swift`, `StageKit/ProfilePersonaOverlay.swift`, tests | Show a chosen identity cue; hide it for other foreground apps, unknown profiles and disconnections. Manual overlay sessions stay separate. |
| Local notes | `PresenterPreferences.swift`, checks, `PresenterPanel.swift` | Explicitly reveal brief preparation notes. A whole-display share can expose them. |
| Chosen app shortcuts / persistent picker | Same preferences and picker | Older optional experiments. General launchers already cover much of this job; the current toolbar work in [PR #69](https://github.com/EthDawg/workbench/pull/69) owns compact persistent controls. |

Source at `main c692a4b` and PR #55's `a2f30c3` contains none of the new bookmark controller, profile-focus reporter, presenter preferences or profile-artwork coordinator. This is a source gap, not merely an unmerged branch name. Conversely, the base destinations feature from [PR #39](https://github.com/EthDawg/workbench/pull/39) was integrated and must not be rebuilt.

The earlier task ended with publication work incomplete. That history is not evidence that these additions were rejected, nor that they were accepted for release. The exact reason these particular uncommitted additions were left out is unknown. Historical local dogfooding is useful context, not verification on today's combined app. Manifest version `0.2.0` in the reference patch is historical and must not replace the current adapter/store identity.

## First increment: open a bookmark in the right profile

Use **Switch to → Bookmarks**, with an explicit connected-profile selector and **Allow bookmarks** only when first requested. Search locally; show a bounded list of titles and hosts; open the selected bookmark ID through that profile's adapter. Report a disconnected profile or revoked permission without guessing a replacement.

This earns a trial because the current saved-destination contract strips queries and fragments. Some existing demo bookmarks rely on them. The recovered controller resolves the original URL inside Chrome and opens it there; it does not need a second synchronized bookmark library. A complete URL can still contain confidential or expiring material, so do not copy it into logs, native summaries, shared setup packs or handoff exports. Titles and hosts may also be sensitive; disclose what the user is choosing to display.

Chrome's [bookmark API](https://developer.chrome.com/docs/extensions/reference/api/bookmarks) requires bookmark permission and provides IDs scoped to a profile. [Optional permissions](https://developer.chrome.com/docs/extensions/develop/concepts/declare-permissions) support a deliberate runtime grant. These are platform capabilities, not proof that the recovered adapter works in real Chrome. Sources checked 21 September 2026.

Implementation order:

1. Rebase the controller and its tests onto the current extension, coordinating with PR #55's bookmark permission and package allowlist. Keep one permission path and one adapter version. Do not copy the old manifest or packager over newer work.
2. Extend the existing typed native protocol with capability negotiation. An older adapter must keep destinations working while bookmark actions clearly remain unavailable. Bind request and response to the selected profile/connection; keep cancellation and expiry.
3. Add the smallest native result surface. Reuse current Switch to focus/keyboard/busy-state behavior. Do not carry over every old preferences panel.
4. Run a synthetic two-profile trial: same bookmark title in both profiles, distinct local URLs, query/fragment preserved, deletion, denied/revoked permission, disconnect/reload, wrong-profile response, expiry, repeated click and minimized-window restoration. Observe the actual final tab and window, not just an acknowledgement.
5. Compare that trial with Chrome's bookmark UI plus existing destinations. Advance only if it removes repeated profile/route hunting without making setup harder. Otherwise retain the reference and stop the feature.

The first increment adds no LLM call, browser DOM access, password integration, cloud synchronization or background library sweep.

## Next: a truthful profile cue

The profile-artwork experiment can remove a repeated manual persona switch, but **Chrome profile identity is not authenticated application identity**. First show the paired profile label as an explicit, opt-in cue. Add existing persona artwork only when a real multi-role walkthrough shows that it helps the presenter or audience. Preserve manual persona groups and one state owner; do not infer tenant, account or role from a page.

Before advancing, verify blur, another app foregrounded, profile/extension disconnect, stale events, reconnect, two profiles with identical labels, sleep/wake, and turning following off. The cue should disappear when its evidence is uncertain. Confirm where the audience actually sees it: a native overlay outside a selected browser window may be absent from that share. The source's tests are reusable but do not establish receiver behavior.

## Notes and alternatives that remain deferred

For notes, [#38](https://github.com/EthDawg/workbench/issues/38) remains the single work item. It currently proposes destination-owned notes and manual selection. The experiment instead stores profile-local notes. Settle that difference explicitly: use existing resource notes by default; add profile-local notes only for genuinely shared role preparation. Do not ship two overlapping editors or silently export local notes.

Start with an explicitly unshared window/display, notes hidden until requested, and synthetic receiver checks. Apple's [`NSWindow.SharingType.none`](https://developer.apple.com/documentation/appkit/nswindow/sharingtype-swift.enum/none) is a legacy constant, not a universal privacy guarantee. The separately recovered [Audience experiment, PR #72](https://github.com/EthDawg/workbench/pull/72), explores a controlled output, but is not a prerequisite for bookmarks or a promise of private notes.

Keep general app shortcuts deferred until a real demo requires a stable named native-app destination that existing launchers cannot handle. Avoid arbitrary window targeting, command execution and another permission/setup surface. Keep persistent smart-menu styling with PR #69 rather than importing a competing toolbar. Weekly credential distribution stays under [#37](https://github.com/EthDawg/workbench/issues/37) and an existing manager.

## How an implementing agent should use the source

Treat the patch as a historical reference. Its old base is deliberate; it preserves the attempted behavior and tests without changing shipped targets. In a disposable checkout at the exact base, `git apply --check` and then `git apply` reconstruct the experiment. Do not apply it to an active owner checkout or current main. The recovery audit records the checks rerun on this reconstruction.

Read the current [presenter contract](../../presenter-direction.md), PR #55 and the chosen issue first. Port one capability, keep current package/store identity and privacy copy, update the owning contract, and record exact runtime evidence. A successful patch reconstruction is not compatibility, installation or release acceptance.
