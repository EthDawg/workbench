# Workbench Preview Chrome adapter

An unpacked Manifest V3 adapter for the Workbench Mac app. Saved resources in Workbench owns the destinations; each Chrome profile explicitly pairs under a name you choose. This adapter stores no passwords and does not sign in, change credentials, read page content, or establish that a persona is authenticated.

## Try the development build

1. Install the matching Workbench development app and enable **Chrome connection** in **Saved resources**.
2. In the intended Chrome profile, open `chrome://extensions`, enable **Developer mode**, choose **Load unpacked**, and select this `BrowserExtension` folder. Repeat for each profile you want to pair.
3. Pin Workbench, open its popup, type a profile name such as **Manager profile**, and select **Connect profile**.
4. Open the intended demo tab. In Workbench’s popup, expand **Save or update this tab**, type an audience-safe label such as **Manager**, and review the exact address. For a new site, choose **Allow this site**; Chrome closes the popup for its permission prompt. Reopen Workbench and finish **Save destination**. Your temporary draft survives, and no save runs after a denied prompt. Already-allowed sites save directly.
5. Choose a destination from any connected profile or Workbench’s Saved resources. Workbench routes it to its paired profile. Keep that profile open and connected.

When a tenant’s subdomain changes, open its new tab in the intended profile, select its existing destination under **Save or update this tab**, review the old and new addresses, and select **Update to this tab**. The existing destination ID is retained. Another profile cannot update it.

The stable unpacked ID is `ajafaiojgpdgmeblldllnhhfnafiiieo`. The existing Chrome Web Store draft has the separate assigned ID `alckfplchkdcjdlhlnhanonkelljnioj`. Native host `com.ethdawg.workbench.browser` allows exactly those two extension origins, both in its registration and when accepting a connection. The manifest's public key preserves the unpacked identity; it is not a signing secret or evidence of a published Web Store package. Updating the companion does not migrate extension storage or remove existing unpacked connections.

After installing a companion with support for both identities, existing users should choose **Saved resources → Chrome destinations → Repair Chrome connection** to refresh the native host registration before connecting a store-installed extension. This preserves saved destinations and profile bindings. Each extension installation owns its own pairing and storage; the store build does not automatically inherit the unpacked installation's profile identity.

## What activation means

The adapter remembers a destination’s tab only for the current browser session. It accepts that tab while it remains in the exact saved origin, including scheme and port. After a restart or stale binding it considers only tabs matching the saved address, ignoring query parameters and fragments. One match is focused; no match opens the saved address; multiple matches ask you to update from the right tab. It never navigates or closes an unrelated tab. An existing tab may have navigated within its tenant after being saved.

Chrome optional host grants are scheme-and-hostname patterns. The adapter enforces the narrower exact origin during every tab decision. A new subdomain requires a new explicit grant when saving or updating. Incognito is excluded. Names and addresses are rendered as text. Page titles are never copied into destination names. Native errors use a fixed message allowlist.

Success verifies Chrome’s tab-active and window-focused flags. It does not verify page rendering, authentication, or meeting capture. A timeout can be uncertain: check Chrome before activating again. Chrome does not offer an atomic read-and-focus operation, so a concurrent user navigation can lead to a failed final verification after a focus request has already occurred.

## State and connection

- `chrome.storage.local`: `profileID`, `profileName`, `paired` only. Never `storage.sync`.
- `chrome.storage.session`: `destinationTabs`, mapping destination UUID to current session tab ID and saved URL. Runtime IDs never enter durable storage.
- `chrome.storage.session`: a permission-step `saveDraft`, checked against its tab/address and a 15-minute expiry when reopening. It is an editable draft, not queued work.
- Native connection: one `connectNative` port per paired profile; version 1 UUID messages, 64 KiB packet ceiling, accepted hello before commands, at most 20 pending requests, 15-second request deadline. Focus has an 8-second deadline and accepts an optional native `expiresAt` timestamp no more than 10 seconds ahead.
- Disconnect: fail pending requests, abort in-flight focus, and schedule one reconnect alarm after 30 seconds. A paired profile reconnects on startup or worker restart. Activation is never automatically retried.

