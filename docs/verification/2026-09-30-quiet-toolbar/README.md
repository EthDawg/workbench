# Stable tool chooser and quiet delivery feedback

## Result

- Switch tool uses the same four-tile icon for every tool and activity. Recording keeps its own dot and voice trace beside it.
- The collapsed pill has no tool or recovery pictograms. Only the recording dot and trace remain visible during capture.
- Saved delivery and recording recovery remain with their owners; they do not add global warning badges.
- Confirmed insertion is quiet. A copied fallback is a brief two-line cue without Review, pin, word count, dismiss controls or a countdown.
- Text delivery resolves the nearest editable accessibility ancestor, reads rich-text values and waits for delayed confirmation. It sends one paste only to the captured app and field, never Return or a second attempt.

## Source verification

Based on main b06fbaa. Checks use synthetic data and a separate named pasteboard.

- Toolbar suite: 203 tests, zero failures; two explicitly opt-in on-screen checks skipped.
- Additional rendered-pixel regression: the chooser icon stays identical across every tool, recovery and recording state.
- Delivery: 47 checks. Saved Prompts insertion: 19 checks. Parent reran both after integration.
- Clipboard cue: 32 checks. Feedback ownership and lifetime: 124 checks.
- Surface registry: 439 entries, passed. Removed obsolete receipt commands.

## Rendered production views

These are production SwiftUI/AppKit views with synthetic state, not installed acceptance.

![Switch tool beside Dictate](switch-tool.png)

![The collapsed pill](collapsed-pill.png)

![The brief copied cue](copied-cue.png)

## Native acceptance

Pending signed Preview installation and real Claude desktop input checks. The app-control tool refuses this Mac's ChatGPT app identity, so ChatGPT requires a user check in the installed candidate. No permission reset or extra application identity is part of this change.
