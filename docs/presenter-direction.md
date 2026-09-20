# Presenter direction: return to the right place

The selected increment is **Switch to**: save a named demo tab in its Chrome profile, then return to it from the browser or Workbench’s native picker. “Manager” should bring forward the prepared Manager tab while the presenter moves between browser, slides, a native app and a mirrored phone. Workbench activates the destination; it does not certify the signed-in account or control the phone.

This extends Saved resources. It does not introduce a second library, a presales platform, or a new app lifecycle. The current branch implements the browser adapter and native picker. Public Preview 3 predates them; build, installed acceptance, review and publication are separate states.

## Decision and research

Reviewed 15 September 2026 against the unified `EthDawg/workbench` main, its complete source inventory, product/implementation/mobile contracts, current issues and recent PRs. Voice owns speech; StageKit already owns annotations, persona artwork, scenes and presentation controls. Saved resources owns named links and stable UUIDs. Mobile preparation remains native and separate. Multi-overlay, ambient-motion and phone-route contributions keep their own owners. The 15 September installed Chrome candidate integrates the existing Preview stack through `6d64f16` so those features are preserved.

Frequency/pain, improvement over today and live-demo reliability carry the most weight. Workbench fit, simplicity and reusable identity are next; new platform complexity is a cost. These are qualitative judgments informed by the described 2–5 personas across 2–6 profiles, not measured adoption scores.

| Rank | Opportunity | Assessment |
| --- | --- | --- |
| 1 | Named destination → exact Chrome profile/tab, invoked from anywhere | Frequent evidenced interruption; large reduction in window hunting; reuses library and keyboard; deterministic browser adapter gives Workbench an advantage. Moderate platform cost. Selected. |
| 2 | Private contextual notes / persistent HUD | Useful context reuse, but cross-app capture exclusion cannot be promised. Keep the current switcher transient and labels suitable for sharing. Deferred. |
| 3 | Distribute the week’s issued demo password through an existing manager | Strong weekly pain and reusable destination mapping; requires a supported manager and explicit account-item mapping. Separate from navigating a tab. Deferred. |
| 4 | URL-bound visual comparison overlay | Established, focused pattern; weaker evidence of everyday presenter value than navigation. Do not duplicate existing overlay controls now. |
| 5 | DOM snapshots / shareable demo states | Useful follow-up artifact; substantial capture fidelity, sanitisation and maintenance burden. Existing specialised products are a better baseline. |
| 6 | Meeting intelligence / copilot | Potential preparation/follow-up value, but introduces account, audio, privacy and probabilistic dependencies into a deterministic job. No first-step architectural advantage. |

