# Workbench Preview and production

Workbench is one Mac app containing Voice, annotation, boards, timers and device presentation. Preview is a separate distribution channel for that same app.

| Identity | Production | Preview |
| --- | --- | --- |
| App bundle | `Workbench.app` | `Workbench Preview.app` |
| Bundle ID | `com.ethdawg.workbench` | `com.ethdawg.workbench.preview` |
| Executable | `Workbench` | `WorkbenchPreview` |
| `WorkbenchChannel` in Info.plist | Absent | `preview` |
| Application Support | `Workbench/` | `Workbench Preview/` |
| Final archive | `Workbench.zip` | `Workbench Preview.zip` |
| Official output directory | `.build/releases/VERSION-BUILD/` | `.build/releases/VERSION-BUILD-preview/` |

Keep production installed. Run one channel at a time when using the same global shortcuts; macOS gives each combination to one owner. Preview uses separate preferences and saved-data directories. Initial migration copies supported legacy Voice/StageMark data into the unified location; it preserves the original files and does not replace an existing unified session. Both channels currently target Apple Silicon because the speech backend's Intel path has not been verified.

## Local development

```sh
bash scripts/install.sh --no-open
```

After quitting Preview, run the same command to update it. The installer uses an existing Developer ID certificate in Keychain, validates the replacement, keeps a rollback ZIP and swaps only the Preview app. It does not remove app data or reset macOS permissions.

Preview has its own first-run permission prompts. Keeping the signing identity, bundle ID and installed path stable helps preserve later grants; macOS controls the final decision. Contributors can use `--ad-hoc` for disposable builds. The normal installer reuses an existing verified Preview cloud profile when present and refuses to silently remove personal-sync capability. It requires Developer ID signing unless the disposable mode is explicitly selected. Select a public certificate fingerprint with `--identity` when more than one Developer ID is available.

Build a local signed candidate without installing:

```sh
bash scripts/build.sh --preview
```

Install an existing signed Preview ZIP without rebuilding:

```sh
python3 scripts/release/preview.py install \
  --archive "PATH_TO_PREVIEW.zip" --no-open
```

Local signed candidates are not automatically notarized public downloads. Use the official process below for a downloadable Preview. Installation and GitHub publication remain separate actions.

## 2.0 evaluation exception

For `2.0.0-preview.1`, the maintainer explicitly requested implementation and
public Preview delivery while holding all Apple submissions, including
notarization. This evaluation uses a Developer ID signed archive produced by
`preview.py`, with the full local regressions, source revision and SHA-256
recorded in its prerelease notes. It is **not notarized**, is not the normal
release pipeline below, and may be blocked by Gatekeeper on a fresh download.
The site and release must state that distinction. This exception does not change
the signing/notarization gates in `release.py` or authorise a production release.

## Official signed and notarized releases

Run on an interactive release Mac after quitting the installed app so it releases global shortcuts. Ordinary contributors can build and test without a paid Apple account.

1. Have a Developer ID Application certificate and its private key available in Keychain.
2. Reuse an existing authenticated notarytool Keychain profile. If none exists, create one using `xcrun notarytool store-credentials Workbench` and its secure prompts. Keep passwords, private keys and signing exports out of arguments, source control and public conversations.
3. Set the marketing version in `scripts/Info.plist`, review the work and commit it. Production uses its committed build number; the Preview builder assigns a UTC timestamp build number. Keep the channel identities above unchanged.
4. Find the public certificate fingerprint with `security find-identity -v -p codesigning`.
5. Choose the channel explicitly when making a Preview.

Official **Preview**:

```sh
python3 scripts/release/release.py --preview \
  --identity CERTIFICATE_SHA1_FINGERPRINT \
  --team-id APPLE_TEAM_ID \
  --keychain-profile Workbench
```

For a Preview that includes personal photo and scene sync, add the existing Developer ID provisioning profile explicitly:

```sh
python3 scripts/release/release.py --preview \
  --identity CERTIFICATE_SHA1_FINGERPRINT \
  --team-id APPLE_TEAM_ID \
  --keychain-profile Workbench \
  --photo-cloud-profile /absolute/path/to/embedded.provisionprofile
```

