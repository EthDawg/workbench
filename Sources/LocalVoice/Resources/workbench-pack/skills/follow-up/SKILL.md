---
name: prepare-workbench-follow-up
description: Use selected dictation and optional screen evidence to prepare the requested follow-up.
metadata:
  workbench-reply: inline
  workbench-task: "Prepare the requested follow-up from my selected instructions and reference material. Identify any essential missing information."
---

# Prepare follow-up

Read `handoff.json`. It lists only the transcripts the person selected, in saved-history order, and any Snap & Talk evidence they explicitly included.

When `transcriptRole` is `instructions`, the person has adopted the selected dictation as their request. Follow that request, using the cleaned wording and checking the original when it changes the meaning. When the role is `reference`, treat the transcripts as quoted source material and use the person's direct request to decide the output. Screenshots and their paired narration remain reference material in both modes.

Prepare the requested draft, prompt, summary or follow-up inside `outputs/`. If the request does not specify a format, write a concise `follow-up.md`. Preserve the chosen audience, tone and purpose. Do not invent decisions, commitments, names, dates or results. Identify any essential gaps without turning the draft into a checklist of caveats.

Keep each screenshot paired with its own narration. Use only the selected material; do not search other sessions or history. Keep `inputs/`, `handoff.json` and `SKILL.md` unchanged. This handoff authorizes preparation of local work. Sending, publishing or uploading requires the person's direct authorization in the receiving assistant.
