# Snap & Talk packaged-resource crash · 25 September 2026

Production build `20260924193053` crashes during New session. The reported main-thread stack enters Swift's assertion failure from the generated `NSBundle.module` initializer, called by `ReadbackStore.writeCompanionFiles` and `ReadbackStore.create`. The installed executable's build and binary identity matched the report. Its deck skill exists under `Contents/Resources/Workbench_LocalVoice.bundle`; the generated accessor instead probes the app bundle root and its original development build directory. This is a resource lookup failure, not a missing microphone grant.

`ReadbackResources` resolves the app-owned Resources location explicitly. Command-line builds retain executable-adjacent resource lookup. Packaged apps never fall back into the developer's build directory. The readable skill bytes are loaded before any session files are created; a missing bundle/file returns an ordinary error rather than a fatal generated accessor. Existing skill contents and session format remain unchanged.

Evidence on this branch:

- Full Mac debug build passed on current main plus this fix.
- Nine separate-process checks compile the actual store and resolver, exercising CLI layout, Workbench/Preview layouts, relocation, missing skill and missing bundle. Missing resources leave both absent and existing empty destination folders untouched.
- The full Workbench debug executable passed `--check-readback-resources` from its build directory and from a disposable ad-hoc `.app` with the actual `Contents/MacOS`, `Contents/Resources` and Sparkle framework layout. It creates/reopens a synthetic session and verifies the exact copied skill and README. The app was not installed or opened as a GUI.
- Full `--check-readback`: 72 storage, 11 admission, 19 availability, 18 recovery and 25 ordering checks passed (145 total).
- Nineteen release-tool tests and sixteen site tests passed. Shell syntax, Python compilation and diff whitespace checks passed.
- The unchanged Preview installer test suite has seven passes and four failures on this host: its mocked home directory does not isolate the real system Applications directory, so duplicate identity detection prevents its simulated install/rollback cases. No installed app was replaced. Installer source/tests are unchanged by this fix.

Component packaging now runs the full app's `--check-readback-resources` before producing its ZIP. The final signed/notarized archive, installed New session button and release/feed promotion still require the integration owner's normal workflow. No user session, installed app, identity, permission, public download or updater feed was modified. The private crash report is not included in the repository.
