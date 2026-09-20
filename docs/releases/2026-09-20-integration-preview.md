# September contribution Preview

This candidate brings Matt's nine contributions together with the pending persona, scene-motion, phone-route and Chrome-destination work. It is for hands-on acceptance before the next public release. The public download remains Preview 3 until a new archive is separately notarized, verified and published.

## What to try

Use disposable text, files and a non-confidential screen. Run only Workbench Preview while testing its global shortcuts.

| Job | Try this | Expected result |
| --- | --- | --- |
| Quick Look | In Saved resources, preview a text file, PDF or picture. Press Escape. Preview again and start a presentation. | Escape closes only the preview. Starting presentation closes it and releases file access. Search and selection remain available. |
| Break timer | Drag the timer near a screen edge; release, hide and reopen. Try Position, restart, and an external-display disconnect if available. | It snaps on release, remembers its position and returns within an available display. Countdown and presentation remain separate. |
| Screenshot handoff | Add disposable screen annotations and choose Workbench's Screenshot action. Capture a region, then cancel another attempt. | Workbench controls/pointer effects stay out of capture; annotations remain available afterward. Apple's Shift-Command-5 is a separate route. |
| Transcript export | Export cleaned and original versions from Recent transcripts. Cancel once; save over a disposable file through the confirmation. | UTF-8 text matches the selected version. History and current draft remain unchanged. A successful retry clears a failed-export message. |
| Read aloud | Start generating a long passage with a Mac voice, cancel, then read a short passage. | Cancel stops generation; no late playback starts. Previously completed audio survives a cancelled replacement. |
| Speko voices | If you already use Speko, load its voices and choose one or Automatic. Restart and check the selection. | Voice choice persists independently of dictation models. Actual online speech remains an explicit action using your account. |
| VoiceOver | Navigate two history rows and the drawing colour controls. | Actions identify their capture, including same-second captures. Colours announce meaningful names and selection. |
| Snap & Talk | Create a disposable session, capture a harmless screen and narrate two sections. Cancel a rerecord, reorder, remove/restore a section, then reopen. | Screenshots, original audio/transcripts and edited narration remain linked. Cancelling a rerecord retains prior completed work. |
| Existing presentation | Reopen an existing scene; test persona visibility/next/previous, presentation End and optional motion Pause. | Saved content remains intact; controls are reachable and separate jobs end independently. |
| Chrome destinations | With the existing paired extension, switch to a saved destination; try a closed tab and an ambiguous duplicate. | Correct profile/tab opens or Workbench requests an explicit choice. Snap & Talk and Switch to have separate shortcut assignments. |

For Snap & Talk, macOS may require Screen Recording and Microphone permission. Complete those system decisions yourself. Check a Teams/Zoom receiver and physical phone/display reconnect separately if those workflows matter to the release. Simulator and synthetic tests cannot establish these results.

## Review fixes included

- Confines portable Snap & Talk sections and their files to the matching section directory, rejecting malformed paths and symlinks before destructive operations.
- Preserves transcription completed during screenshot capture and restores earlier narration when rerecording is cancelled.
- Bounds Speko catalogue downloads while receiving data and limits pagination independently of voice count.
- Preserves distinct history action labels, export recovery, Quick Look ownership and immediate timer placement.
- Resolves the shared shortcut identity collision between Chrome Switch to and Snap & Talk, retaining independent saved preferences.

## Release sequence

Review and test the integrated source, merge through the protected-main checks, then test this signed local Preview. Once accepted, use the existing release helper to sign/notarize/staple the exact source with the Preview's existing Production iCloud provisioning. Verify the final downloaded GitHub archive and checksum before updating the website's matching download link. App Store and Chrome Web Store submissions are separate.

Technical results and remaining limits belong in [the integration verification record](../verification/2026-09-20-contribution-integration.md). GitHub issues/PRs remain the work queue; this checklist is acceptance guidance, not another backlog.
