# Build-specific App Review evidence

Recovered and refined 21 September 2026 from unpublished preparation commit `0db38e6aa74aa65c507874179f5db789e30736fd`. This preserves a useful delivery gate. It does not submit an app, resolve a rejection or attest that an untested build is ready. Private review messages, submission identifiers and contact details remain outside the repository.

The [mobile store-preparation record](../ios-preview.md#store-preparation--20-september-2026) owns the documented candidate/status. The [Preview 4 record](../releases/2026-09-20-preview-4.md) owns the direct Mac download. Refresh the actual selected build in App Store Connect before using these instructions; this recovery did not inspect that account.

## Why the earlier preparation could not finish the job

The existing mobile record describes a request for more information about an older standalone StageMark Mac submission. It does not establish rejection of the mobile candidate or unified Mac Preview. Physical recordings and build-specific acceptance remained missing. Documentation and polished artwork cannot supply that evidence.

Keep three products distinct: the older submitted Mac binary, the separate mobile candidate, and the unified Developer ID Mac Preview. Record the actual build under review. Mac notarization does not establish App Store approval, and an internal TestFlight build is not a public release. A unified Mac store candidate needs its own sandbox, entitlements and supported-feature acceptance.

Apple's [App Review Guidelines](https://developer.apple.com/app-store/review/guidelines/#app-completeness) call for complete, functioning submissions and accurate review information. [Replying to App Review](https://developer.apple.com/help/app-store-connect/manage-submissions-to-app-review/reply-to-app-review-messages) explains the review-message/attachment route. Sources checked 21 September 2026. A physical launch-to-feature video is the documented case-specific request here, not a universal new rule inferred from those pages.

## One evidence packet per selected build

Record app/platform/version/build, source or signed-artifact identity, device model, exact OS, date and results. Keep account identifiers private. The packet needs:

1. A recording on the actual physical device beginning before app launch and showing the advertised main journeys. Simulator images and generated concepts do not substitute for this request.
2. A concise purpose/audience explanation and exact navigation steps, setup, permissions, optional downloads and any required sample material.
3. An accurate service/region explanation. Distinguish local Apple tools and private iCloud from optional providers in other editions. Worldwide storefront availability does not prove identical speech support.
4. Relevant rights/provenance checks for bundled artwork/dependencies and accurate regulated-use/content declarations. Do not invent a public content feed, account login or paid flow that the selected build does not have.
5. Working support/privacy links and completed current listing fields. Keep reviewer credentials, if genuinely needed, in the private review fields rather than Git.

Use the incomplete [mobile review-notes template](mobile-review-notes-draft.txt) only after checking every claim against the chosen mobile build. Remove unsupported features and resolve all placeholders before submission. It is not a Mac review reply.

## Physical rehearsal

Use harmless synthetic items in an isolated test library, preserving existing user work. Record failures and fix/retest the replacement build rather than hiding a broken advertised feature in a video.

| Mobile journey | Observable result |
| --- | --- |
| Dictate | Confirm language/assets, permission, actual transcript, save/reopen, interruption/denial and recovery. A Ready label is insufficient. |
| Read aloud | Enter synthetic text, choose an available voice, play/pause/stop and verify the actual audio route. |
| Mark up | Import a project-owned sample, draw, undo, save/reopen and export a copy; preserve the original. |
| Scenes | Prepare, save and reopen a scene. If advertising paired Mac handoff, demonstrate receipt/reopening and a deliberate return edit on the real second device. An upload receipt alone is insufficient. |
| Wallpapers / Saved | Adjust crop, save to Photos, finish wallpaper installation in Apple's UI, and find saved work later. Do not imply automatic installation or a Live Photo. |

Repeat essential journeys on each supported physical form factor, including rotation, Pencil or accessibility where advertised. A short recording may communicate the normal journey while separate QA records cover failures. There is no invented mandatory recording duration.

For a Mac store candidate, record the sandboxed submitted app on a physical Mac, including how to find menu controls, permissions, save/reopen/export and cleanup. Do not demonstrate Developer ID-only automatic paste, native-host installation or motion as store functionality without verifying that edition.

## Submission handoff

Keep actual screenshots and feature copy aligned with the selected binary. Earlier promotional composites in `docs/app-store/2026-09-08/` and later generated concepts are design assets, not acceptance evidence. Beta status, unfinished scope and a finished App Store product need an explicit decision; renaming alone does not resolve this.

Attach the real recording or a stable reviewer-accessible link and verify access. Put the requested explanation in the relevant review reply and Review Notes when the specific request requires both. Recheck selected build, privacy answers, rights, screenshots and availability in the account. Retain the receipt of what was submitted; completing this packet cannot guarantee approval. Replacing the binary may require a new recording and revised notes.
