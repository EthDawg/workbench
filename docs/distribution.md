# Workbench distribution

Workbench is a free, MIT-licensed native Mac app. Developer ID signing and Apple's notarization service support distribution outside the Mac App Store. A notarization ticket verifies Apple's automated checks; it does not establish that every feature or supported device has been tested. [Apple's distribution guidance](https://developer.apple.com/developer-id/).

## Unified Preview and earlier releases

The Workbench 2 consolidation is a locally installed, Developer ID-signed Preview. Its notarized public download is still pending. The authoritative workflow evidence and remaining tests are in [Preview 2.0](preview-2.0.md).

As checked on 12 September 2026, the public `local-voice` releases still contain the earlier Voice app, most recently [Voice 1.3.0](https://github.com/EthDawg/workbench/releases/tag/v1.3.0). Earlier Voice and StageMark notarization records describe those specific packages. They are not signing, notarization or hardware evidence for the new single-app package.

The unified identities are `com.ethdawg.workbench` and `com.ethdawg.workbench.preview`. The Preview installer uses `~/Applications/Workbench Preview.app`; manual installs and later replacements should use that same location. Quit the existing copy before replacing it. Do not leave another Preview in Downloads or the system Applications folder and alternate between them.

Saved data lives outside the app bundle. The first unified launch copies supported earlier Voice/StageMark files into missing unified component locations and preserves the originals. Subsequent launches keep the unified working copy. See the [product contract](workbench.md#identity-migration-and-release) for the identity and migration boundaries. There is no automatic updater yet.

## The path for testers and contributors

1. The [Workbench website](https://workbench-mac.vercel.app) explains the public download. Candidate website source in this branch must not deploy until its matching release assets exist and have been downloaded and verified.
2. GitHub Releases own versioned app ZIPs, release notes and SHA-256 checksums. The website does not host additional binary copies. A checksum detects changed bytes; it does not replace an identified developer signature or notarization.
3. A tester installs one app and tries a small real workflow. Downloaded binaries require no Xcode or developer account; the combined Preview targets Apple Silicon and macOS 14 or later. The actual QA Mac ran macOS 26.5.1; other OS/device combinations need their own evidence.
4. Website feedback prepares an observation for the unified repository or the tester's coding agent. It does not submit issues automatically. Versioned contributor and product-contract links must match the downloaded candidate, including before consolidation merges to `main`.
5. Contributors use the [contribution guide](../CONTRIBUTING.md). GitHub issues are the shared work queue, PRs hold review, and releases hold downloadable versions.

The website cannot establish native microphone, Accessibility paste, shortcuts or overlay behavior. Workbench's optional founder introduction opens an editable email draft inside the app; it does not send email or require website signup.

## Build, verify and promote

Quit Workbench, Workbench Preview and legacy Voice/StageMark apps before running `bash scripts/test.sh`. The suite includes exclusive global-shortcut registration, so a running copy can cause an expected conflict even in StageKit's CI test mode.

Follow [the release guide](../scripts/release/README.md) for the exact signed Preview build/install and notarization commands. The ordinary `bash scripts/build.sh` produces the ad-hoc `dist/Workbench.zip`. `python3 scripts/release/preview.py build` produces a Developer ID-signed `dist/Workbench Preview.zip`; this local build step does not notarize or publish it.

The notarization workflow must verify one clean source commit, channel identity, signature, Apple's Accepted response, stapling and Gatekeeper. Re-extract and verify the final archive. Publish its exact ZIP plus `SHA256SUMS.txt`; never replace a version's binary with a different build. Download the public asset again and compare the digest before changing the matching website link.

A signed, notarized Preview may be a GitHub **prerelease** for independent testing after packaging and local regressions pass, with remaining fresh-Mac and live-workflow checks stated in its notes. Production promotion requires those acceptance checks to be completed. [Native acceptance and publication](../scripts/release/README.md#native-acceptance-and-publication) is the single policy for both channels. A successful build or synthetic speech round-trip alone does not prove first-run usability, automatic paste, device video or an audience's screen share.

For website changes, run `node --test site/tests/*.test.mjs` and `node site/build.mjs`. Check installation wording, version/ref agreement and local assets. Browser interaction and mobile layout need separate evidence when exercised. Preserve the existing Vercel project and `site` root; deploy the unified site only after the matching public download is verified. Never submit synthetic QA feedback as real issues. [site/HOSTING.md](../site/HOSTING.md) owns the host, its two addresses and what must never break for installed apps.

## App Store scope

This consolidation uses the Developer ID direct-download workflow. It does not change an App Store submission, listing or review. A future store edition has separate sandbox, entitlement, distribution and acceptance requirements; the direct-download Preview does not establish that compatibility.
