# Browser setup candidate · 20 September 2026

Status: development candidate, awaiting real Chrome acceptance. Public Preview 4, the installed Preview build `20260920065909`, the website download and the accepted Chrome 0.1.1 store-draft package remain unchanged. This is not a notarized release or an App Store submission.

## What changes

- Saved resources gains Browser setup: create/open a portable pack, import bookmark HTML for an agent, hand off to Claude/Codex/ChatGPT, reload edits, and export conventional bookmark HTML per role.
- The Compound starter includes shared links and Presenter, Manager/desktop and Employee/Pocket examples. Profile role assignments stay on the Mac; the portable pack contains no browser profile identities or credentials.
- Select multiple paired Chrome profiles, review bookmark counts and apply an additive update. Existing manual edits are kept. Repeating a successful apply uses durable ownership receipts instead of creating another copy.
- Launch tabs opens ordered role URLs in a new window per selected profile, preserving existing tabs. Startup and New Tab remain separate, explicit per-profile setup. The Google Password Manager guide covers native account sharing without copying passwords or sessions.
- Extension 0.2 adds optional bookmark permission, explicit local-root choice and an interrupted-write recovery action. Store packaging retains the existing store identity and omits the development key.

See the [browser setup contract and acceptance steps](../browser-setup.md) for use, data ownership, recovery and limitations. The matching extension and Mac candidate must be used together for setup; older extensions continue ordinary destination switching.

## Verified

- Full Swift package suite: 113 tests passed. Final pack/protocol rerun after input/handoff refinements: 16 tests passed.
- Native socket integration: 37 checks passed from both the development executable and packaged app, using isolated temporary libraries and preferences. Includes capability compatibility, selected-profile routing, wrong-peer reply refusal, busy state, role assignment persistence and interrupted request completion without replay.
- Extension: 90 Node tests passed. Includes permissions/local roots, synced-root rejection, repeat apply, manual edits, stale review, partial failure, recovery isolation, schema constraints, ordered launch and replay expiry.
- Chrome packaging: 10 tests passed; generated archive validated at version 0.2.0 with 15 runtime files and no development key.
- Website: 8 tests passed. Privacy source explains the development feature; public download links were not changed.
- Skill frontmatter validation passed. The real SwiftUI view was rendered and visually inspected. Compound starter JSON, skill, guide and HTML files were exported successfully.
- Production build completed. Packaged native host, extension and skill match the source; ad-hoc signature verification passed. This does not constitute notarization.

## Local artifact hashes

| Artifact | SHA-256 |
| --- | --- |
| Development Mac ZIP | `87e800ed6a5432beffccd9a4b401e591f2d598ed83ec4db149e50db212afa723` |
| Chrome 0.2.0 store-format ZIP | `62d61c209cde1f6005825762968f5c8f1bf77a2b9524503b5de0a52cacb62504` |

## Still to verify before promotion

The computer-control service timed out while opening the disposable native fixture. No live Chrome bookmark permission/apply flow is claimed from this session, and no real profile/bookmark/password changes were made. Use the two-disposable-profile acceptance sequence in the contract before merging/promoting the feature, then build and notarize a new Preview from the accepted commit. Do not replace the current store draft with 0.2.0 until that matching native companion is ready. Hardware/iOS/App Store work is unaffected.
