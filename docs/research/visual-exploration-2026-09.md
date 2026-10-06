# Visual exploration history

> **Historical research — 20 September 2026.** Excerpt recovered from `docs/design-images.md` at `a305d4edaa4a9c5ca2b4a19234081109e69878a1` in [closed, unmerged PR #66](https://github.com/Ship-Work/workbench/pull/66). Original analysis is retained; relative links were rebased for this location. Claims about current capabilities and proposed work are historical. Consult [current decisions](creation-handoff-2026-10.md) and [research index](README.md); this does not resume paused platforms.

## Reuse the work before generating again

Added 20 September 2026. This is the existing home for visual exploration, prompts and decisions. Image generation is useful for trying different design languages, control hierarchies, experience states and handoffs, and for producing original backdrop/persona artwork or explanatory collateral. A concept can be valuable even when the implementation deliberately differs.

Start with a relevant existing asset and its critique below. These are useful entry points, not an exhaustive asset register:

| Question or output | Existing material to reuse | Where behaviour is decided |
| --- | --- | --- |
| Compact controls, expansion and placement | [Voice alternatives](../../site/assets/guide/voice-experiments.png), [placement study](../../site/assets/guide/voice-placement-study.png), [refined jobs](../../site/assets/guide/jobs-refined.png) | [Floating-control decisions](../hud-design.md), [interaction contract](../product-spec.md) |
| Mobile capture and a recognisable Mac handoff | [Photo handoff B](../../site/assets/guide/photo-handoff-concept-b.png), [scene preparation](../../site/assets/guide/scene-preparation-concept-a.png) | [Photo handoff](../photo-handoff.md), [mobile contract](../ios-preview.md) |
| A coherent scene with editable persona controls | [Persona study](../../site/assets/guide/persona-controls-concept-b.png), [reusable persona artwork](../../Resources/PersonaPortraits) | [Persona contract](../personas.md), [scene decisions](../research/personal-scenes.md) |
| Backgrounds and finished artwork | [Scene backdrops](../../Resources/SceneBackdrops), [ambient assets and prompts](../../Resources/AmbientScenes/prompts.md) | [Background management](../background-management.md), [Mac experience contract](../../site/handbook/contract.json) |
| Product explanation and contribution collateral | [Refined feature study](../../site/assets/guide/commodity-features-refined.png), [architecture study](../../site/assets/guide/commodity-architecture-refined.png) | [Product direction](../commodity-strategy.md), [guide and publishing route](../../site/README.md) |

Use generation actively when seeing alternatives would resolve a decision. For example, compare two or three treatments of the same idle → recording → completion flow, using the existing selected study as a visual reference. Keep the job, wording and native constraints stable so the comparison is useful. Record the selected idea and rejected details beside the prompt; make another round when a meaningful question remains. Improving a label or matching an implemented control may only need a normal code or document edit.

For background or collateral work, reuse the original artwork and generation brief. State dimensions, crop, palette, negative space for the device/annotation, and required variants. Keep product labels, logos, sizes and interactive controls editable in their existing owners rather than baking them into a background. Check actual transparency where required. The [background-brief proposal](https://github.com/EthDawg/workbench/issues/65) should start from this material.

The [tenant-branding finisher review](../research/tenant-branding-editor.md) adds the last mile: place an existing image into a specific SaaS slot, adjust framing/padding and export semantic filenames. It includes a generated editor concept, its [exact prompt](../research/tenant-branding/finisher-concept-prompt.md), official destination specifications and explicit corrections to the illustration. Reuse that decision before generating another general-purpose editor concept.

### Worked example: the waveform is a design choice

![Generated recording alternatives with waveform shapes; exploration, not app evidence](../../site/assets/guide/voice-experiments.png)

The generated study above explores compact, labelled and expanded controls with waveform shapes. The agreed pairing in [the control review](../hud-design.md) is compact plus explicitly expanded. That borrows the hierarchy and footprint; it does not make every generated detail a requirement.

At source `f63cf35197221866c0501d6f1ced23c808401d20`, [CaptureLevelMeter](../../Sources/LocalVoice/CapturePanel.swift) renders eight equal-size segments whose fill follows the current input level. It has no waveform history. The interaction contract requires input-level feedback, so this is a design difference to evaluate, not an established broken waveform requirement. The usefulness question is whether someone can tell that sound is being received without losing sight of Stop or the task beneath the controls.

![Native recording-panel preview labelled Panel preview and Microphone off](../../site/assets/guide/recording-expanded-actual.png)

This existing native image is a **panel preview with the microphone off**. It helps compare layout but cannot demonstrate live meter response, microphone permission or preserved paste focus. The guide already records that distinction. A future waveform experiment should compare silence/speech feedback and compact/expanded legibility, preserve Stop/focus and respect Reduce Motion. Capture its actual state and source revision before using it as evidence.

### Carry the decision into implementation and collateral

In the existing issue or PR, link the selected image, name the details to keep, explain material differences from it, and point to the behaviour owner and acceptance check. This can be a short paragraph. Do not silently overwrite the concept when code changes; keep the reasoning and add a matching native capture when available. An incidental generated label or animation is not a requirement unless adopted explicitly.

Use actual UI evidence for instructions and claims about the current release. Put a visible concept label beside exploratory illustrations wherever they are reused. A native capture still needs its state, build/revision and evidence limits: a preview fixture or Simulator image is not a live device/receiver test. Finished artwork can be reused as artwork without pretending it is app evidence. Preserve the original and any relevant provenance or usage restrictions; do not infer rights from an image being present in a folder.

Claude and Codex can help compare alternatives, critique a design, draft a prompt or implement a bounded choice. Reuse the same linked decision and relevant approved material so the next assistant does not reconstruct the project from screenshots. State the useful output and allowed scope; the submitting contributor still checks the result against source and observed behaviour. Share confidential material only within its authorised recipient/tool and purpose; use a synthetic example or a selected public excerpt when sufficient. Keep credentials, unrelated private context and raw private transcripts out of public issues and assets. This is part of the existing [contributor responsibility](../../CONTRIBUTING.md#send-your-change), not another handoff system.
