---
name: build-snap-and-talk-deck
description: Build a faithful slide deck from a Workbench Snap & Talk session folder containing ordered screenshots and linked narration.
---

# Build a Workbench Snap & Talk deck

Create a 16:9 PowerPoint `.pptx` from the Snap & Talk session in this folder.

## Source of truth

Read `session.json`. Its non-deleted `sections` array owns slide order. Resolve only relative paths inside this session folder; do not follow a path that escapes it.

Use sections whose status is `ready` and whose screenshot and edited-transcript files exist. Report unfinished, failed, or missing sections instead of inventing replacements. Never include anything under `trash/`.

## Template

Look for a file named `template.pptx` in two places, in this order: inside this session folder, then in the parent folder that contains this session folder (a shared template is often kept alongside session folders rather than bundled into each one). Stop at the first one found; do not search further up or elsewhere.

If a `template.pptx` is found, ask the user whether to build the deck from it before doing anything else. Describe what it is (branded theme, its layout names, whether it already contains slides) so the choice is informed. Proceed based on the answer:

- **Use the template:** Open it as the base presentation (don't recreate its theme from scratch). Pick one existing layout to reuse for every included section, matching the visible-copy rule below:
  - Favor a layout with a title, a body-text area, and room for a large uncropped screenshot (name hints: "Demo Intro", "Weighted Left/Right Photo", "Title and Content", or a comparable text-and-image layout). Put the concise title and supporting bullets in the text area and the screenshot in the picture placeholder or remaining open canvas. A roughly one-third text / two-thirds image composition is a useful default, but preserve the template's own proportions when it supplies them.
  - If no layout provides both readable text and a large image area, use a title-and-image layout and add the smallest text box needed for the supporting copy, styled from the template's own body typography. Do not shrink the screenshot into a thumbnail to make the text fit.
  - If the requested look mixes traits from two layouts (e.g. one layout has the right structure but the wrong background art, and a different layout in the same template carries the desired background), ask the user before compositing them — confirm which structural layout and which background/art asset to pair, then reuse both pieces as-is from the template (swap the background picture only; don't hand-recreate colors or gradients that aren't already an asset somewhere in the file). If no layout or combination fits at all, ask the user which one to use rather than guessing.
  Do not carry over any slides that already exist in the template file — add only the new screenshot slides. Leave every other placeholder (footer, slide number, decorative graphics already baked into the layout) exactly as the template defines it — don't add covers, dividers, or extra branding beyond what one chosen layout (or explicitly approved composite) already provides.
- **Skip the template:** Fall back to the plain deck described below.

If no `template.pptx` is found in either location, skip straight to the plain deck — don't ask.

## Deck contract

- Make one slide per included section, in manifest order.
- Use a clear text-and-image composition: concise presentation copy on the left and the screenshot on the right unless the chosen template clearly places them differently. For a plain deck, reserve roughly 34% of the slide width for text and 66% for the screenshot, with comfortable margins and a quiet neutral background.
- Fit the complete screenshot, without cropping, stretching, rotating, or covering it, in the image area. When the screenshot's aspect ratio doesn't fill that area, letterbox the gap using the template's placeholder/background fill or the plain deck's neutral background.
- Put the edited narration in that slide's speaker notes verbatim, unmodified. Never edit, trim, or clean up the notes text — verbatim means verbatim, filler words ("um", stray phrasing) included.
- Give each slide a large visible title: a short, active phrase that summarizes what that section's edited narration says, sized and styled as a real title. The title must not add facts, claims, numbers, or context the narration doesn't already contain.
- Under the title, turn the edited narration into concise visible slide copy: normally two to five short bullets, or one brief statement when the narration does not naturally form a list. Preserve the meaning and important specifics, but remove filler, repetition, and spoken false starts from this visible copy only. Do not paste a dense transcript onto the slide.
- Treat the visible title and bullets as a faithful presentation summary, not permission to invent strategy, benefits, metrics, branding, subtitles, callouts, or conclusions. When the narration is ambiguous, describe what is shown instead of guessing what it means.
- Prefer the edited transcript. The original transcript and audio are recovery evidence; do not re-transcribe audio unless the edited transcript is missing or the user asks.
- Keep the session files unchanged. Keep `template.pptx` unchanged (open it read-only; save the deck as a separate file). Write a new `.pptx` beside this folder or to the destination the user names, and do not overwrite an existing deck without permission.

## Verification

Before delivery, verify the presentation is 16:9, the slide count and order match the included sections, every screenshot is fully visible, every slide has a title and readable supporting copy, and each slide's notes match its edited narration verbatim (unedited). Check that visible copy is concise, grounded only in the narration, and does not cover the screenshot. If a template was used, verify no pre-existing template slides survived into the output and that the theme/layout came from the template rather than a recreated look-alike. State which sections were skipped and why, whether a template was used, and list the title and visible copy you gave each slide so the user can correct any drift.

Keep all work local unless the user explicitly authorizes an external upload or service.
