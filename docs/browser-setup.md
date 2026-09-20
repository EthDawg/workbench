# Browser setup packs

**Development candidate; not part of public Preview 4 or the Chrome 0.1.1 store draft.** Browser setup extends Saved resources with a portable bookmark/launch pack and the same deliberate agent handoff used by Snap & Talk. It is a direct-Mac Chrome feature; it adds no mobile UI or account service.

## Use it

1. Open **Saved resources → Browser setup → New Compound pack**. Choose a folder. It contains `browser-setup.json`, `SKILL.md`, a guide and one bookmark HTML file per role. The starter has shared links plus Presenter, Manager/desktop and Employee/Pocket launch sets. These names describe illustrative workflows, not proven authenticated accounts or an ESS implementation.
2. To organise your existing links, export bookmarks from Chrome and choose **Add bookmark export**. Workbench copies the chosen HTML into the pack's `imports/` folder. **Hand off → Claude / Codex / ChatGPT** copies a prompt and reveals the folder; it does not upload or send a message. Give the chosen agent the folder after reviewing its links for private information. Reload its edited JSON before reviewing changes.
3. Create/open intended profiles with Chrome's profile menu. Install extension 0.2+, connect each profile and open its **Browser setup** page. Optional bookmark access is requested only by that page's button. Choose a writable local bookmark location. Chrome 134+ metadata is required; synced and managed roots cannot be selected. Use Google's own sync when the same account should share synced bookmarks.
4. Back in Workbench, assign a role to each intended connected profile. Nothing is selected by default for a new pack. Assignments are saved locally by pack UUID and profile UUID; portable exports do not contain them. Read the role's links and folders, choose **Review selected profiles**, then **Apply reviewed bookmarks**. Reviews expire after five minutes and are single-use. If one profile changes, reconnects or fails, review again.
5. **Launch tabs** separately opens one new window per selected profile. Existing windows/tabs remain. Page rendering and login identity still need checking in Chrome.

For **default tabs** in extension 0.2.1, copy the role’s default URL into that profile’s extension **Browser setup → Default tab** and save. **Open default tab** in the toolbar popup opens it even when the Mac companion is offline. Each profile retains its own address and choices in local extension storage; applying a pack does not change them. Multiple profiles can connect independently to the same Mac companion. The extension does not create profiles or copy their state.

**Installing 0.2.1 replaces Chrome’s New Tab page with a local Workbench page.** Enable **Redirect every new tab** only if that profile should navigate automatically to its saved address. It starts off, with no address configured. Turning it off or clearing the address stops automatic redirection but keeps the Workbench New Tab page. To restore Chrome’s original New Tab page (unless another extension controls it), disable/remove Workbench in Chrome’s extension settings; this also stops that profile’s Workbench connection. Chrome decides precedence and prompts when another New Tab extension is installed. No redirection runs in incognito.

An independent **Open an extra background tab when this Chrome profile starts** option also starts off. It runs only for Chrome’s profile startup event, never extension install/update, a new window, worker restart or native reconnect. It adds to Chrome’s restored/startup pages; enabling it alongside New Tab redirection or Chrome startup URLs can duplicate a page. For Chrome-managed **startup pages**, use that profile’s `chrome://settings/onStartup` settings instead. Startup creation failures are not retried; the popup provides an explicit retry. HTML exports are a manual fallback; repeated Chrome HTML imports can duplicate bookmarks. Regenerate them after editing the JSON.

## State and recovery

| State | Owner | Portable? |
| --- | --- | --- |
| Shared links, roles, folders, ordered launch URLs and default URL | User-chosen `browser-setup.json` | Yes |
| Imported bookmark HTML and agent guidance | User-chosen pack folder | Yes, only when user shares it |
| Selected profile-to-role assignment | Local Workbench preferences | No |
| Bookmark grant, root selection, owned node receipts and in-progress journal | That Chrome profile's extension local storage | No |
| Review token and exact owned-node snapshot | Extension worker memory, five-minute expiry | No |
| Default URL, New Tab redirect and extra startup-tab opt-ins | That Chrome profile’s extension local storage | No; outside the pack |
| Passwords, site sessions, profile creation and Chrome-managed startup pages | Chrome / Google Password Manager | Outside the pack |

Apply is additive. A same-name existing folder is never adopted. Receipts identify the folders and entries Workbench created; an update is allowed only while the current node still matches its last receipt. Manual changes/moves/deletions are preserved as conflicts. Removing a bookmark from JSON never deletes it in Chrome. Existing owned folder names are retained if a pack title changes. Root changes with existing receipts need deliberate reconciliation.

Writes are sequential, not atomic. Before each Chrome mutation the extension saves an intent journal, rereads relevant ownership and checks the command deadline. After mutation it verifies the result and saves the receipt. A failure can leave some work completed; the UI reports per-profile outcomes, never a batch rollback. Disconnects do not replay operations. If a mutation might have completed without its receipt, further writes pause. Inspect the pack in Chrome's Bookmark Manager, then optionally use **Keep existing bookmarks and start a fresh copy** in extension setup. Its confirmation forgets ownership of only the interrupted pack-role; it deletes no bookmarks. The next review offers new copies and can duplicate links the user kept. Other packs remain managed.

