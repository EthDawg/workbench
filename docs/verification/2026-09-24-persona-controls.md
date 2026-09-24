# Persona control discoverability · 24 September 2026

Single-card controls now expose a labelled 6–40% Size slider. Multiple-overlay controls expose the selected audience label, Size, Add and Remove without opening the options menu. The existing geometry limits, frozen candidate set, eight-copy limit and explicit Save layout ownership are unchanged. The library exposes confirmed removal and group membership editing; removing a live copy does not delete a saved persona.

Validation on this feature branch:

- StageKit source and legacy test harness compiled with the macOS SDK.
- `--persona-controls-only`: 4 tests, 71 assertions, zero failures. Actual native controls route size/removal to the selected copy, bound their layout inside the panel, keep Add available for an empty set and disable Add at eight copies. Existing independent-copy and empty-set recovery checks also pass.
- `--persona-quick-only`: 5 tests, 76 assertions, zero failures.
- Eight site checks and static site build passed; `git diff --check` passed.
- Production AppKit control views were rendered using `cacheDisplay` with fictional labels and inspected at single/multiple sizes. These are synthetic control-view renders, not whole-screen captures or proof of physical interaction.

The host emitted unavailable system-service warnings but the above checks completed. Live dragging with a physical pointer, VoiceOver, multiple displays, installed-package acceptance and meeting receivers remain unverified. No installation or public binary release is included.