The profile must cover the Preview bundle, selected certificate and Production iCloud container. The helper verifies that capability on both the signed candidate and the final extracted ZIP. Omitting this option deliberately produces a local-only app; it must not be advertised as supporting personal sync. Production cloud packaging is not configured by this option.

Official **production** retains the existing default:

```sh
python3 scripts/release/release.py \
  --identity CERTIFICATE_SHA1_FINGERPRINT \
  --team-id APPLE_TEAM_ID \
  --keychain-profile Workbench
```

Both routes enforce the same release gates:

- A clean Git commit before work begins, and the same clean commit after regressions and building.
- The selected Developer ID Application private key, Apple team and working notarization profile.
- The configured regression suite and executable self-checks. Preview reuses `preview.py` for its identity conversion and signing; production keeps its build-then-sign route.
- Exact bundle name, bundle ID, executable, channel, version and archive contents. The archive cannot contain another app, unrelated files, duplicate paths or extraction traversal paths.
- Real, discoverable Transcribe with Workbench Shortcuts metadata, required during building and checked in the packaged app.
- Nested signing with hardened runtime and a secure timestamp, Apple Silicon executable coverage and full signature verification.
- A single notarization submission, explicit `Accepted` status, stapling and Gatekeeper assessment.
- Re-extraction of the final ZIP, another identity/version/signature/ticket check and Gatekeeper assessment of that exact packaged app.

The final channel ZIP, `SHA256SUMS.txt` and `release.json` appear only after these checks succeed. Release directories are never overwritten. `release.json` records the source commit, channel, bundle ID, executable, version/build, architecture, signing team, notarization ID, validated iCloud capability and final archive SHA-256. The tool does not install the app, create a GitHub release or publish website links.

## Interrupted notarization and recovery evidence

Each output directory retains `candidate.json`, `signature.txt`, the exact `submission.zip`, `submission-SHA256SUMS.txt` and, once Apple returns it, `submission.json`. Later evidence includes `notarization.json` and `notarization-log.json`. `submission.zip` is the submitted, unstapled candidate; it is not the final public download.

An interrupted observation is not a rejected submission. Read the saved submission ID and inspect that same submission before considering another release run:

```sh
xcrun notarytool info SUBMISSION_ID \
  --keychain-profile Workbench --output-format json
xcrun notarytool wait SUBMISSION_ID --keychain-profile Workbench
xcrun notarytool log SUBMISSION_ID \
  --keychain-profile Workbench PATH_TO_SAVED_LOG.json
```

Use `wait` only while that submission remains in progress. Check the saved submission checksum before recovering its bytes. After acceptance, recovery must staple the app extracted from those exact bytes and repeat the signature, ticket, Gatekeeper, final-archive extraction and checksum gates above. The script preserves recovery evidence but does not automatically resume an old directory. Do not rerun it merely because waiting was interrupted, and do not publish `submission.zip` or a partially verified archive. If Apple rejected the candidate, inspect the saved log, fix the cause and make a new clean candidate.

## Native acceptance and publication

A signed, notarized Preview may be published as a GitHub **prerelease** for independent testing after packaging and local regressions pass. Its notes must state the remaining fresh-Mac and live workflow checks. Keep stable production download links unchanged until production has its own accepted release.

Production promotion requires the applicable native checks below to pass on the delivered package. The release helper records signing and notarization evidence; it does not perform these interactive checks or authorize publication.

- Download the final channel ZIP through a browser on another Mac or clean account. Verify its SHA-256, expected app identity, normal Gatekeeper opening and first-run permissions. Shell extraction alone is not this test.
- Verify one app and one menu-bar icon; home-window reopen/close behavior; onboarding; shortcut recording, conflicts and practice; and safe switching between speech, drawing and presenting.
- Voice: first model download, microphone start/stop/cancel, transcription, clipboard-only delivery, optional Accessibility paste into a harmless TextEdit document, focus protection, reading/export, and restart/history.
- Annotation: draw/erase/undo, pointer effects, saved boards, timer, display changes and real screen sharing.
- Present: scene and logo persistence, USB device selection/reconnection and actual video, full-screen start/end, and the separate QuickTime/iPhone Mirroring launch paths where supported.
- Confirm Preview preserves existing production/legacy apps and saved data. Never imply unperformed hardware or fresh-Mac tests passed.
- Publish only the final channel ZIP and `SHA256SUMS.txt` as public download assets. Keep the release evidence with the maintainer. Download the published asset back and compare its digest before updating the landing page's matching channel link.

