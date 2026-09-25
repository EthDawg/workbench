# Installing, testing and updating Workbench

Workbench has two persistent Mac identities: **Workbench**, the public production app with a green icon, and **Workbench Preview**, the developer edition with a purple icon and P badge. Its name, sidebar, About and build details identify the edition. Keep one installed copy of each identity. Both editions can be installed, but only one Workbench edition or legacy Voice/StageMark app should run at a time because they share shortcuts. Opening another copy explains which app is already running and leaves its work intact.

## For users

Install a published signed, notarized **Workbench.app**. An extracted app left in Downloads is not the installed copy and can appear as another Spotlight result.

1. Quit the edition you are replacing. Unzip the download, then move the app from Downloads into the **same Applications folder** as the existing copy and choose Replace. For a first install, use **Applications in your home folder** (`~/Applications`). Keep an existing `/Applications` installation in that location.
2. Open the exact installed app and use **Copy build details** to confirm the edition, version and build. Check that the saved work you need is available.
3. Retain the original download ZIP and a verified recovery ZIP for an older build you need to keep. Then move leftover extracted `.app` copies out of Downloads to Trash, so they cannot be mistaken for the installed app. Preserve the original saved-data folders; archiving or removing an app binary is separate from its data.

Existing versions without an updater need this one-time manual replacement. Thereafter Settings → Workbench updates checks the edition's signed feed. Automatic checks and background downloads are on by default; both can be disabled in Settings, and existing user choices are retained. Review update opens Sparkle's native release notes and installation controls. A downloaded update can install on normal Quit or when you explicitly restart an idle app. A recording, presentation, reading, capture queue, timer, drawing or modal edit defers an update-triggered restart. The app saves the current speech session before accepting that restart.

You can keep working while automatic checks and downloads run. Available updates show a quiet in-app reminder. They do not steal focus during a demo. An explicit Check for Updates opens the native updater when idle. Offline or failed checks retain the existing app and explain the failure. No account, unique client identifier or hardware-profile transmission is added. The update and download hosts necessarily receive ordinary network request information. Existing provider and cloud choices are unchanged.

Stable and Preview use separate feeds, preferences and saved data. They never silently switch editions. New versions must increase the bundle build number, even when the marketing version is unchanged. Local builds clearly say **Local build** and do not use the public updater. Install the current published edition to return to its update stream. Copy build details includes edition, version, build, source revision, modified-source status and macOS version, without local paths or user content.

Do not delete saved-data directories when replacing an app. A binary rollback is not a data rollback. Release changes that alter storage must provide a migration backup and establish whether the old binary can safely read the new data. This update adds no storage schema migration. Moving from Preview to Stable is an explicit future migration with its own verification; installing Stable must never silently copy Preview's live data or cloud permissions.

## One workflow for Ethan, Matt and coding agents

Run `python3 scripts/release/status.py` to inspect both Applications folders and ordinary extracted apps directly in Downloads. It labels installed and downloaded copies separately and warns when identities repeat; it never moves or deletes anything. `--json` retains the existing array and provenance fields, adding `location` and `duplicate_identity`. This inventory does not select the installer's destination: the installer still selects an existing copy only from the two Applications folders. It is a bounded inspection, not an exhaustive Spotlight index or a saved status ledger.

1. Start a feature branch/worktree from current main and claim a clear outcome in the existing GitHub issue/PR. One writer per worktree. The integration owner alone updates the shared installed Preview during overlapping work.
2. `bash scripts/test.sh` verifies the source. `bash scripts/build.sh` creates a disposable **Preview** archive without installing. Its ad-hoc signature is for isolated developer testing and cannot be expected to preserve OS grants.
3. `bash scripts/install.sh --no-open` builds with the available Developer ID and replaces the existing Preview in place. It preserves an existing installation in either Applications folder and refuses duplicate copies of the same identity. Quit Preview first. The same signer, bundle identifier and installation path preserve app identity; macOS owns the final permission decisions. Never reset privacy grants, generate a new app identifier, or install a differently named staging copy to fix a prompt.
4. Open the exact installed path, use **Copy build details**, and exercise the changed workflow there. Report source checked, Preview installed, native acceptance, merged, packaged and published as separate states. A new source commit is not evidence about the running app.
5. Use the [release procedure](../scripts/release/README.md) for a clean, signed, notarized artifact, followed by `prepare_update.py`. Publish the exact artifact and verify the public download before deploying its signed feed and matching website link. Do not rebuild between package verification and publication. Preview and Stable require their own packages and acceptance because their identities differ.

Use only these two persistent identities; there is no third QA or staging app. Build products stay disposable and uninstalled in build or verification directories. Persistent developer testing uses the existing purple-P Preview installation and its signed replacement workflow.

The installer holds a per-edition OS file lock during replacement and detects a changed installed binary while it was building. A collision stops with a message instead of overwriting another contributor's result. It retains a previous-package ZIP for recovery. Locks are kernel-owned; never delete a lock file to bypass a running installer.

## Release acceptance

- Confirm the clean source, edition, source revision, build number, update key and feed in the final extracted app match its release receipt.
- Run the final extracted app executable with `--check-readback-resources`. It creates and removes only a disposable synthetic session, verifying packaged Snap & Talk skill lookup, exact companion bytes and reopening without microphone/screen access. Packaging also runs this check on the component and after signed Preview identity conversion. `--check-readback-pack` also verifies legacy pack compatibility, snapshots and preservation using synthetic temporary data. `--check-transcript-handoff` checks selected inputs, original/cleaned wording, chosen roles and screen/narration pairing in the signed Preview and final extracted archive. These checks do not replace the installed New session UI check.
- Verify nested Sparkle code, Developer ID signature, Apple notarization, stapled ticket and Gatekeeper on the final ZIP.
- Exercise an actual old-to-new Sparkle update, including a refused/busy restart and successful idle restart. Confirm one app at the same location, retained saved work, expected code requirement, unchanged update preference and exact new build.
- Test failed/offline checks, a bad signature, cross-edition metadata and a local development build. None may replace the installed app.
- Verify the public ZIP digest, signed feed URL and website download all identify that same version. Test a browser-downloaded first install separately from an already trusted developer Mac.
- On a maintainer Mac, inventory legacy apps and verify the unified app's migrated data before retiring old binaries. Keep recoverable archives and original data. Never auto-delete a customer's apps during an update.

The updater applies only to direct-download macOS packages. The separate mobile app and any future Mac App Store edition use Apple's distribution and updates; this work does not claim Store readiness.