## Verification

Run `node --test BrowserExtension/tests/*.test.js` from the repository root. No npm install or runtime dependencies are needed. Tests use deterministic Chrome API fakes for URL handling, tab selection, permissions, duplicate tabs, focus verification, navigation and cancellation races, wire correlation, disconnects, timeouts, size limits and manifest/popup boundaries.

These tests do not establish live Chrome/native integration. Dogfood the matching native host with synthetic profiles and pages before distribution, including two profiles, browser restart, closed tabs, duplicate URLs, minimized windows, permission refusal and a tenant subdomain update.

## Prepare the Chrome Web Store package

Run `python3 scripts/package-chrome.py` from the repository root. The reproducible archive is `dist/WorkbenchPreview-Chrome-0.2.1.zip`; the manifest sits at ZIP root. The ZIP omits the development-only `key` so an upload to the existing store item uses that item’s signing identity. The source manifest retains its key and stable unpacked ID. The script validates manifest capabilities, local asset references, exact icon dimensions and ZIP readback. Its fixed runtime allowlist excludes tests, development metadata, source artwork, listing copy and private or unrecognised files. `--check` validates without writing, and `--output` selects another ZIP destination.

Run `python3 BrowserExtension/tests/package_test.py` for the packaging regressions; they also run in the ordinary `scripts/test.sh` suite. CI builds the allowlisted ZIP and retains it as the `workbench-chrome-preview` artifact. Store copy, reviewer steps, permissions reasons and remaining publication requirements live in [store/listing.md](store/listing.md). [privacy.html](privacy.html) is the in-product privacy page; [the public-policy draft](store/privacy-policy-draft.md) must also be published on the companion website before submission.

The icons reuse the repository’s canonical `scripts/icon.swift` artwork. To regenerate them on macOS, first run that script into a temporary directory, then run `swift BrowserExtension/store/render-assets.swift <temporary-directory>/icon_512x512@2x.png BrowserExtension`. This creates exact 16/32/48/128px PNGs and the separate 440×280 promotional tile. The 128px icon keeps transparent store padding. The tile is branding artwork; the store still needs a screenshot of the actual extension.

The store name is **Workbench Preview**, version **0.2.0**. Keep the existing draft item `alckfplchkdcjdlhlnhanonkelljnioj` and unpacked identity `ajafaiojgpdgmeblldllnhhfnafiiieo`; do not create a replacement store item or change the manifest key to repair native connectivity. Verify store-installed pairing against the matching companion before distribution. Packaging and the two-origin native allowlist do not establish store approval, publication or live store-installed acceptance.


## Browser setup packs (0.2.0 development increment)

Open **Browser setup for this profile** from the popup. Allow optional bookmark access using that page's button and explicitly choose a writable local root. Setup requires Chrome 134+ metadata; Switch to retains its Chrome 120 minimum. Synced and managed roots are excluded. If profiles share synced bookmarks, use Chrome Sync instead of applying duplicate local packs. Google Password Manager, Chrome Sync, profile creation, startup and New Tab remain Chrome-owned setup steps explained on that page.

The accepted hello advertises `capabilities: ["browserSetup1"]`. The native companion sends `setupPreview`, `setupApply` or `setupLaunch` over the existing paired connection with a v1 UUID request ID, a fresh `expiresAt` timestamp up to 60 seconds ahead, and a bounded `setup` payload. Replies use `setupResult` with the matching request ID and nested bookmark counts/root/notes. Counts exclude folders. Preview returns a single-use five-minute token bound to the normalized pack and owned-node/root snapshot; Apply includes `reviewToken` at message top level. Tokens disappear on worker restart or disconnect. At most 60 bookmarks and eight launch URLs are accepted inside the existing 64 KiB packet ceiling. Setup preserves ordinary query/fragment navigation and rejects known sensitive query keys rather than using Switch to's stripping rules. Unknown pack/bookmark fields, untrimmed names, duplicate normalized launch URLs, and addresses exceeding 4,096 UTF-8 bytes are rejected.

