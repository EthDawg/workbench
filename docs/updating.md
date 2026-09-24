# Installing, testing and updating Workbench

Workbench has two persistent Mac identities: **Workbench** (Stable) and **Workbench Preview**. Preview has a purple icon with a P badge. Its name, sidebar, About and build details identify the edition. Both can be installed, but only one Workbench edition or legacy Voice/StageMark app should run at a time because they share shortcuts. Opening another copy explains which app is already running and leaves its work intact.

## For users

Install a published signed, notarized release in Applications. Existing versions without an updater need one manual replacement. Thereafter Settings → Workbench updates checks the edition's signed feed. Automatic checks are on and can be turned off. Automatic downloads are optional. Review update opens Sparkle's native release notes and installation controls. A downloaded automatic update can install on Quit; a recording, presentation, reading, capture queue, timer, drawing or modal edit defers an update-triggered restart. The app saves the current speech session before accepting that restart.

Scheduled updates show a quiet in-app reminder. They do not steal focus during a demo. An explicit Check for Updates opens the native updater when idle. Offline or failed checks retain the existing app and explain the failure. No account, unique client identifier or hardware-profile transmission is added. The update and download hosts necessarily receive ordinary network request information. Existing provider and cloud choices are unchanged.

Stable and Preview use separate feeds, preferences and saved data. They never silently switch editions. New versions must increase the bundle build number, even when the marketing version is unchanged. Local builds clearly say **Local build** and do not use the public updater. Install the current published edition to return to its update stream. Copy build details includes edition, version, build, source revision, modified-source status and macOS version, without local paths or user content.

Do not delete saved-data directories when replacing an app. A binary rollback is not a data rollback. Release changes that alter storage must provide a migration backup and establish whether the old binary can safely read the new data. This update adds no storage schema migration. Moving from Preview to Stable is an explicit future migration with its own verification; installing Stable must never silently copy Preview's live data or cloud permissions.

## One workflow for Ethan, Matt and coding agents

Run `python3 scripts/release/status.py` to read the actual installed copies, editions and provenance. This is an inspection command, not a saved status ledger.

1. Start a feature branch/worktree from current main and claim a clear outcome in the existing GitHub issue/PR. One writer per worktree. The integration owner alone updates the shared installed Preview during overlapping work.
2. `bash scripts/test.sh` verifies the source. `bash scripts/build.sh` creates a disposable **Preview** archive without installing. Its ad-hoc signature is for isolated developer testing and cannot be expected to preserve OS grants.
3. `bash scripts/install.sh --no-open` builds with the available Developer ID and replaces the existing Preview in place. Quit Preview first. The same signer, bundle identifier and installation path preserve app identity; macOS owns the final permission decisions. Never reset privacy grants, generate a new app identifier, or install a differently named staging copy to fix a prompt.
4. Open the exact installed path, use **Copy build details**, and exercise the changed workflow there. Report source checked, Preview installed, native acceptance, merged, packaged and published as separate states. A new source commit is not evidence about the running app.
5. Use the [release procedure](../scripts/release/README.md) for a clean, signed, notarized artifact, followed by `prepare_update.py`. Publish the exact artifact and verify the public download before deploying its signed feed and matching website link. Do not rebuild between package verification and publication. Preview and Stable require their own packages and acceptance because their identities differ.

The installer holds a per-edition OS file lock during replacement and detects a changed installed binary while it was building. A collision stops with a message instead of overwriting another contributor's result. It retains a previous-package ZIP for recovery. Locks are kernel-owned; never delete a lock file to bypass a running installer.

## Release acceptance

- Confirm the clean source, edition, source revision, build number, update key and feed in the final extracted app match its release receipt.
- Verify nested Sparkle code, Developer ID signature, Apple notarization, stapled ticket and Gatekeeper on the final ZIP.
- Exercise an actual old-to-new Sparkle update, including a refused/busy restart and successful idle restart. Confirm one app at the same location, retained saved work, expected code requirement, unchanged update preference and exact new build.
- Test failed/offline checks, a bad signature, cross-edition metadata and a local development build. None may replace the installed app.
- Verify the public ZIP digest, signed feed URL and website download all identify that same version. Test a browser-downloaded first install separately from an already trusted developer Mac.
- On a maintainer Mac, inventory legacy apps and verify the unified app's migrated data before retiring old binaries. Keep recoverable archives and original data. Never auto-delete a customer's apps during an update.

The updater applies only to direct-download macOS packages. The separate mobile app and any future Mac App Store edition use Apple's distribution and updates; this work does not claim Store readiness.
