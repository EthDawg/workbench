# Recent user journeys — 15 September 2026

This review covers phone presentation plus the recent dictation, scene/background and persona-overlay changes. It uses disposable data. It does not certify App Store readiness or a meeting receiver's experience.

## Changes found through the journey review

| Moment | Previous gap | Result |
| --- | --- | --- |
| Choose a phone route | Picture, Mac control and two-way phone audio were easy to confuse. A fallback app could open while Workbench still owned USB capture. | One native Connection & audio guide; explicit End preview & open waits for window closure and capture cleanup. First source choice is explicit; reconnect never selects a different device. |
| Finish a Mac dictation when storage fails | The state save swallowed its error, then the successful transcript path deleted the owned audio. | One local recovery record; save precedes delivery. Retry saving uses the same capture ID and no models or old destination. Newer saved drafts survive restart. |
| Paste over an iPhone draft | Whole-draft Paste replaced current and original text without preserving the previous work. | A single disk transaction preserves the previous draft and installs the replacement. Failed writes, oversized and empty payloads keep the prior state. |
| Show one persona card | Group preflight could fail after Personas closed, leaving its error hidden. | The failure result uses the same visible post-dismiss error path as prepared sessions. Existing output remains intact. |
| Read a long connection route, then choose another | The new guide retained the old scroll offset. | Each route resets to its first instruction; Done and fallback remain outside the scrolling text. |

## Automated evidence

- Baseline `fb48227`: [GitHub run 34895796347](https://github.com/EthDawg/workbench/actions/runs/34895796347) passed Mac, iPhone and iPad.
- Final full Mac regression at `ec2f961`: release, voice/core/provider/refinement/reading/library/keyboard checks, 97 shared Swift tests and 121 StageKit tests / 2,601 assertions passed. The same run includes all 51 capture-persistence checks. The release build also passed.
- Integrated phone guide and overlay fix: 121 StageKit tests / 2,601 assertions passed. Six phone-specific tests cover permission diagnostics, explicit selection, both teardown orders, duplicate/failing launch, interrupted native transition and capture callback lifetime. Persona coverage includes missing artwork and a busy or oversized group, without dropping existing output.
- Mac capture recovery: 51 focused checks passed using exact production transaction/lifecycle methods, real temporary recovery files and injected recognition, delivery and state writes. Tests include failed commit, retry without duplicate history or delivery, cancellation, cold recovery, a newer saved draft, explicit discard, invalid/future data and preserving imported originals. Both state and recovery-text writes can fail; that case reports the limitation honestly.
- iPhone Simulator: 77 native unit tests passed, including the two new Paste transaction tests. The initial 11-test UI run had one incomplete-text-entry failure while desktop automation was also active. The exact failing test then passed in isolation. The full UI-only rerun then passed all 11 tests with desktop automation idle. The initial failure remains part of the evidence; no source change was made to mask it.
- Site: eight existing tests passed. Final build and deployed file verification are recorded with the delivery below.

## Native inspection

The actual Connection & audio sheet was exercised in an isolated AppKit host with the real SwiftUI guide and a fake app-opening boundary. All three jobs and six routes, workplace disclosure, scrolling, route reset, Escape, Return/Done and post-dismiss fallback callback were checked. [Actual capture](../../site/assets/guide/phone-guide-actual.png) and [source provenance](../../site/assets/guide/phone-guide-provenance.json) stay with the guide.

A first disposable fixture launch stalled while resolving shared libraries outside its bundle. The fixture was repackaged with its two built modules and correct relative library references, then opened normally. This was a test-host packaging issue, not evidence of a Workbench connection defect.

Earlier native overlay, backdrop and motion evidence remains attributed to its own source revision. This review reran the relevant preservation, snapshot, stale-save, pause/resume and ownership tests; it did not replace the user's library or change their desktop. A code review found no additional concrete ambient/background lifecycle defect.

The recovery HUD’s exact failure view was also rendered at its 480 × 128 content size with inert model actions. Retry saving, Open Workbench and Dismiss remain accessible. Long error detail is shortened in the HUD, with the full message available through its help and main editor. This component check does not simulate disk exhaustion in the installed app.

The public phone guide was checked at desktop width and a 390-pixel iPhone viewport. Routes become stacked cards on small screens so limitations remain visible. Both generated and actual images loaded; the page has no horizontal overflow.

## Delivery record

- Runtime commit: `ec2f9611281f8e14d9431ec88c5447c5f274de93`.
- Signed and installed Workbench Preview 2.0.0, build `20260914220342`, bundle `com.ethdawg.workbench.preview`. Developer ID verification passed with normal macOS certificate access; the restricted-shell check could not validate it. The installed executable exactly matches the signed archive.
- Archive SHA-256: `9c96a518f048bd0559bc18899eca956300a4f7052349c3a7b01cf95069822921`.
- Executable SHA-256: `f1f5c7ff2ee939f8143cbf9ceadb40db3df4fd0541fb765bbf98cae78834db3e`.
- Installed-app inspection: Home → Present a device → Connection & audio → Voice conversation → Done passed without starting capture. The existing scenes stayed visible. No user library was replaced.
- Site: eight tests and the static build passed. [The phone guide](https://workbench-mac.vercel.app/phone-presenting/) was deployed to the existing production site from site commit `87f28fb`. Vercel deployment `dpl_7zGQSRTVe99puKJkeKNNqJsEAT6T` reports READY; ten public pages/assets were HTTP 200, matched the reviewed build byte-for-byte and retained `nosniff`. The public downloadable binary remains Preview 3.
- The pre-change guide archive was saved to the owner's AI OS Drive and verified before material edits. Its private link is intentionally omitted from this public record.

[Draft PR #36](https://github.com/EthDawg/workbench/pull/36) contains this review. Its GitHub Mac, iPhone and iPad checks were still running at handoff; the local results above are complete.

The source review is stacked on PR #35 to preserve the pending multi-overlay, ambient and motion baseline. It does not merge those releases.

## Remaining acceptance

Physical iPhone unplug/reconnect; a real Apple-app fallback acquiring the released device; live voice-agent microphone, reply and interruption; Teams/Zoom desktop and browser receiver views; and multiple displays/Spaces remain separate tests. No workplace policy, account, audio driver, permission, cloud opt-in or physical phone state was changed for these regressions. Scene/photo cloud reception, App Store declarations, signing for store submission and public binary publication are separate release boundaries.
