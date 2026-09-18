---
name: build-snap-and-talk-deck
description: Build a faithful slide deck from a Workbench Snap & Talk session folder containing ordered screenshots and linked narration.
---

# Build a Workbench Snap & Talk deck

Create a 16:9 PowerPoint `.pptx` from the Snap & Talk session in this folder.

## Source of truth

Read `session.json`. Its non-deleted `sections` array owns slide order. Resolve only relative paths inside this session folder; do not follow a path that escapes it.

Use sections whose status is `ready` and whose screenshot and edited-transcript files exist. Report unfinished, failed, or missing sections instead of inventing replacements. Never include anything under `trash/`.

## Deck contract

- Make one slide per included section, in manifest order.
- Fit the complete screenshot on a 16:9 slide without cropping, stretching, rotating, or covering it. Use a quiet neutral background for any letterboxing.
- Put the edited narration in that slide's speaker notes verbatim. Do not add the narration as visible slide text.
- Do not invent titles, summaries, callouts, branding, or conclusions. Add those only when the user separately requests a polished or interpreted version.
- Prefer the edited transcript. The original transcript and audio are recovery evidence; do not re-transcribe audio unless the edited transcript is missing or the user asks.
- Keep the session files unchanged. Write a new `.pptx` beside this folder or to the destination the user names, and do not overwrite an existing deck without permission.

## Verification

Before delivery, verify the presentation is 16:9, the slide count and order match the included sections, every screenshot is fully visible, and each slide's notes match its edited narration. State which sections were skipped and why.

Keep all work local unless the user explicitly authorizes an external upload or service.
