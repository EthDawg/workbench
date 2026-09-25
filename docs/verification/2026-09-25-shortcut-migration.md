# Shortcut migration across Voice and Stage

PR #102 base: `7806392c69a82b1777e9235ed9bad9df6f759f35`. Follow-up branch: `codex/shortcut-followup-20260925`.

## Reproduction

An isolated harness linked the actual Stage module and compiled the base Voice preferences source. Synthetic preference suites reproduced both failures before the follow-up:

- Stage's chosen Timer `Option-V` remained saved, but Voice's migrated Dictate default also claimed `Option-V`.
- Voice's chosen Read `Option-D` remained saved, but Stage's migrated Draw default also claimed `Option-D`.

The host previously gave Voice registration priority. Stage also fell back to fixed Voice reservations after the host explicitly returned that a key was free, so yielding the Voice default alone was insufficient.

## Implemented behavior

Startup reads Stage's chosen combinations before migrating Voice, then reserves the completed Voice catalogue while migrating Stage. Both owners check a fallback key before assigning it; if the preferred and fallback keys are already chosen, that new shortcut stays off. Disabled choices remain disabled and do not reserve keys. The existing revision markers still make the migration run once; later edits to old keys remain intentional choices.

Saved duplicate custom combinations remain saved. Registration pauses all duplicate actions, and Keyboard shortcuts names the other action and explains how to repair the conflict. Editing or disabling either action refreshes the other owner's conflict state. Unrelated Stage edits do not re-register Voice, and an unchanged external conflict set does not re-register Stage, preserving held-key state.

Stage now treats the host's validation result as authoritative. Fixed Voice reservations apply only without a host validator. Read and Present changes also notify the shared registration owner, like the other five Voice actions.

Settings loading suppresses observer writes. This prevents validation or migration from overwriting unreadable Stage preferences with fallback defaults. The existing recovery copy remains available.

## Verification

On an arm64 macOS host, in an isolated worktree:

- `swift build --disable-sandbox --product LocalVoice` passed.
- `.build/debug/LocalVoice --check-shortcut-migration` passed **30 checks** covering both directions, fresh/partially reset stores, fallback exhaustion, disabled choices, the earliest Snap shortcut, one-time persistence, both duplicate repair directions and unreadable preference preservation. This check is included in `scripts/test.sh`.
- `bash scripts/test-stage.sh --shortcut-settings-only` passed **9 tests / 81 assertions** covering existing Stage defaults, migration, chosen-key preservation, app-command migration, later old-key choices, settings validation, persona migration, corruption recovery and duplicate registration planning.
- `git diff --check` passed.

Both focused suites use disposable synthetic preference domains and no global shortcut registration, event monitors, `NSApplication`, or windows. The macOS keyboard-layout service logged a connection warning in this headless invocation; all assertions passed. No installed application, release metadata, website, or real user preferences were changed. This evidence verifies settings and registration plans, not installed keyboard delivery. The integration owner must verify actual Command-Q delivery and the shared Keyboard repair flow in the final candidate.
