# Snap and Snap History

Snap is a deliberate Mac capture utility. Region and Window use Apple's interactive selector; Screen captures the display under the pointer. Workbench hides its capture controls while acquiring the image. Screen Recording access remains a macOS permission. Cancel or Escape creates no history item, and the selector writes only to a private temporary location removed when capture finishes. No automatic Desktop image is created.

The desktop Snap workspace owns quick crop, pen, arrow and rectangle annotations, titles, optional notes and tags. Paste image and Import image open the same unsaved editor. Save retains the image in Snap History; Save & Copy also places the rendered PNG on the clipboard. Closing or cancelling an unsaved editor leaves history unchanged. Copy and explicit Export use the saved crop and annotations. The original image remains available for later editing; imported external files are never changed.

## Ownership and preservation

`SnapModel` is the app's single Snap owner. `SnapStore` keeps one directory per stable UUID in the current Workbench edition's `Snaps` support directory. `original.png` is immutable; edited PNGs have distinct immutable filenames. A versioned `snap.json` links the original, rendered image, non-destructive crop/marks, metadata and an optional archive date. A per-record revision rejects stale editor saves, including after an incidental history reload. Atomic metadata replacement follows private media writes, and oversized metadata is rejected before commit. Unreadable or newer-format records produce recovery notices; valid records remain available and no automatic eviction runs.

Archive is reversible metadata. Restore returns the same UUID and files to history. Snap does not automatically delete original images, older edits, archived captures, earlier narrated-session files or a running task's input bytes. This first version has no permanent-delete command. The product remains account-free and works locally without a provider.

Search covers title, source type, notes and tags. Every search term must match. Filtering does not discard selection; the footer reports selected Snaps outside the current view. The host supplies a binding backed by the common history selection owner, preserving transcript references when a Snap is selected or cleared. Saved selections contain UUID references rather than exported folders. Missing or archived selected images stop handoff with a visible explanation.

`SnapModel.handoffSnapshots(ids:)` returns frozen original/rendered bytes and metadata in saved-history order. One request allows up to 100 Snaps and 256 MB of image bytes. The common handoff flow owns destination, selected-content review, provider status, task receipts and outputs. Editing or archiving a source after dispatch cannot change that job.

## Snap & Talk composition

Create or open an existing Snap & Talk session, then add selected history images. `SnapReadback` copies original and rendered PNGs plus source identity into new portable section directories and appends them to the existing v1 manifest. It preserves current section order, custom skills, frozen private packs and all earlier sections. The session remains usable away from this Mac's Snap store.

Imported sections are ready with optional editable notes and no invented audio or original transcription. Record narration is an explicit separate action. The existing capture-and-narrate shortcut keeps its established behavior. Re-adding the same source bytes and metadata skips the existing section, including one in Recently Deleted; restoring that section is explicit. A changed source produces a new frozen section without replacing the earlier version. Invalid batch inputs are checked before any section is created.

The host also wires `ReadbackModel.onSaveCapturedSnap` to `SnapModel.saveNarratedCapture`. A new screenshot from the existing Snap & Talk shortcut first enters this same Snap History, then becomes a portable narrated section with a source receipt. Adding it back to that session skips the duplicate. If the session addition fails, the app identifies the saved capture in Snap History for retry. Earlier sessions are not bulk-imported or rewritten. Narration, section replacements and custom session edits remain owned by their portable session; they never mutate its original source Snap.

## Organisation and synthesis

Organise reviews the exact selected UUIDs. Its local overview groups saved titles and notes by their existing tags and links to each immutable source image. Byte-identical rendered images become duplicate proposals; similar-looking or low-value images require human judgement. Archive reviewed duplicates is explicit and refuses changed sources or a changed retained copy. Originals remain recoverable.

Repeating the same selected UUID set updates one private overview under `Snaps/Reviews`; it does not create another batch folder. Archived duplicates are not proposed again. Hand off for synthesis opens the common selected-content review with a bounded instruction to create one useful themed document, link claims to source UUIDs/images, distinguish evidence from inference, and list exclusions for review. It cannot automatically apply an assistant's proposed cleanup. A result or summary is never authority to delete evidence.

## Verification boundaries

`bash scripts/test-snap.sh` compiles the actual storage, renderer, organisation and portable-session importer with synthetic fixtures. It checks crop pixels and dimensions, annotation output, immutable originals/snapshots, stale-save refusal, serialized-size limits, private file modes, corruption/symlink refusal, reversible duplicates, stable result paths, optional narration, repeated import, ordering and unchanged pack/skill bytes.

These checks do not establish installed capture permissions, region/window selection, clipboard delivery, keyboard/VoiceOver behavior, multi-display capture or the combined provider round trip. Native acceptance must also confirm a fresh Snap & Talk shortcut capture appears once in Snap History, adding it back does not duplicate its section, and canceling narration retains the image. The sole Preview integration owner verifies those journeys on the signed candidate, records Copy build details and follows [the shared install/update workflow](updating.md). Source implementation, automated checks, native acceptance and public release are distinct states. Track the combined delivery in [issue #112](https://github.com/EthDawg/workbench/issues/112).