To update production in place from a finished notarized release:

```sh
python3 scripts/release/preview.py install --production \
  --archive "PATH_TO_NOTARIZED_WORKBENCH.zip" --no-open
```

That installer validates the production identity, Developer ID signature, notarization ticket and Gatekeeper. It does not build an ad-hoc production replacement.

## App Store scope

This is the Developer ID direct-download workflow. It performs no App Store Connect, submission or listing operations. A future App Store edition needs separate sandbox and distribution validation; this release does not establish that compatibility.

Reference: [Apple's notarization guidance](https://developer.apple.com/documentation/security/notarizing-macos-software-before-distribution).


### GitHub asset filenames

GitHub normalizes spaces in uploaded asset names: `Workbench Preview.zip` is delivered as `Workbench.Preview.zip`. Preserve the app bytes and SHA-256, but prepare the public checksum file and `release.json` using the actual delivered asset filename. Download the uploaded ZIP and checksum, then run `shasum -a 256 -c SHA256SUMS.txt` in that directory before updating website links. Local packaging receipts retain the original local archive name. Never publish the intermediate `submission.zip`.

## Shared update delivery

[docs/updating.md](../../docs/updating.md) is the user/contributor contract. `bash scripts/build.sh` now makes a disposable Preview package. `--component-package` is an internal packaging step, not an installable developer distribution. Persistent installs use `scripts/install.sh` and the existing Developer ID. Local development packages carry provenance but no update feed. Official release builds receive their edition's feed and the committed public Ed25519 key. The corresponding private update key stays in the release Mac's Keychain under account `com.ethdawg.workbench`; do not export it into CI, chat or source control.

After this document's notarization and acceptance steps, prepare the feed from the immutable final directory:

```sh
python3 scripts/release/prepare_update.py --release .build/releases/VERSION-BUILD-preview \
  --tag vVERSION-preview.N --notes /path/to/release-notes.html --output .build/publish/VERSION-BUILD
```

Use an HTML fragment for concise user-facing release notes. Sparkle generates the appcast, signs the final archive and signs the feed. The helper verifies provenance, keys, edition, signature, notarization, increasing build number and enclosure URL/size. Never manually edit a signed XML file.

After integrating the verified source into `main`, package that exact clean commit and publish:

```sh
python3 scripts/release/publish_update.py --prepared .build/publish/VERSION-BUILD \
  --notes /path/to/release-notes.md
```

This requires the existing maintainer `gh` login. It refuses an existing tag/release or a source other than current main. It uploads a draft, reads back its archive, publishes, verifies the unauthenticated public download digest, then stages `site/updates/EDITION.xml` and the corresponding download record. Commit/deploy that site change together; the website build derives matching download links from the record. Verify the live signed feed and download links after deployment. Other-edition feeds remain unchanged. A failed step does not authorise overwriting an existing release: inspect the recorded GitHub state before a deliberate recovery.

Sparkle helpers are copied with symlinks intact and signed inside-out with their original entitlements preserved. The package includes Sparkle's license. Public builds require signed feeds and verification before archive extraction. Both Preview and production now use monotonically increasing UTC build numbers; their marketing versions remain separate human-facing labels. Preview is a separate identity, so production promotion requires a separately signed/notarized production artifact and its own native acceptance.

For the first updater release, install an older updater-enabled test artifact and verify the full signed old-to-new update before exposing the feed. Existing public versions cannot discover this first update automatically; the website and release notes must explain the one-time manual installation. Do not claim that a command-line package check proves fresh-Mac permissions, a customer's data or live UI acceptance.