Chrome's APIs cannot atomically exclude a manual edit between reading and writing. Ownership is checked immediately before each operation and again afterward; detected races report changed/uncertain instead of claiming success. Launch request IDs are persisted before opening windows, retained through their original deadline plus 60 seconds, and not replayed after reconnect.

## Passwords and profile bridging

Ethan selected **Chrome / Google Password Manager**. Chrome can make saved passwords available where the user signs in with the same Google Account, under the user's saved-info settings. Distinct accounts/profiles do not become a common password vault through Workbench. Profile labels do not verify a signed-in identity. Keep role-specific site sessions under Chrome's normal controls.

Ordinary extensions cannot use Chromium's component-only `passwordsPrivate` API. This feature never edits Chrome profile/password databases, imports password CSVs, copies cookies, or rotates credentials. The existing weekly-password issue remains separate. Bookmark packs supply repeatable shared navigation without merging authentication state.

## Validation and compatibility

- Strict schema 1; unknown fields rejected; 256 KB input limit; 1–12 roles; at most 60 bookmarks and 8 launch URLs per role; one-level folders; stable IDs. Each role must fit the 64 KB native frame.
- Only HTTP(S) navigation URLs. Unlike Switch to's canonical destination URLs, setup URLs preserve normal queries and fragments for demo routes. Embedded credentials, controls and known secret query/fragment keys are rejected. This is not a guarantee that every URL is public: review links before export or agent sharing.
- Native `browserSetup1` capability negotiation keeps older extension installations usable for ordinary destinations and reports setup as unsupported promptly. Native review/apply/launch share the app's existing interaction guard and serialize with destination focus.
- The 0.2.1 manifest adds a New Tab page override, a visible installation behavior change. No required permission was added. Optional `bookmarks` access is broad at Chrome's permission layer; implementation confines writes to a selected local root and receipt-owned nodes. Bookmark tree metadata is read locally to verify ownership. It is not sent to an agent or developer service. Selected pack links cross only the existing local native bridge unless the user opens a site or shares the folder.
- Both existing unpacked and Web Store native origins remain allowed; store packaging still omits the development key. Existing Preview 4 and store draft 0.1.1 are not replaced by this branch.

## Test and release gate

Focused commands:

```sh
swift test --disable-sandbox --filter PresenterKitTests
swift build --disable-sandbox
.build/debug/LocalVoice --check-presenter
node --test BrowserExtension/tests/*.test.js
python3 BrowserExtension/tests/package_test.py
python3 scripts/package-chrome.py --check
```

Native socket checks require permission to bind a temporary current-user Unix socket. Synthetic data is used throughout. `--export-browser-setup NEW_FOLDER` exports a usable Compound starter without touching Chrome. `--render-browser-setup-fixture OUTPUT.png` renders the actual SwiftUI view to a PNG; it is layout evidence, not live browser acceptance. `--browser-setup-fixture /tmp/wb-browser-setup-NAME` is a developer-only isolated window with display-only fake profile peers; it must not be represented as a working Chrome connection.

Before promoting into a signed public Preview/store update, use two disposable real Chrome profiles: grant/deny permission; select a local root; apply one shared/role pack to only the chosen profile; reapply without duplicates; manually edit one managed bookmark and verify it survives; launch ordered tabs with another window already open; restart/reconnect and verify nothing replays. Also check an account-synced root is unavailable and normal Switch to still works. Also verify extension 0.2.1 in two disposable profiles: distinct saved default URLs; manual open with the Mac offline; redirect initially off; enabling and disabling redirect; clear address; fully quit/restart Chrome with startup opt-in on/off; no opening on extension reload/reconnect; conflict prompts with another New Tab extension; and disable/uninstall restoring Chrome’s page. Existing tabs must stay intact. These real Chrome acceptance steps remain outstanding; the UI-control service timed out during the original session, and protected Chrome settings/store automation was unavailable during the default-tab increment. Never overwrite real user profiles for tests.

## Research basis — 20 September 2026

The implementation uses supported [bookmarks](https://developer.chrome.com/docs/extensions/reference/api/bookmarks), [optional permissions](https://developer.chrome.com/docs/extensions/reference/api/permissions), [windows](https://developer.chrome.com/docs/extensions/reference/api/windows) and [native messaging](https://developer.chrome.com/docs/extensions/develop/concepts/native-messaging) APIs. [Startup overrides](https://developer.chrome.com/docs/extensions/reference/manifest/chrome-settings-override) and [New Tab overrides](https://developer.chrome.com/docs/extensions/develop/ui/override-chrome-pages) are manifest-level product decisions, not a runtime cross-profile settings API. Google owns [profiles](https://support.google.com/chrome/answer/2364824) and [saved information](https://support.google.com/chrome/answer/165139); Chromium's [permission features](https://chromium.googlesource.com/chromium/src/+/main/chrome/common/extensions/api/_permission_features.json) restrict private password access. The Compound routes were inspected read-only; no demo hiring/offboarding actions were executed.
