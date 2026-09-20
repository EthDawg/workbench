# Floating controls: design review

Status: implemented for 2.0.0-preview.1. The [interaction specification](product-spec.md) is authoritative; the [release evidence](preview-2.0.md) distinguishes code checks, native observations and remaining acceptance work. The generated studies remain concepts, not screenshots.

## Agreed direction

The collapsed presentation control contains a phone icon, divider and chevron. Click opens its controls. It has no “Demo” or “Live” label. Hover must not reveal essential actions. The tile can be repositioned so it does not cover the device, persona or software being demonstrated.

Recording is the core utility. Its Stop action and recording state remain visible while audio is being captured. Opening, closing or resizing controls must preserve the recording and the intended paste destination.

## Options shown for review

| Voice control | Benefit | Tradeoff |
| --- | --- | --- |
| A: compact capsule | Small footprint; timer, input level, Stop and disclosure remain available | Icons need clear accessible names and comfortable targets |
| B: labelled strip | Recording and completion actions are easier to discover | Uses more horizontal space |
| C: detailed card | Room for input information and secondary controls | Obscures more of the working app |

The selected pairing is A for regular use and C when explicitly expanded. Ethan authorised implementation using the project goals and the form-factor distinction. Generated boards compare the alternatives, refine the presentation tile, and illustrate snapping and recording states. They are design illustrations, not screenshots of shipped behavior.

The illustrated waveform remains an exploration detail: the current recording implementation uses a segmented input-level meter. See the [concept-to-source example](design-images.md#worked-example-the-waveform-is-a-design-choice) for the reference, current source and evidence limits. Decide whether a different visual improves sound feedback before making it an implementation requirement.

## Interaction details to validate

- Click opens options. Clicking elsewhere closes options without stopping or discarding audio.
- Snap guides appear only while dragging. A Position menu supplies the same destinations for people who do not drag.
- Expansion preserves the chosen edge or corner; changing display geometry brings the control back onscreen.
- Essential actions work with keyboard navigation and VoiceOver, with readable contrast and Reduce Motion support.
- Recording, transcription, optional cleanup and paste readiness have distinct states. Original transcription remains available.
- Model downloads belong in the model manager. Changes must not silently alter an in-flight request; the UI must explain when a new choice takes effect.
- Recording controls must preserve the target application's focus and paste destination.
- Test whole-display and window sharing in Teams and Zoom at the receiver. Workbench cannot assume its controls are hidden from another application's capture.

## Evidence

[Superwhisper's recording-window documentation](https://superwhisper.com/docs/get-started/interface-rec-window) describes mini/full views, mode selection, recording controls and a context menu. Some essential controls appear on hover; Workbench's proposed click behavior deliberately follows Ethan's preference instead.

[Superwhisper's changelog](https://superwhisper.com/changelog) records fixes for multi-monitor snapping, window position drift and focus stealing during mode changes. These inform regression cases; they do not establish that Workbench passes them.

[Apple's popover guidance](https://developer.apple.com/design/human-interface-guidelines/popovers/) recommends small anchored surfaces, one popover at a time, preserving work on dismissal and maintaining context when a view changes size. Native panels and popovers should supply the underlying behavior before introducing custom chrome.
