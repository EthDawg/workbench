# Workbench Preview Chrome adapter

> **Paused, including Mac runtime admission — 6 October 2026.** Retained source and compatibility tests only. Current Workbench refuses browser connections even when an older preference enabled them; old extensions may retry but commands are not queued or replayed. Mac packages no longer include this extension or its setup material. Existing Chrome profiles/extensions and Library URLs/bindings are preserved. Use Library’s Copy link or Open in default browser. Resumption requires an explicit decision under [Foundation G](../docs/mac-foundation.md#5-remove-dormant-scope-without-losing-work).

An unpacked Manifest V3 adapter for the Workbench Mac app. Saved resources in Workbench owns the destinations; each Chrome profile explicitly pairs under a name you choose. This adapter stores no passwords and does not sign in, change credentials, read page content, or establish that a persona is authenticated.

## Historical setup

The former development setup and its acceptance evidence remain in the [historical presenter record](../docs/presenter-direction.md#historical-use-before-the-pause). Those controls are no longer available in current Workbench. Do not install or repair the extension to access a saved URL.

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

## Retained package compatibility

`scripts/package-chrome.py --check` validates the retained extension source without creating a distribution. The package script and allowlist remain for compatibility checks; no Chrome release or upload is part of the active Mac workflow.

Run `python3 BrowserExtension/tests/package_test.py` for the retained packaging regressions; they also run in `scripts/test.sh`. CI does not distribute a Chrome ZIP. Store copy and reviewer steps in [store/listing.md](store/listing.md) are historical, as is [the policy publication draft](store/privacy-policy-draft.md).

The retained icons derive from the repository’s canonical `scripts/icon.swift` artwork. Store assets and former submission requirements remain historical reference in `store/`; they are not active packaging work.

The retained store name is **Workbench Preview**, version **0.1.1**, with item `alckfplchkdcjdlhlnhanonkelljnioj` and unpacked identity `ajafaiojgpdgmeblldllnhhfnafiiieo`. Preserve these identities. Their presence in source establishes neither current availability nor store approval, publication or installed acceptance.