Application creates a new owned pack/role folder and named child folders. Local receipts identify created nodes; matching names never confer ownership. A later apply updates only nodes whose current title, address and parent still match their receipt. Manual changes, missing nodes and changed owned folders are preserved as conflicts. Entries removed from the plan are retained. Chrome does not provide an atomic transaction across read/check/write or profiles, so a concurrent manual browser edit can still cause uncertainty. Each write commits an intent first and a receipt afterward. Any interrupted intent blocks further bookmark writes; there is no automatic adoption, reset, rollback or replay. Inspect the browser before recovery. The profile setup page offers **Keep existing bookmarks and start a fresh copy…** only for a valid interrupted journal. Its explicit confirmation explains that all Chrome bookmarks stay untouched, only that pack/role’s ownership receipts are forgotten, and the next reviewed apply can duplicate kept links. Other pack receipts, root and launch ledger remain intact. Stale confirmations or corrupt state are rejected. A storage or browser failure reports completed entry counts and preserves the uncertainty journal.

Explicit launch creates a new normal window, preserving unrelated tabs. Its request ID is persisted before opening, so an uncertain or duplicate request never opens again. The durable ledger retains each request until its original expiry plus a 60-second grace period, then prunes it on a later launch. The trusted native companion must generate a fresh UUID nonce for each command and never reuse an ID with a new expiry. Original expired requests fail before any effect. Retained IDs remain blocked across worker restarts; there is no lifetime launch limit. Success confirms creation only, not authentication or rendering. Neither native reconnect nor worker restart applies a pack or launches tabs. The separate profile-local default-tab feature below adds a New Tab override and optional extra startup tab; there is no password-store access or profile creation API.

Additional local extension storage is `browserSetup` v1: chosen root, owned-node receipts, interruption journal and launch request ledger. No bookmark tree, credentials or profile directories enter the native protocol or portable pack. Review tokens are memory-only. Removing the extension loses these receipts but leaves its bookmarks in Chrome.

Focused deterministic coverage lives in `tests/setup.test.js`; run the ordinary browser and package suites above. This does not establish live Chrome/native UI acceptance. Before distribution, test the packaged companion and extension using disposable local profiles, permission refusal, sync/root transitions, user edits, process interruption, stale reviews and two-profile partial success. These changes have not been installed or published by this work.

## Profile-local default tabs · 0.2.1 candidate

These controls are new in 0.2.1; extension 0.2.0 does not contain them. Default-tab opening works independently of the native app. Pack review/apply/launch still needs the matching native companion.

Browser setup saves `defaultTab` v1 in `storage.local`: `url`, `redirectNewTabs`, and `openOnStartup`. No native protocol or pack application can set these choices. Both automatic options start false, and the address starts empty. The popup’s **Open default tab** needs neither pairing nor host permission. Query/fragment routes are retained under the same credential/secret-key validation as setup links.

The manifest always claims `chrome_url_overrides.newtab` for `newtab.html`. Installing this candidate changes New Tab to a local Workbench page even while redirect is off. Turning redirect off or clearing settings keeps that page; disabling/removing the extension restores Chrome’s original page and disconnects this profile. Chrome controls precedence with other New Tab extensions. Incognito remains excluded. Only the bundled override page redirects its own document; existing user tabs are not inspected or navigated.

An explicit startup opt-in opens an extra background tab on `runtime.onStartup`, alongside Chrome’s own startup/restored pages. It can duplicate a URL when combined with redirect or Chrome startup settings. It does not run on install, worker boot or reconnect, and failures are not replayed. Save/clear failures surface in setup; invalid stored settings fail closed. The profile-local default URL stays out of the native bridge and Chrome Sync. Every participating Chrome profile can use its own value with the same Mac companion.

`tests/default-tab.test.js` and background lifecycle tests cover URL validation, profile isolation, disabled defaults, clearing, failure preservation, explicit open and startup event boundaries. Real two-profile Chrome UI acceptance and competing-extension behavior remain required before distribution; automated tests alone do not verify them.
