---
name: build-snap-and-talk-deck
description: Build a faithful slide deck from a Workbench Snap & Talk session folder containing ordered screenshots and linked narration.
---

# Build a Workbench Snap & Talk deck

Create a 16:9 PowerPoint `.pptx` from the Snap & Talk session in this folder.

Neutral skill version 1.1.0. These instructions apply to this frozen session copy.

## Source of truth

Read `session.json`. Its non-deleted `sections` array owns slide order. Resolve only relative paths inside this session folder; do not follow a path that escapes it.

Use sections whose status is `ready` and whose screenshot and edited-transcript files exist. If any active section is unfinished, failed, or missing, list it and ask whether to skip it or wait for a correction before building; never invent a replacement. Never include anything under `trash/`. Record the session ID, manifest SHA-256 and included screenshot/edited-narration SHA-256 values before building so the final summary identifies the exact input revision. A changed input needs a new review, not silent adoption.

First confirm this assistant can read the supplied session files and create a downloadable or local `.pptx`. A pasted local path alone does not grant file access. If those capabilities are unavailable, explain what is missing before starting. For an attachment-only host, the user must deliberately supply the complete session and optional template while retaining relative paths; do not claim they have been uploaded or silently use a cloud service. Workbench does not automatically receive the resulting deck.

## Template

Look only for `template.pptx` inside this session folder. Do not search parent or sibling folders or follow symbolic links outside the session. A template elsewhere must first be deliberately copied into this folder by the user; its original stays unchanged.

If a `template.pptx` is found, ask the user whether to build the deck from it before doing anything else. Describe what it is (branded theme, its layout names, whether it already contains slides) so the choice is informed. Proceed based on the answer:

- **Use the template:** Open it as the base presentation (don't recreate its theme from scratch). Pick one existing layout to reuse for every included section, matching the visible-copy rule below:
  - Favor a layout with a title, a body-text area, and room for a large uncropped screenshot (name hints: "Demo Intro", "Weighted Left/Right Photo", "Title and Content", or a comparable text-and-image layout). Put the concise title and supporting bullets in the text area and the screenshot in the picture placeholder or remaining open canvas. A roughly one-third text / two-thirds image composition is a useful default, but preserve the template's own proportions when it supplies them.
  - If no layout provides both readable text and a large image area, use a title-and-image layout and add the smallest text box needed for the supporting copy, styled from the template's own body typography. Do not shrink the screenshot into a thumbnail to make the text fit.
  - If the requested look mixes traits from two layouts (e.g. one layout has the right structure but the wrong background art, and a different layout in the same template carries the desired background), ask the user before compositing them — confirm which structural layout and which background/art asset to pair, then reuse both pieces as-is from the template (swap the background picture only; don't hand-recreate colors or gradients that aren't already an asset somewhere in the file). If no layout or combination fits at all, ask the user which one to use rather than guessing.
  Do not carry over any slides that already exist in the template file — add only the new screenshot slides. Leave every other placeholder (footer, slide number, decorative graphics already baked into the layout) exactly as the template defines it — don't add covers, dividers, or extra branding beyond what one chosen layout (or explicitly approved composite) already provides.
- **Skip the template:** Fall back to the plain deck described below.

If no `template.pptx` is present in this folder, make the plain deck — don't ask the user to find a template.

## Deck contract

- Make one slide per included section, in manifest order.
- Use a clear text-and-image composition: concise presentation copy on the left and the screenshot on the right unless the chosen template clearly places them differently. For a plain deck, reserve roughly 34% of the slide width for text and 66% for the screenshot, with comfortable margins and a quiet neutral background.
- Fit the complete screenshot, without cropping, stretching, rotating, or covering it, in the image area. When the screenshot's aspect ratio doesn't fill that area, letterbox the gap using the template's placeholder/background fill or the plain deck's neutral background.
- Put the edited narration in that slide's speaker notes verbatim, unmodified. Never edit, trim, or clean up the notes text — verbatim means verbatim, filler words ("um", stray phrasing) included.
- Give each slide a large visible title: a short, active phrase that summarizes what that section's edited narration says, sized and styled as a real title. The title must not add facts, claims, numbers, or context the narration doesn't already contain.
- Under the title, turn the edited narration into concise visible slide copy: normally two to five short bullets, or one brief statement when the narration does not naturally form a list. Preserve the meaning and important specifics, but remove filler, repetition, and spoken false starts from this visible copy only. Do not paste a dense transcript onto the slide.
- Treat the visible title and bullets as a faithful presentation summary, not permission to invent strategy, benefits, metrics, branding, subtitles, callouts, or conclusions. When the narration is ambiguous, describe what is shown instead of guessing what it means.
- Prefer the edited transcript. The original transcript and audio are recovery evidence; do not re-transcribe audio unless the edited transcript is missing or the user asks.
- Keep all existing session files unchanged, including `session.json`, screenshots, audio, both transcripts, this skill and `template.pptx`. Open the template read-only; save the deck as a separate file.

## Output

Create `outputs/` inside this session if needed. Verify its resolved path stays inside the session and is not a symbolic link. Save a uniquely named new `.pptx` there, for example `outputs/session-title-20261007-143000-a1b2c3.pptx`; if the name exists, choose another name. Never overwrite an existing file. Put any temporary/rendered verification files in a new unique subfolder of `outputs/`, leaving earlier outputs unchanged. Do not write beside the session or search outside it. A different destination requires a separate explicit user instruction.

Return the exact deck path and, when supported, a direct file link or downloadable attachment. Explain how the user can open/save it; do not claim Workbench imported it. If file creation or verification fails, report the failure and any partial output path honestly.

## Verification

Before delivery, render and inspect the presentation. Verify it is 16:9, the slide count and order match the included sections, every screenshot is fully visible, every slide has a title and readable supporting copy, and each slide's notes match its edited narration verbatim (unedited). Check that visible copy is concise, grounded only in the narration, and does not cover the screenshot. If a template was used, verify no pre-existing template slides survived into the output and that the theme/layout came from the template rather than a recreated look-alike. Compare the original input and template hashes again to confirm they are unchanged. If any check cannot be performed, identify it as unverified instead of claiming success.

Finish with a short human-readable summary: input session ID and revision hashes; included section IDs/order; explicitly skipped sections and reasons; template choice and unchanged hash (or no template); exact output path; verification performed and limitations. List the title and visible copy for each slide so the user can correct drift. This summary is for review, not a new Workbench receipt format.

Keep all work local unless the user explicitly authorizes an external upload or service.
