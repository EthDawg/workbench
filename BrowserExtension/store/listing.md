# Workbench Preview — Chrome Web Store draft

This is submission copy and a release handoff, not evidence of store approval or publication. Confirm the public Mac companion download and privacy page contain this feature before submitting.

## Existing store identity

Continue the existing Chrome Web Store draft with assigned extension ID `alckfplchkdcjdlhlnhanonkelljnioj`; do not create a replacement item. The store ZIP omits the development-only `key`; uploading it updates the existing item under Google’s assigned signing identity. The development manifest retains its public key and stable unpacked ID `ajafaiojgpdgmeblldllnhhfnafiiieo`. The companion's native host registration and incoming-origin validation explicitly allow those two identities only. This preserves existing unpacked use while supporting the store-assigned identity; saved destinations and profile pairing are preserved. Version 0.2.0 adds optional browser setup commands and local bookmark receipts; it requires a matching companion for those new actions.

After installing the matching companion, choose **Repair Chrome connection** in **Saved resources → Chrome destinations** to refresh an existing native host registration. A store installation has separate extension storage and requires its own explicit profile pairing. Live store-installed pairing and the dashboard's submission/approval/publication status remain separate acceptance checks.

## Store fields

**Name:** Workbench Preview

**Short description:** Save named destinations and return to the right Chrome profile. Requires the Workbench Preview companion for macOS.

**Category:** Productivity (choose the closest current dashboard category).

**Language:** English.

**Website:** https://workbench-mac.vercel.app/

**Support:** https://github.com/EthDawg/workbench/issues

**Privacy policy:** https://workbench-mac.vercel.app/privacy.html#chrome — the earlier browser-specific disclosure was published and byte-verified on 15 September 2026. The 0.2.0 browser-setup additions in packaged `privacy.html` and `privacy-policy-draft.md` still need public publication before this update is submitted.

## Detailed description

Return to the right demo tab in the right Chrome profile.

Workbench Preview lets you save a web tab under a clear name such as “Manager” or “Employee”, then return to that destination from any paired Chrome profile or the Workbench Mac app. Your saved list lives in Workbench’s existing Saved resources.

Requires the matching Workbench Preview app for macOS. Install the companion from https://workbench-mac.vercel.app/ and enable Chrome connection in Saved resources before pairing this extension. This preview does not operate independently on Windows, Linux or ChromeOS.

Get started:
• Give each Chrome profile a recognisable name and connect it to Workbench.
• Open the intended tab, choose an audience-safe destination name, and review the address.
• Allow that site when Chrome asks, reopen the popup, and finish saving.
• Search or choose a destination to focus its paired profile’s tab.

When a tenant’s subdomain changes, open the new address in its intended profile and update the existing destination. Workbench shows the previous and new address and asks for access to the new site.

Workbench remembers the tab during the browser session. If that tab is gone, it looks for the saved address. One match is focused; no match opens a tab; several matches ask you to choose the right tab and update the destination. Existing unrelated tabs are not navigated or closed. Keep the destination’s Chrome profile open and connected.

Your destination names, saved addresses and profile labels are handled locally and shared with the Workbench companion on your Mac. The extension does not send destination records to a developer server or use Chrome Sync. Switch to removes query parameters and fragments before saving. Browser setup preserves ordinary query/fragment routes and rejects known credential-bearing query keys. The extension reads the current address for saving and permitted tab addresses for matching; it does not read page content, saved passwords, forms, cookies or browsing history, and it does not sign in or rotate credentials.

Opening a destination confirms Chrome’s tab and window focus. It does not confirm which account is signed in, page readiness or what a meeting audience can see.

Free and open source. Preview software: report reproducible issues using synthetic examples and leave out customer data, passwords and private addresses.

Optional browser setup applies a reviewed pack of bookmarks into a selected local folder and opens launch tabs in a new window. Bookmark access is requested only if you enable that feature. Existing bookmarks and detected manual changes are preserved. Chrome 134 or later is required for setup; Switch to continues to support Chrome 120 or later. Workbench does not set startup or New Tab settings, create profiles or change Google Password Manager.

## Single purpose

Prepare and return to reviewed web destinations in explicitly paired Chrome profiles, using the local Workbench Mac companion. Browser setup remains part of preparing those destinations; reassess the final single-purpose description and permission disclosures in the store dashboard before submitting this update.

## Permission justifications

| Dashboard permission | Explanation |
| --- | --- |
| `nativeMessaging` | Connects to the installed `com.ethdawg.workbench.browser` native host. The local Workbench Mac app owns Saved resources and routes each selected destination to its paired Chrome profile. This companion is required and prominently disclosed. |
| `activeTab` | Reads the current tab’s address when the user opens the extension, to show exactly what will be saved. The user chooses a label; the page’s title and content are not copied. |
| `storage` | Stores a generated profile identifier, user-chosen profile label and paired flag, plus optional setup root IDs, owned bookmark receipts, interruption journal and launch request ledger locally in this Chrome profile. Session storage holds temporary destination-to-tab bindings and an editable save draft while Chrome presents an optional site permission. Chrome Sync is not used. |
| `alarms` | Schedules a reconnect attempt 30 seconds after the native companion disconnects, only for previously paired profiles. It never retries a destination activation. |
| Optional `bookmarks` | Granted only from the Browser setup page by an explicit click. Reads bookmark metadata locally to select a writable local root and verify owned nodes; applies a reviewed pack without deletion or adopting existing names. No bookmark tree is sent to the native app. |
| Optional `http://*/*`, `https://*/*` | Supports user-chosen demo sites whose tenant hostname can change. No host is granted at installation. The user grants a specific scheme and hostname through “Allow this site”. That access reads tab addresses for matching and allows the selected destination to be focused. A new subdomain requires another explicit grant. The extension has no content scripts or DOM access and requests neither all sites at once nor wildcard subdomain grants. |

