# Workbench distribution

Workbench is a free, MIT-licensed native Mac app. Developer ID signing and Apple's notarization service support distribution outside the Mac App Store. A notarization ticket verifies Apple's automated checks; it does not establish that every feature or supported device has been tested. [Apple's distribution guidance](https://developer.apple.com/developer-id/).

## Production, Preview and earlier releases

The [production release record](../site/updates/production.json) identifies the public package, its source revision, ZIP digest and signed update feed. [Workbench 2.4.0](https://github.com/EthDawg/workbench/releases/tag/v2.4.0) is published as build `20261001032329` from `d6b36af7122520c6a47bec157d1d55cc934f6e26`. The [2.4.0 release record](releases/2026-10-01-workbench-2.4.0.md) lists its verified packaging and regression results and remaining native-test limits.

Earlier Voice, StageMark and Workbench Preview releases retain their own package-specific evidence. The historical [Preview 2.0 record](preview-2.0.md) is not the current production or candidate acceptance record.

The persistent identities are `com.ethdawg.workbench` and `com.ethdawg.workbench.preview`. Preserve an existing installation in its current Applications folder; a first install uses `~/Applications`. Quit the edition before replacing it and keep one installed copy of each identity. Follow [Installing, testing and updating Workbench](updating.md) for the shared workflow.

Saved data lives outside the app bundle. The first unified launch copies supported earlier Voice/StageMark files into missing unified component locations and preserves the originals. Subsequent launches keep the unified working copy. See the [product contract](workbench.md#identity-migration-and-release) for the identity and migration boundaries. Published builds use their edition's signed update feed; local development builds have no public feed and require the signed Preview installer for replacement. A binary rollback is not a data rollback; the [update contract](updating.md) records retention and migration limits.

## The path for testers and contributors

1. The [Workbench website](https://workbench-mac.vercel.app) explains the public download. Candidate website source in this branch must not deploy until its matching release assets exist and have been downloaded and verified.
2. GitHub Releases own versioned app ZIPs, release notes and SHA-256 checksums. The website does not host additional binary copies. A checksum detects changed bytes; it does not replace an identified developer signature or notarization.
3. A tester installs one app and tries a small real workflow. Downloaded binaries require no Xcode or developer account; the combined Preview targets Apple Silicon and macOS 14 or later. The actual QA Mac ran macOS 26.5.1; other OS/device combinations need their own evidence.
4. Website feedback prepares an observation for the unified repository or the tester's coding agent. It does not submit issues automatically. Versioned contributor and product-contract links must match the downloaded candidate, including before consolidation merges to `main`.
5. Contributors use the [contribution guide](../CONTRIBUTING.md). GitHub issues are the shared work queue, PRs hold review, and releases hold downloadable versions.

The website cannot establish native microphone, Accessibility paste, shortcuts or overlay behavior. Workbench's optional founder introduction opens an editable email draft inside the app; it does not send email or require website signup.

## Build, verify and promote

`bash scripts/test.sh` runs with Workbench open. StageKit's CI mode includes exclusive global-shortcut registration; while Workbench, Workbench Preview or a legacy Voice/StageMark app holds the defaults, the two checks that need them are reported as SKIP, naming that app, and the rest still counts. Quit it to run them locally; GitHub CI runs them in full.

Follow [the release guide](../scripts/release/README.md) for the exact signed Preview build/install and notarization commands. The ordinary `bash scripts/build.sh` produces the disposable ad-hoc `dist/Workbench Preview.zip` without installing it. `python3 scripts/release/preview.py build` produces a Developer ID-signed `dist/Workbench Preview.zip`; this local build step does not notarize or publish it.

The notarization workflow must verify one clean source commit, channel identity, signature, Apple's Accepted response, stapling and Gatekeeper. Re-extract and verify the final archive. Publish its exact ZIP plus `SHA256SUMS.txt`; never replace a version's binary with a different build. Download the public asset again and compare the digest before changing the matching website link.

A signed, notarized Preview may be a GitHub **prerelease** for independent testing after packaging and local regressions pass, with remaining fresh-Mac and live-workflow checks stated in its notes. Production promotion requires those acceptance checks to be completed. [Native acceptance and publication](../scripts/release/README.md#native-acceptance-and-publication) is the single policy for both channels. A successful build or synthetic speech round-trip alone does not prove first-run usability, automatic paste, device video or an audience's screen share.

For website changes, run `node --test site/tests/*.test.mjs` and `node site/build.mjs`. Check installation wording, version/ref agreement and local assets. Browser interaction and mobile layout need separate evidence when exercised. Preserve the existing Vercel project and `site` root; deploy the unified site only after the matching public download is verified. Never submit synthetic QA feedback as real issues.

## Adoption evidence

The only adoption evidence is public: GitHub's per-release download counts and the repository traffic page. [Adoption evidence](adoption.md) explains what each count means and records the baseline from 5 October 2026. `python3 scripts/release/adoption.py` prints the current counts.

## App Store scope

This consolidation uses the Developer ID direct-download workflow. It does not change an App Store submission, listing or review. A future store edition has separate sandbox, entitlement, distribution and acceptance requirements; the direct-download Preview does not establish that compatibility.
