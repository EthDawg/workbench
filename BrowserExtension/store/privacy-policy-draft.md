# Chrome destinations privacy — publication draft

Publish this section in the public Workbench privacy policy before Chrome Web Store submission. Keep it consistent with the packaged `BrowserExtension/privacy.html`. This draft is not itself proof of public publication.

Workbench Preview for Chrome requires the matching Workbench Preview companion for macOS. It saves named web destinations and returns to their explicitly paired Chrome profiles.

The extension handles destination names and profile labels you type, a generated profile identifier, chosen saved URLs, and temporary tab/window identifiers. Opening the popup reads the current tab address locally so you can review it. Switch to removes query parameters and fragments before saving or sending an address; browser setup preserves ordinary query/fragment navigation and rejects known sensitive query keys; usernames and passwords embedded in addresses are rejected. When opening a saved destination, the extension checks the current or pending addresses of permitted tabs. It does not read page content, forms, stored passwords, cookies or browsing history. It does not sign in or rotate credentials.

Chrome stores the profile label, generated identifier and pairing state locally in that profile. Session storage keeps destination-to-tab bindings and an unfinished save draft. A permission-step draft can be restored for 15 minutes; an expired draft is not used and may remain until overwritten or the browser session ends. Runtime tab IDs do not enter durable extension storage. Workbench extension records do not use Chrome Sync. Browser setup writes only to roots currently marked local by Chrome; later Chrome Sync choices may change how Chrome handles those bookmarks.

Chosen names, saved URLs and profile labels pass through Chrome native messaging to the local Workbench app, which owns their canonical Saved resources records on the Mac. The companion supplies this destination list to your connected profiles. Browser destinations are not included in optional Workbench photo or scene sync. This feature sends no destination records to a developer server or other third parties and includes no analytics, advertising or sale of data.

When you choose to open a destination, Chrome contacts that website normally under its own privacy policy. Opening the Workbench website or support links similarly makes a normal web request. The extension does not request account credentials for those sites.

Browser setup is optional. Its page requests bookmark permission only after a user clicks Allow. Chrome grants access to all bookmarks in that profile; Workbench locally inspects metadata to choose a writable local root and check its own recorded nodes. A reviewed setup creates folders/bookmarks and updates unchanged owned nodes. No bookmark tree is exported to the companion; only counts, root labels, fixed notes and temporary review tokens are returned. The extension retains the root ID, owned node IDs and last title/address/parent, operation receipts, an interruption journal and launch request ledger in local storage. Review tokens live in worker memory for up to five minutes. Detected manual edits and existing bookmarks are preserved. An interrupted write blocks further application rather than retrying blindly; Chrome does not offer an atomic cross-profile transaction or read-and-write guarantee against simultaneous user edits.

Open launch tabs creates a new normal window without closing existing tabs or changing startup/New Tab settings. It does not read or change Google Password Manager, Chrome sign-in or cookies. Request IDs are recorded before opening; reconnection never replays a launch or bookmark application.

Site access is optional and requested when you choose **Allow this site**. The extension uses the grant to inspect tab addresses and focus a saved tab. A new tenant subdomain needs a new grant. Chrome may describe the grant broadly as access to that site; this extension has no content scripts and does not inspect or change the page. Incognito is disabled.

You can manage site permissions or remove the extension in Chrome. Removing the extension removes its Chrome-managed local data and ownership receipts but leaves created bookmarks in Chrome; a reinstallation cannot adopt those bookmarks as owned. closing Chrome clears session storage. Saved resources in the Mac app is separate, so uninstalling the extension does not delete those records. Manage those items in Workbench. Device backups follow your system settings.

Workbench’s use of data received through Chrome APIs complies with the Chrome Web Store User Data Policy, including its Limited Use requirements.

For privacy questions, use [Workbench support](https://github.com/EthDawg/workbench/issues). Public issues must not include private destinations or customer details. Security-sensitive information can use [private vulnerability reporting](https://github.com/EthDawg/workbench/security/advisories/new).
