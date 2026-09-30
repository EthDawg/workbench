# Stable tool chooser and quiet delivery feedback

## Result

- Switch tool uses the same four-tile icon for every tool and activity. Recording keeps its own dot and voice trace beside it.
- The collapsed pill has no tool or recovery pictograms. Only the recording dot and trace remain visible during capture.
- Saved delivery and recording recovery remain with their owners; they do not add global warning badges.
- Confirmed insertion is quiet. A copied fallback is a brief two-line cue without Review, pin, word count, dismiss controls or a countdown.
- Text delivery resolves the nearest editable accessibility ancestor, reads rich-text values and waits for delayed confirmation. It sends one paste only to the captured app and field, never Return or a second attempt.

## Source verification

Based on main b06fbaa. Checks use synthetic data and a separate named pasteboard.

- Full Swift suite: 328 tests, zero failures; two explicitly opt-in on-screen checks skipped.
- Rendered-pixel regression: the chooser icon stays identical across every tool, recovery and recording state.
- Delivery: 47 checks. Saved Prompts insertion: 19 checks. Parent reran both after integration.
- Clipboard cue: 32 checks. Feedback ownership and lifetime: 124 checks.
- Surface registry: 439 entries, passed. Removed obsolete receipt commands.
- Native surface gallery: 280 renders, 140 entries, zero flags. Toolbar gallery: 344 production-view fixtures.
- Capture persistence: 154 checks, including saved audio preservation and no popup revival after confirmed insertion.
- Corrected toolbar-host gallery: 54 renders, zero flags. It covers Copy during a meeting, a meeting starting while a copied cue is visible, and a stationary pointer holding the cue.
- StageKit: 253 tests and 4,903 assertions, zero failures after quitting both app editions to free their global shortcuts. The remaining full-suite checks also passed: transcript handoff, readback pack, capture preview, image workspace, history, handoff jobs, subscription CLI, meeting removal and capture, and Snap.

## Rendered production views

These are production SwiftUI/AppKit views with synthetic state, not installed acceptance.

![Switch tool beside Dictate](switch-tool.png)

![The collapsed pill](collapsed-pill.png)

![The brief copied cue](copied-cue.png)

## Native acceptance

Signed Preview installed in place and verified through the running app's **Copy build details**:

- Version: 2.3.1 (20260930082642)
- Source: 62f8ba5b9f41de7549d0877719baa89a402fdb34
- Local development; modified source: no
- macOS: 26.5.1 (25F80)

The existing Preview identity, saved data and Stable installation were preserved. Both editions were closed for shortcut-sensitive tests; only Preview was reopened afterward.

Desktop delivery acceptance is **pending a user keyboard check**. The app-control tool's Option-V attempt in Claude entered the normal Option-V characters without starting Workbench capture. Those two unsent test characters were removed and the empty composer was verified. This attempt does not establish a native delivery result. The tool also refuses this Mac's ChatGPT app identity. Neither limitation was bypassed with another automation mechanism.

Requested check on this exact candidate: use Option-V to dictate a short sentence twice into an empty Claude desktop composer and an empty ChatGPT desktop composer. Each sentence should appear once, without the old Copied/Review popup or submission. Source checks for selection replacement and a changed target passed, but the corresponding real-app journeys remain unverified.

The control tool cannot establish native hover timing. Production-host pointer tests and rendered views are recorded separately above. No permission reset or extra application identity is part of this change.

## Repeatable scenarios for the experience study

1. Change between every tool, then start recording: Switch tool keeps the same icon; recording has a separate signal.
2. Leave saved recovery unresolved, collapse, reveal, then record: no warning pictogram appears, and saved audio remains available.
3. Copy an existing transcript: the brief cue has only its title and useful next step. After expiry, hover reveals tools.
4. Start a synthetic meeting, then Copy: the recording signal remains visible and Stop transcribing remains reachable. Also check the reverse order, Copy then start a meeting.
5. Keep the pointer stationary where a cue appears: its passive native sensor holds the remaining time. Moving away releases the hold; VoiceOver focus independently keeps it readable.
6. In an empty Claude or ChatGPT desktop composer, dictate a short sentence, repeat, replace selected text, then switch apps during a capture. Text is inserted once into the unchanged original target; a changed target gets a clear fallback, with no submission.

The toolbar-host cases use actual production views, synthetic meeting capture and a synthetic pointer location. They do not establish microphone or desktop-app delivery acceptance. The original full-suite run encountered occupied global shortcuts; after closing Stable, the StageKit rerun passed 253 tests and 4,903 assertions.