[Raycast Quicklinks](https://manual.raycast.com/quicklinks), [Velja](https://sindresorhus.com/velja) and [Workona](https://workona.com/help/tab-manager/) support the capture/name/reuse pattern. Velja already opens links in profiles; Workbench earns this addition through returning to the exact live tab from an existing presenter shortcut, not by becoming another URL router. We reuse the current tab when valid and leave unrelated windows intact.

[Navattic sandbox](https://docs.navattic.com/demos/sandbox), [Storylane presenter mode](https://docs.storylane.io/sandbox-demo/sandbox-configuration/present-mode) and [Walnut presenter notes](https://help.walnut.io/help/demos/publish/presenter-notes) separate audience content from operator context. Storylane’s second-display/tab-share pattern is useful; it is not universal HUD invisibility. Apple describes `NSWindow.SharingType.none` as legacy; another app owns its capture filter. See [AppKit sharing](https://developer.apple.com/documentation/appkit/nswindow/sharingtype-swift.enum) and [ScreenCaptureKit](https://developer.apple.com/documentation/screencapturekit/capturing-screen-content-in-macos).

[Reprise](https://www.reprise.com/resources/blog/meet-the-reprise-integrated-demo-creation-platform-and-reprise-reveal) and [Supademo](https://docs.supademo.com/create/by-demo-type/guided-html-demos/manual-capture-for-html-recordings) show why captured applications are another maintained representation, not a cheap snapshot. [PerfectPixel’s publisher](https://chromewebstore.google.com/publisher/welldonecode-llc/uaa0f8ac250365ab1da459e897655b1ec) provides a narrower opacity/locking/domain-persistence reference. [Teams presenter view](https://support.microsoft.com/en-us/teams/meetings/share-slides-in-microsoft-teams-meetings-with-powerpoint-live), [Zoom meeting questions](https://support.zoom.com/hc/en/article?id=zm_kb&sysparm_article=KB0057749) and [Vivun insights](https://www.vivun.com/product-insights) concern distribution, meeting context and organisational knowledge; switching must work without those services or an LLM. These are product/architecture references, not hands-on competitor benchmarks.

Native application activation and exact-window selection differ: [NSWorkspace](https://developer.apple.com/documentation/AppKit/NSWorkspace) opens apps, while arbitrary exact-window targeting needs [Accessibility actions](https://developer.apple.com/documentation/applicationservices/1462091-axuielementperformaction) and new failure/permission handling. Chrome’s own [tabs](https://developer.chrome.com/docs/extensions/reference/api/tabs) and [windows](https://developer.chrome.com/docs/extensions/reference/api/windows) APIs provide better evidence for this first target. The user can invoke Switch to while an emulator or mirrored phone is in front; restoring their internal state is separate. [Android snapshots](https://developer.android.com/studio/run/emulator-snapshots) and [iPhone Mirroring](https://support.apple.com/guide/personal-safety/manage-iphone-mirroring-on-your-iphone-or-mac-ips70daa1bcf/1.0/web/1.0) retain their own lifecycle limits.

## Use it

1. In the built Mac app, open **Saved resources → Chrome destinations → Enable Chrome connection**. This registers the bundled host for the current user and selected Workbench edition.
2. Choose **Show Chrome extension**. In each participating Chrome profile, open `chrome://extensions`, enable Developer mode and **Load unpacked** with that folder. Pin Workbench if desired. This local distribution is not a Chrome Web Store release.
3. On a demo tab, open the extension, give that profile a recognisable name and **Connect profile**. Choose **Save or update this tab**, type a label such as Manager, and inspect the address.
4. For a new site, **Allow this site** opens Chrome’s permission prompt. Chrome closes its popup; reopen Workbench to finish **Save destination**. The short-lived draft survives; no save is queued behind a denied prompt. A later save at an already allowed site is direct.
5. From any app, use **Control–Option–G**, or Workbench’s menu **Switch to…**. Type a name, use arrows and Return, or select a row. Escape returns to the previous app. Change/disable the shortcut in the existing Keyboard page.

Both native and browser activation obey the same guard during recording and keyboard practice. Entering Switch to ends active drawing input and exits the board view using the existing StageKit Escape path; drawing history remains owned by StageKit. The extension also lists the same destinations and can switch between profiles. Saved resources can edit labels, remove entries or **Use default browser instead**. Chrome destinations do not contain private notes in the switcher. The feature requests neither Accessibility nor Screen Recording. A shared display can show the picker and its labels.

A changed tenant subdomain is explicit: open the new URL in the intended profile, choose **Update [destination]**, review old/new addresses and grant the new site if needed. The resource ID stays stable. There is no wildcard tenant match or automatic URL rewrite across unrelated accounts. Queries and fragments are removed and previewed; use a stable navigation URL rather than a signed, secret-bearing or query/hash-dependent route.

## State and security boundaries

| State | Owner / behaviour |
| --- | --- |
| Name, navigation URL, stable resource UUID | Existing versioned `demo-library.json`; validated atomic saves, blocked on unreadable/future data or an observed outside edit. One library. |
| Browser target | Optional resource attachment: profile UUID, readable profile label, installation UUID. Local to this Mac/edition. Portable export and import strip it. |
| Extension profile identity | `chrome.storage.local`, independently generated per profile. No Chrome account ID, profile-directory scan or Chrome Sync. |
| Live tab binding | `chrome.storage.session`, checked against the saved URL and current/pending origin. Never portable or treated as stable after browser restart. |
| Permission-step draft | Session storage, current tab/address only, 15-minute validity. No automatic save after permission. |
| Connections, pending actions | Native memory; dropped on Quit/disconnect. Request IDs, duplicate rejection, one activation at a time, eight-second expiry and no automatic activation retries. |
| Credentials, cookies, page/DOM content | Absent. Chrome or an existing password manager owns credentials. No analytics, cloud backend, Workbench account or remote code. |

`PresenterKit` owns the bounded typed protocol; `WorkbenchBrowserHost` only relays Chrome native-messaging frames to the app’s Unix socket. `PresenterModel` uses the existing resource model and dispatches to the paired profile. `PresenterPanelController` is a transient native adapter. The host’s exact extension origin is pinned; the per-user socket directory is 0700 and socket is 0600, with peer-UID checks and an edition lock. This protects against other users, not malicious processes already running as the same user. There is no HTTP listener or AppleScript bridge. See [Chrome native messaging](https://developer.chrome.com/docs/extensions/develop/concepts/native-messaging).

The extension requests `nativeMessaging`, `activeTab`, `storage` and `alarms`, plus optional host access only for explicitly saved sites. No content scripts, cookies, passwords, history, blanket tabs permission or incognito support. Chrome’s host grant covers a scheme/hostname; actual resolution separately checks the exact origin including port. Names and addresses remain local but can still be sensitive: use audience-safe labels and non-secret paths. The 64 KiB protocol and 250-entry ceiling bound the small presenter list; excessive metadata is rejected before a browser save.

The minimum portable primitive is the existing resource UUID and navigation link. Profile/permission/session state is deliberately not added to SceneSyncKit or mobile CloudKit. A future adapter can bind that resource explicitly on another machine; no speculative workspace/account schema is introduced.

## Recovery contract

A valid remembered tab wins even if the presenter has navigated within the same origin. Otherwise exactly one matching saved address can be rebound. Multiple matches ask the user to select the correct tab and update its destination. No match opens the saved address in that same connected profile. Existing unrelated tabs are never navigated or closed. Tab activation and window focus are both checked; this confirms navigation focus, not authentication, page rendering or the current business persona.

Keep Workbench and participating profiles available. A missing/paused native app or extension reports the reconnect steps. Opening a closed tab works while the paired extension remains connected; Workbench does not launch a quit browser or guess a profile directory. Reopen the intended profile and Retry. Native messaging reconnects after worker/app interruption; only connection establishment retries, never an uncertain activation. Old commands expire across sleep. Chrome APIs cannot atomically prevent a user navigation racing a focus operation; a changed final target reports uncertainty rather than readiness.

No automatic screen-sharing detection, private-note overlay, full workspace restoration, generic native-window capture, credential mutation or mobile/emulator control is claimed.

## Weekly password clarification

The provider issues a new weekly password for global demo tenants. The requested operation is distribution across 2–5 usernames in 2–6 Chrome profiles, with occasional tenant-subdomain changes. It is not changing passwords at the provider. The earlier CSV-upload workflow was unreliable.

Chromium restricts `passwordsPrivate` to component extensions; an ordinary extension cannot bulk-edit Chrome’s saved-password store. [Permission source](https://chromium.googlesource.com/chromium/src/+/main/chrome/common/extensions/api/_permission_features.json). Do not write Chrome credential databases or automate internal password pages. A later adapter should update a reviewed set of existing items in an approved manager and verify each receipt without returning secrets. [Bitwarden’s CLI](https://bitwarden.com/help/cli/) is a feasibility reference, not a selected or configured dependency. This iteration stores no username/password mapping and changes no credentials.

## Build and validation

`bash scripts/test.sh` includes protocol, native routing and extension regression checks; Node 20+ is required for the dependency-free extension suite. `bash scripts/build.sh` packages the native host and extension inside the ordinary Mac bundle, and the existing Preview/release tools sign nested executables. No separate browser product or backend build is required. The focused commands are `swift test --disable-sandbox --filter PresenterKitTests`, the built executable’s `--check-presenter`, and `node --test BrowserExtension/tests/*.test.js`.

Native dogfood can use the packaged executable with `--presenter-fixture /tmp/wb-presenter-fixture-NAME`. This opens the actual picker and bridge with a disposable resource store and preference suite. It never constructs AppModel or migrates existing libraries; it registers only Switch to for a real global-key check. Pair only disposable Chrome profiles and local synthetic pages. A custom Chrome user-data directory keeps its native host manifest in `NativeMessagingHosts/`. The fixture flag is developer QA, not part of the normal user flow.

### Acceptance evidence — 15 September 2026

- Full Mac regression runner passed, including the existing 91 StageKit checks / 2,165 assertions. After the final routing and library changes, 8 PresenterKit tests, 27 real native-socket checks, 64 browser tests and 29 Saved resources recall checks passed. Browser tests cover expiry after a simulated clock jump, cancellation, permission refusal, ambiguous matches and false-success prevention.
- Real UI dogfood used macOS 26.5.1, Chrome for Testing 151.0.7922.34, two ordinary disposable Chrome profiles, synthetic local pages and an isolated native resource store. No real demo accounts or credentials were used. Verified native search/Return and accessible row activation, extension cross-profile activation, closed-tab reopening, minimized-window restoration, extension reload, duplicate-tab refusal, permission grant/denial, and explicit tenant-subdomain update preserving the resource UUID.
- Quit the native companion: the extension showed Not connected with Retry. Restarted the app: the same resource IDs and profile bindings returned. Quit Chrome: destinations showed Open profile to connect and explained recovery without launching or guessing a profile. Reopening a paired profile reconnected automatically; commands did not replay.
- The signed package's host and bundled extension were verified against the tested source; its executable passed all 27 native checks. The first proposed shortcut conflicted with Break timer during packaged dogfood, so the final default is Control–Option–G. Its Carbon registration and native key delivery passed. The computer-use tool targets keystrokes at one process; it did not establish physical system-wide key delivery from another app.
- The initial implementation was a signed local candidate. The subsequent installed candidate and store preparation are recorded below; public Preview 3 still predates the browser companion.

Remaining acceptance: physical sleep/wake; a real Zoom/Teams receiver across share start/stop and display changes; physical system-wide shortcut invocation from native apps, mirrored phone and emulator; and the full normal-app interaction with live drawing/board controls. Simulated expiry does not prove physical wake behavior. The picker is intentionally visible to a whole-display share; no private HUD guarantee is made. Existing iOS/CloudKit features were not changed or retested on hardware. Use the signed release workflow with any established cloud provisioning retained before replacing an installed Preview.

### Installed Chrome preview and store preparation — 15 September 2026

- Runtime source: `df2950f9faf9e106236a77fccabe023a3aa01074`, including the existing installed Preview stack through `6d64f16`. PR #39 is stacked on the phone-route branch so its review remains focused.
- Installed Developer ID signed Workbench Preview 2.0.0 build `20260914230155`. Its existing Production CloudKit provisioning, app path, signing team and saved data were retained. The installer saved the previous app as a rollback archive. This new binary is not notarized or publicly downloadable.
- Mac archive SHA-256: `1011d974002df6f3709c2ed3889c5a9a4f9211844fbdb8af9234b03dc9a85d7f`. The installed bundled host and extension matched the source; the installed executable passed all 27 native presenter checks.
- Workbench Preview for Chrome 0.1.0 was installed unpacked and pinned in the maintainer's normal Chrome profile. Pairing showed Connected in Chrome and one connected profile in Workbench. A public Workbench website destination was saved through the optional one-site grant; its draft survived the permission prompt. The same item appeared in the existing Mac Saved resources, and both the native picker and extension returned to its tab. No demo credentials or private websites were used.
- Final combined Mac regressions passed, including 121 StageKit tests / 2,601 assertions. The first run failed because the installed app still held global keys; quitting through its menu and verifying process exit resolved that environment conflict. The successful rerun did not change source or omit the shortcut tests. Browser checks: 64 passed. Store packaging checks: 9 passed. Site checks: 8 passed.
- `scripts/package-chrome.py` creates a root-manifest ZIP containing exactly 12 runtime files. The Chrome ZIP SHA-256 is `6a744938a87c6d80346946138ad44c9e40baa8fd2b07a4f451e63dcdc53c6c40`. Listing copy, permission reasons, privacy text, icons and promotional tile are in `BrowserExtension/store/`. Actual store screenshots and the final store-assigned identity remain submission steps.
- The [Chrome privacy disclosure](https://workbench-mac.vercel.app/privacy.html#chrome) and guide were published to the existing site. Vercel deployment `dpl_FGJg2KNpZg8C4y2iMnhd5bZTTRd6` is READY; five public pages matched the reviewed build byte-for-byte with HTTP 200 and `nosniff`. The public binary link still targets Preview 3.

Chrome Web Store registration, upload, final identity/key alignment, review submission and approval are not complete. Before submitting, provide a publicly downloadable matching native companion and replace these pending claims only with authoritative release evidence. Physical hotkey delivery, sleep/wake and meeting-receiver limitations above remain unchanged.

The only deferred opportunities created from this work are [weekly password distribution through an existing manager #37](https://github.com/EthDawg/workbench/issues/37) and [contextual notes on an explicitly unshared surface #38](https://github.com/EthDawg/workbench/issues/38). They are not implemented capabilities.
