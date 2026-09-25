# Snap & Talk crash patch acceptance · 25 September 2026

Matt’s PR #103 fixes New session in packaged Workbench by resolving the owned SwiftPM resource bundle under Contents/Resources. Its skill and existing session format remain unchanged. PR #104 branding is separate and is not included in this patch.

## Verified before integration

- The live production feed and native Check for Updates agreed on Workbench 2.0.0 build 20260924193053, source c4a2ae5701460459e918d671f203a34ef6d279e8. Both automatic checks and downloads were enabled. That message identified the published package, not unmerged fixes.
- Exact PR #103 head da8ebe2aa911d95a4aa17cf6665c74e9af3147df passed nine process checks for CLI, production and Preview layouts, relocation and recoverable missing resources.
- Existing Developer ID signed Preview was replaced in place with build 20260925052829, verified in Settings and Copy build details. Native New session created an isolated synthetic session; Review opened it with zero captures. The saved manifest, README and exact skill bytes were verified. Screen Recording and Microphone remained Ready. The test entry was removed from Recents and its files retained privately; original session contents were not changed.
- Bounded Claude code review found no blocking resolver defect. Its packaging-coverage finding led to checks after signed Preview identity conversion and after final notarized archive extraction. There are no remaining executable Bundle.module call sites in Sources.
- Release-tool, installer and update-tool suites passed: 19, 11 and 11 tests respectively. GitHub’s Build and test and Site checks passed for #103.

## Release follow-through

The marketing version is 2.0.1. Packaging must succeed from clean main, including the new exact-package check. Publication requires the signed archive, public feed and website record to agree, followed by a native production update and New session check. This source record does not itself claim those later steps completed; the published release receipt and release notes record their outcome.

The eight historical GitHub releases now carry a current-download/manual-upgrade notice while preserving their original notes and assets. Older builds without an updater need one manual upgrade. Workbench and Preview keep separate identities and saved libraries; no silent cross-edition migration is introduced.