**Remote code:** No. All JavaScript is in the uploaded extension package. Native messaging exchanges versioned data and commands with the installed local companion; it does not download or execute remote JavaScript.

## Data usage answers

Use the live dashboard’s exact definitions. This extension handles user data, so do not describe it as handling no data simply because processing is local.

- Browser setup reads bookmark metadata locally and retains only its owned-node receipts; the native companion receives counts, root labels, fixed notes and review tokens. The bookmark tree is not exported.
- Saved URLs and current/permitted tab addresses are URL/browsing data used solely to save and focus a selected destination. The extension does not enumerate browsing history or track visits.
- User-entered destination/profile labels and a generated profile identifier are handled locally. Labels can contain personal information if a user types it. Describe these and their local companion transfer in the policy and any applicable dashboard fields.
- There is no payment, health, authentication, location, communications or page-content collection for this feature, and no analytics or advertising.
- The disclosed purpose is the only use. Destination records are not sold, used for advertising, used for credit decisions, or sent to third-party data processors. Opening a destination or help link is a normal user-requested website navigation.

## Reviewer instructions

1. Use a Mac with the matching Workbench Preview release, and enable **Saved resources → Chrome connection**. No Workbench account or subscription is required.
2. Install the extension in two regular Chrome profiles. Pair them with synthetic labels such as **Manager test** and **Employee test**.
3. Open a non-sensitive HTTP/HTTPS page in the first profile. Enter a synthetic destination label and choose **Allow this site**. Accept Chrome’s prompt, reopen the popup, and choose **Save destination**.
4. Select that destination from the second paired profile or the Mac app. The first profile’s saved tab/window should activate.
5. Close the destination tab and activate again to open the saved URL. For multiple tabs with the same saved URL after losing the remembered binding, the extension asks which tab to use rather than choosing silently.
6. Update the destination from its own profile to another synthetic site. Review the old/new URLs and grant that site before saving.

Provide the exact public native build URL and its supported macOS version in the submission notes. The companion must include the exact store origin `chrome-extension://alckfplchkdcjdlhlnhanonkelljnioj/` in both registration and host validation; verify the installed registration and store-installed pairing before submission.

## Store assets and remaining publication work

- ZIP: `dist/WorkbenchPreview-Chrome-0.2.0.zip`, generated from the explicit 15-file runtime allowlist.
- 128px icon: `BrowserExtension/icons/icon128.png`; 16/32/48px icons are also packaged.
- Small promotional image: `BrowserExtension/store/promo-440x280.png`, 440×280 pixels, derived from the existing Workbench icon. It is branding artwork, not a screenshot.
- Required screenshot: capture the actual packaged extension with synthetic destinations at **1280×800** or **640×400**. No screenshot is fabricated by the packager. The final changed popup still needs visual/live verification.
- The browser setup increment has not been installed, accepted with live Chrome, or published. A matching companion and updated public privacy policy are prerequisites for distributing 0.2.0. The earlier companion is publicly available as [Workbench 2.0 Preview 4](https://github.com/EthDawg/workbench/releases/tag/v2.0.0-preview.4), build `20260920065909`. It is Developer ID signed, notarized, stapled and retains Production CloudKit. The published ZIP was downloaded back and hash-verified. It includes the browser companion and exact existing store identity; older Preview 3 does not.
- Verify developer registration, contact verification and the current dashboard distribution/review requirements.
- Uploading a draft, submitting for review, approval and publication are separate states. Preserve this distinction in the release record.

## Primary sources checked 15 September 2026

- [Prepare your extension](https://developer.chrome.com/docs/webstore/prepare): ZIP root manifest, manifest description limit and increasing uploaded versions.
- [Manifest icons](https://developer.chrome.com/docs/extensions/reference/manifest/icons): raster PNG assets and standard icon declarations.
- [Supplying images](https://developer.chrome.com/docs/webstore/images): icon padding, promotional tile and actual screenshot requirements.
- [Privacy fields](https://developer.chrome.com/docs/webstore/cws-dashboard-privacy): single purpose, minimum permissions, remote-code declaration and data-use disclosures.
- [Privacy policy requirement](https://developer.chrome.com/docs/webstore/program-policies/privacy): an accurate publicly accessible privacy policy for handled user data.
- [Limited Use](https://developer.chrome.com/docs/webstore/program-policies/limited-use): use only for the disclosed purpose and publish an affirmative policy statement.

## Package correction — 20 September 2026

The first 0.1.1 ZIP was rejected because its retained development `key` did not match the existing store item. The packager now removes only that field from the ZIP and leaves source bytes, the stable unpacked identity and all other runtime files unchanged. The corrected ZIP SHA-256 is `7d9b5b868a23fc593e30bae939946aeaa1ec22d0be5249d682f4b1f93fbf3fcf`. The maintainer handoff names it `WorkbenchPreview-Chrome-0.1.1-store.zip` to distinguish it from the rejected archive. All nine packaging and 64 browser tests pass, including an assertion that the packaged manifest differs only by the omitted key and source identity stays intact. Dashboard acceptance still needs verification.

Google documents the manifest key’s [development identity purpose](https://developer.chrome.com/docs/extensions/reference/manifest/key). Continue updating the existing item; never use this correction to create a new listing or overwrite the unpacked source identity.
