# Workbench product review: preparation, explanation and handoff

20 September 2026. Supporting research for [the product direction](../commodity-strategy.md), using public first-party sources and repository `f63cf35197221866c0501d6f1ced23c808401d20`. Vendor pages establish advertised behaviour, not hands-on comparison. No competitor was installed, no new model benchmark or hardware/meeting test was run, and no interview or contributor endorsement is implied. No personal image library or private Drive folder was inspected.

## What changed the recommendation

Workbench grew from speech and presentation utilities into one app. Matt's publicly recorded contributions include Snap & Talk and native handoffs; scene, persona and mobile work provides preparation and reuse. See [contribution provenance](../../CONTRIBUTING.md#start-from-the-current-workbench-code). Connecting these pieces can make existing work more useful without enlarging every feature.

The unfinished transition is from showing something to leaving an explanation another person can use. Snap & Talk's images, ordered notes and recipe are a good starting point. A folder path, a generated deck and a recipient accepting that deck are distinct outcomes.

Source review found substantial existing preparation and recovery code, incomplete receiving-meeting/multi-display evidence, and functioning local-model integrations without a completed natural-speech benchmark. Start from those facts. The initial audience hypothesis is repeat software demonstrators. Validate recent behaviour: what they prepared, what changed during the demo, what they sent afterward and what needed clarification. Observing a task is more useful than asking whether AI tags sound attractive.

## Category comparison

Primary pages checked 20 September 2026. The final column is our interpretation, not vendor claims or proof of a Workbench advantage.

| Category/source | Advertised/native baseline | What to borrow and where to stop |
| --- | --- | --- |
| [Apple Screenshot](https://support.apple.com/en-ca/guide/mac-studio/apdbc4019fdf/mac), [Presenter Overlay](https://support.apple.com/en-au/105117) | Screen/window/region capture, thumbnail editing/drag/share; supported Macs offer speaker compositing. | Native capture and webcam presence are strong baselines. Earn extra steps through explanation and delivery; test interaction with meeting controls. |
| [Presentify](https://presentifyapp.com/), [DemoPro](https://www.demoproapp.com/) | Drawing, cursor emphasis, whiteboards and shortcuts. DemoPro offers momentary press-and-hold activation and toggle mode. | Borrow fast mark/clear/return. Test discovery and key conflicts. Additional brushes alone are weak differentiation. |
| [CleanShot](https://cleanshot.com/features) | Capture/annotation, editable projects, reusable backgrounds and an immediate overlay for copy/save/drag. | Connect a small control to the current artifact and next destination. A full editor/cloud gallery/scrolling-capture engine is a separate commitment. |
| [Screen Studio](https://screen.studio/) | Polished video, automatic/editable zoom, cursor treatment, backgrounds, USB phone recording and export options. | Borrow restrained defaults and reuse. Determine whether the recipient needs inspectable images/notes or finished video before considering a timeline editor. |
| [Raycast window management](https://www.raycast.com/core-features/window-management) | Hotkeys, named positions, resizing, display moves and restoration. | Predictable placement helps Workbench-owned controls. General desktop orchestration needs a stronger case. |
| [Canva brand tools](https://www.canva.com/business/features/brand/) | Reusable logos, colours, fonts, imagery, guidelines and templates. | Consume approved ingredients/finished artwork; keep overlays editable. A brand-management system is unnecessary for one reusable scene. |
| [Eagle Skill/MCP](https://en.eagle.cool/blog/post/eagle-plugin-mcp-skill) | Vendor-described agent title/tag updates, folder organisation and selected-image analysis. | Semantic naming and agent access are not novel alone. Test selected evidence plus authored explanation, origin and a specific recomposition task. |

A floating menu matters when it prevents a lost place: start the next action, stop the current one, return to software input, or move the result onward. [#56](https://github.com/EthDawg/workbench/issues/56) and active [PR #62](https://github.com/EthDawg/workbench/pull/62) own this implementation. Test closed/idle/recording states, keyboard recovery, placement and audience visibility before another menu redesign.

## Context should follow the material

Avoid collapsing these distinct concepts:

| Concept | Existing meaning | Safe capture use |
| --- | --- | --- |
| Persona group | Named prepared collection, stable IDs and optional public label. | Snapshot deliberately selected role/approved label. A private preparation name need not be exported. |
| Scene | Backdrop, crop, phone geometry and optional logo/persona layers. | Snapshot identity/name and composition facts when the capture actually uses that scene. |
| Saved-resource group | `DemoResource.product` and `.persona` strings combined for display. | Use only from a selected resource; matching names do not establish persona-group identity. |
| Browser profile | Machine-local targeting/authentication context. | Route explicit destinations; it is not a customer identity or exportable login/session. |
| Personal settings profile | Proposed portable preferences in [#59](https://github.com/EthDawg/workbench/issues/59). | Separate from presentation context; never export endpoints/secrets as metadata. |
| Annotation | Drawing geometry, style, text and time. | Future meaning belongs to a captured item or explicitly selected mark, not a guessed interpretation of strokes. |
| Snap & Talk session | Ordered screenshot/audio/original/edited-text references and status. | Owns recipient sequence and authored explanation. |

Source: [annotations](../../Sources/StageKit/Core.swift), [groups](../../Sources/StageKit/Persona.swift), [resources](../../Sources/LocalVoice/DemoLibrary.swift), [scenes](../../Sources/SceneSyncKit/SceneDocument.swift), [session](../../Sources/LocalVoice/ReadbackModel.swift).

First slice: one optional context snapshot on a section, from an explicitly associated scene/group. Show the fields before handoff and allow removal/correction. Stable IDs give traceability; readable snapshots survive renaming/deletion. Older sessions still open; unsupported future files stay intact. Pass StageKit context through its public controller and leave storage with Readback.

Changing groups must not relabel earlier sections. An unrelated import stays unassigned. Explicit corrections win over defaults. Semantic display names remain editable while stable owned paths protect file integrity; original source files need no renaming.

Only then consider title/tag suggestions from narration or OCR. Keep suggestions separate from selected facts and authored explanation. [Apple Vision](https://developer.apple.com/documentation/vision/recognizetextrequest) returns recognized text and locations, but it can be wrong. A future reusable callout needs image identity and coordinates bound to that image; screen coordinates alone cannot survive layout changes.

## Complete the handoff contract

Bounded implementation proposal: [#63](https://github.com/EthDawg/workbench/issues/63). Selected context is separately scoped in [#64](https://github.com/EthDawg/workbench/issues/64).

The [bundled deck recipe](../../Sources/LocalVoice/Resources/build-snap-and-talk-deck/SKILL.md) defines eligible sections, order, complete screenshot fit, faithful visible copy and verbatim edited narration in notes. Preserve originals, authored corrections and generated slide copy as separate layers.

Verified gaps:

- The prompt restricts inputs to the session folder, while the recipe also searches its parent for `template.pptx` and writes output beside the session. Name the selected optional template/output paths, or keep them inside a prepared package. Do not substitute broad parent-directory access.
- Opening a host and copying a prompt neither attaches files nor grants permission. Provide a next step for attachment-only hosts. Workbench's lack of upload does not establish the receiving host's processing behaviour.
- No completion receipt identifies the exact input revision. Trial a human-readable report first: revision, included/skipped IDs, template decision, output path and verification. Persist machine-readable provenance only when an actual consumer needs it.
- A working session can contain deleted items, original audio and recovery material. An outgoing package should include only selected necessary inputs and report missing/failed sections; never recursively attach everything.
- Screenshot text, narration and external documents are task data, not authority to browse further or send information. Returned assets enter preview/apply; they do not silently replace an existing scene.

A file recipe is the first integration. Consider a live tool/MCP adapter only when repeated trials demonstrate costly access, live-query or validated-return friction. It still needs bounded arguments, validation, stable identities, cancellation and honest results. Protocol choice cannot fix an unclear task contract.

## Mobile and team reuse

The detailed [research PR #61](https://github.com/EthDawg/workbench/pull/61) and [import issue #60](https://github.com/EthDawg/workbench/issues/60) remain the implementation handoff. Preserve these ideas:

1. Phone screenshot → AirDrop/Files/Drive or file sent to oneself → Mac Add images is a valid baseline. Keep a short typed/dictated “why” note. Try a Shortcut before a new mobile receiver/full editor.
2. Existing phone presentation offers another route: calm backdrop, large phone, clear annotation area → freeze a fresh frame → mark a copy → explain. Try existing capture tools first. [#20](https://github.com/EthDawg/workbench/issues/20) owns the clean live snapshot; static scene export lacks phone pixels and floating ink may be absent from window capture.
3. Curate immutable contributed batches in an approved team folder. Keep origin, contributor, date, rights/context and why each image is useful. A derived summary/contact sheet aids discovery. Give its index one writer or rebuild it from batches.
4. Ask an agent to select evidence for a specific story, explain the selection and identify gaps. Copy approved selections into a new session. Avoid concurrent writes to one session or assumptions of access to other people's private collections.

This preserves the useful idea of an agent selecting the best relevant captures and managing names/tree/summary, while making contribution and recomposition testable. Semantic names help humans; stable IDs/source links support corrections. Eagle is an example, not a reason to reproduce its entire library.

Test phone legibility in the final deck. A phone composed inside a scene and then placed in the slide's image area can shrink twice. Start with the raw frame in the existing recipe; a whole-scene slide needs an explicit alternative recipe. Personal CloudKit photo/scene transfer remains distinct from team sharing.

## A useful scene brief without a model call

Conditional experiment: [#65](https://github.com/EthDawg/workbench/issues/65). Try the manual brief before adding the action.

Take dimensions from the chosen output target. Compute clear-space regions from the actual rendered scene at that size; normalized placement values are not automatically generator coordinates. Keep approved logos, labels and personas as separate editable layers.

The first brief contains width/height/aspect, intended use, crop policy, quiet regions for existing overlays/annotations, explicitly supplied palette/mood, reference provenance, exclusions and a result checklist. For fictional input:

> Create background artwork for a 1920 × 1080 software demonstration using the approved navy and teal palette. Keep the phone and logo areas quiet according to the attached layout guide. Leave clear space for drawing. No lettering, logos, device frames or persona artwork. The background must work as a still.

Actual regions come from the selected scene. Show a readable preview and Copy brief. The user can search for an approved image in their browser, use a design tool or choose a generator. Future discovery should use the explicit brief and retain source/rights context; it does not require access to browsing history or customer accounts. Import through existing backdrop preview/cancel/apply. Check actual dimensions, crops, contrast and clear space; a prompt cannot guarantee image dimensions.

Improve prompts with a few versioned examples and accepted/rejected synthetic outputs. Test second-audience reuse before adding inheritance or a prompt-management service.

Apple announced on 11 June 2026 that programmatic `ImageCreator` will not work on OS 27 and later, directing developers to the Image Playground sheet or another service. Do not assume it is an enduring offline engine. [Apple's notice](https://developer.apple.com/news/?id=dz9wvq0r). A portable brief is the smaller initial investment.

## Ecosystem service areas and boundaries

Added 20 September 2026 after the broader ecosystem review. Official documentation establishes feasible routes and API contracts; no Android device, Windows host, Teams/Slack tenant, VPN or managed-device configuration was accessed or tested. Keep this map with the product rationale. Do not turn every row into a feature, sidebar category or integration issue.

| Service area | What Workbench can own | Ecosystem boundary and investment trigger |
| --- | --- | --- |
| Personal input and accessibility | Faithful capture, correction, reading, recoverable originals and understandable native controls. | OS input/accessibility and chosen model providers remain distinct. Invest when measured correction or access friction blocks a real task. |
| Devices and capture | Selected evidence, source identity, composition and capture recovery. | Use external mirroring/remote tools first. Add a source adapter only when repeated capture/composition friction survives that trial. |
| Live presentation and collaboration | Preparation, destination switching and presenter-owned emphasis. | Teams/Zoom/Meet own audience delivery. Prove visibility, audio and recovery before claiming compatibility. |
| Evidence and reuse | Portable explanations, provenance and a reviewed selection. | Existing approved folders/libraries own sharing and access. Add retrieval or contribution automation when a second person repeatedly needs it. |
| Agent instructions and execution | A clear recipe, bounded inputs and a verified return. | The chosen host owns model access. Progress from files to tools only when measured handoff friction justifies it. |
| Managed-workplace compatibility | Truthful prerequisites, data-flow explanation, recoverable errors and supportable installation. | The organisation owns accounts, device/network policy and retention. A real deployment requirement must justify any managed configuration, audit or administration feature. |

Architecture, security, design and delivery cut across these areas. They do not require separate products. Useful emerging opportunities include turning demonstrations into reusable evidence, using selected context to guide agents, and reviewing an agent's result before applying it. Their value is a completed task, not the number of connected services.

### Android and Windows: three separate questions

**Android on a Mac is feasible now through a separate tool.** [scrcpy](https://github.com/Genymobile/scrcpy) documents display/control over USB or TCP/IP on macOS, Windows and Linux, without root or a persistent phone app. Mirroring requires Android 5+ and normally USB debugging; its OTG exception provides input control without mirroring. The [Mac guide](https://github.com/Genymobile/scrcpy/blob/master/doc/macos.md) documents installation and adb prerequisites. Managed devices may prohibit that setup. No installation is part of this review.

First trial: an approved Android device → scrcpy window → native screenshot or meeting share → chosen image into Snap & Talk through #60. Workbench's current AVFoundation device path does not ingest a scrcpy window. Native screenshot capture can supply an image; a composed live source would need a separate, validated adapter. scrcpy's documented virtual-camera route is Linux-only, so do not assume it produces a Mac camera input. [Project capabilities](https://github.com/Genymobile/scrcpy).

Audio is another acceptance path: scrcpy documents Android 11+ forwarding, with version/source restrictions and possible video-only continuation when audio fails. That does not establish meeting audibility or two-way voice-agent operation. [Audio contract](https://github.com/Genymobile/scrcpy/blob/master/doc/audio.md). Start a permitted USB trial before wireless discovery; networking and device policy remain separate constraints. [Connection options](https://github.com/Genymobile/scrcpy/blob/master/doc/connection.md).

**Windows content on a Mac** can use Microsoft's Windows App to reach an authorised remote PC or provisioned Windows service, subject to that destination's prerequisites and network access. Workbench could explain or capture the visible remote window; the remote client owns connection, credentials and redirection. This is a composition to test, not an integrated Workbench remote-desktop feature. [Microsoft Windows App](https://learn.microsoft.com/en-us/windows-app/get-started-connect-devices-desktops-apps).

**Workbench running on Windows** is a separate port with no current implementation commitment. Portable images, notes and decks provide an earlier cross-platform benefit. Microsoft Phone Link is a Windows-host option with device/market requirements; its existence does not establish universal phone mirroring or a Mac route. [Supported Phone Link experiences](https://support.microsoft.com/en-us/windows/apps/phonelink/supported-devices-for-phone-link-experiences). Keep host OS, source device, control, capture and audio as separate capability fields.

### Get more from Teams and the existing Chrome extension

Start with the meeting app's supported primitives. Microsoft documents screen/window sharing, Chrome/Edge web sharing and its own presenter controls. On Mac, the relevant app/browser needs screen-recording access. [Teams presentation guidance](https://support.microsoft.com/en-us/teams/meetings/present-content-in-microsoft-teams-meetings).

| Intended job | First route to verify | What must remain explicit |
| --- | --- | --- |
| Move between browser profiles, native apps and floating overlays | Teams desktop sharing one prepared display. | Anything visible on that display, including Workbench controls, can reach the audience. |
| Present one composed device view | Share the Workbench scene window. | Separate persona/ink/timer windows are not automatically included. |
| Show one browser application | Teams web with the selected tab. | A successful Workbench Switch to does not retarget the shared tab. |
| Show the phone directly | Teams mobile screen sharing/companion route. | Separate from Workbench USB; rehearse audio, echo and interruptions. |

The extension currently focuses a named destination in its paired Chrome profile. It has no Teams meeting API or share-state detector. A fixed window/tab share can keep showing the old source after a successful switch. Verify that interaction from the receiver. Its URL canonicalisation removes queries/fragments: save stable demo destinations and leave meeting invitations/joining with Teams, rather than assuming invitation links retain their meaning. See [presenter ownership](../presenter-direction.md#state-and-security-boundaries), [URL handling](../../Sources/PresenterKit/PresenterProtocol.swift) and [Chrome native messaging](https://developer.chrome.com/docs/extensions/develop/concepts/native-messaging). Browser-native transport is not a Teams connector.

Keep presenter microphone, application playback and phone conversation separate. Microsoft's Mac desktop guidance calls for the Teams audio component; its web documentation describes tab/system sound controls whose actual availability needs testing in the chosen Mac/browser build. No component is installed by this proposal. [Teams sound sharing](https://support.microsoft.com/en-us/teams/meetings/share-sound-from-your-computer-in-microsoft-teams-meetings-or-live-events). Workbench's USB picture remains video-only.

Teams already offers collaborative annotation using Whiteboard and saved snapshots. Prefer that baseline when the audience needs to contribute; Workbench's candidate role is presenter-owned explanation across applications. Check availability and input ownership in the actual client rather than running two ink layers blindly. [Teams annotation](https://support.microsoft.com/en-us/teams/meetings-events/use-annotation-while-sharing-your-screen-in-microsoft-teams).

### Skills, tools and interactive agent interfaces

| Mechanism | Useful job | When it earns its cost |
| --- | --- | --- |
| Portable folder and `SKILL.md` | Tell a chosen agent how to transform selected evidence into a checked artifact. | Now: clear instructions, file access and output contract. A copied skill file is not automatically installed/discovered by every host. |
| Native action, CLI or small adapter | Invoke a repeatable bounded operation with typed input/output. | Reuse existing operations first, such as audio-in/text-out Shortcuts or the browser destination adapter. No model call is inherently required. |
| MCP tools/resources | Query selected live state or request an operation and receive a structured result. | Repeated cases need live freshness, bounded export or a validated result return that the file route cannot handle well. |
| MCP Apps | Show an interactive preview/selection inside a supporting agent host. | Later: only if choosing captured sections or approving returned assets inside the conversation measurably improves the workflow. |

[Agent Skills](https://agentskills.io/home) packages task instructions/resources; [MCP](https://modelcontextprotocol.io/docs/learn/architecture) provides a tool/resource interaction contract. They can complement each other. [MCP Apps](https://modelcontextprotocol.io/extensions/apps/overview) adds interactive host-rendered interfaces; it introduces another UI to support. None supplies credentials, permission, product understanding or successful completion by itself. A connector also does not automatically reduce token use: compare selected input volume, calls, retries and correction effort.

A sensible first tool candidate, if needed, is reading or exporting an explicitly selected session revision, followed later by previewing a returned artifact. Reuse the same validation/state owner as the native UI. Keep arbitrary file access, arbitrary commands, automatic posting and a generic agent platform outside that trial. #63 remains the file-handoff first step.

### Collaboration and enterprise possibilities

Start Slack/Teams delivery with a readable artifact and an existing authorised conversation or approved folder link. [Slack supports normal file sharing](https://slack.com/help/articles/201330736-Add-files-to-Slack), subject to workspace restrictions. The recipient should not need Workbench to understand the output. Do not assume chat delivery grants access to a linked folder.

The stronger stretch cases have concrete triggers: a Teams meeting app when participants repeatedly need a shared interactive artifact inside a meeting; a transcript connector when a selected meeting's discussion must be combined with the explanation; or a Slack adapter when repeated thread selection/delivery receipts create material work. [Teams meeting apps](https://learn.microsoft.com/en-us/microsoftteams/platform/apps-in-teams-meetings/teams-apps-in-meetings), [Graph transcript/recording access](https://learn.microsoft.com/en-us/microsoftteams/platform/graph-api/meeting-transcripts/overview-transcripts) and [Slack file APIs](https://docs.slack.dev/messaging/working-with-files/) add app permissions, organisational rules and ongoing maintenance. Wrapping an API in MCP does not remove them. Prefer the user's existing approved connector where it already completes the task.

VPN compatibility is a property of a tested route, not a universal toggle. Workbench's current Chrome bridge uses local native messaging/a Unix socket; tenant pages, remote desktops, meeting media, wireless devices and model downloads have different network dependencies. Record the approved configuration and failure without collecting credentials or altering routes. Microsoft's [VPN guidance](https://learn.microsoft.com/en-us/microsoft-365/enterprise/microsoft-365-vpn-split-tunnel?view=o365-worldwide) is an administrator concern. Managed extension, recording, USB and installation policies can independently constrain a demo.

An enterprise opportunity could be repeatable team preparation and evidence reuse with controlled export. Managed deployment, audit/retention, redaction and identity integration stay conditional on a real customer's requirements. First publish an honest supported-route description and a portable result; avoid adding a service platform to make the project look enterprise-ready.

### Two ecosystem experiments, using the existing queue

Use [receiver issue #29](https://github.com/EthDawg/workbench/issues/29) for the first chosen route; its original one-meeting-app scope stays small. Optional follow-on rows compare Teams desktop display/scene-window sharing with Teams web tab sharing. Switch between two prepared Chrome profiles, mark/clear, show one phone picture and play a test sound. Record exactly what the recipient sees/hears, wrong-source incidents, readability and stop/restart recovery. Android/scrcpy is another optional hardware row, not a dependency for finishing the iPhone route. Leave untried rows explicitly deferred rather than expanding the issue's closure gate.

Extend the #63 handoff trial: use a synthetic explanation and a chosen recipient/destination, with a human explicitly handling delivery. Can they open the output, associate notes/images and answer the intended question without installing Workbench? Measure missing context and delivery effort before proposing a bot or connector. No test message, tenant access, driver install or policy change is authorised by this document. Create an implementation issue only after one of these trials identifies a concrete missing step.

## Local models: working integrations, incomplete quality evidence

| Job | Implementation at reviewed source | Evidence boundary |
| --- | --- | --- |
| Mac recognition | Parakeet TDT v2 through FluidAudio 0.15.6; optional loopback transcription server. | Recorded round trips and synthetic whisper.cpp compatibility trial; no completed natural-speech comparison for a new default. |
| Mobile recognition | Apple SpeechAnalyzer/SpeechTranscriber and asset/readiness handling. | Source/isolated checks; physical acceptance separate. It does not inherit Mac model settings. |
| Refinement | Original, deterministic Light, optional Natural through Apple Foundation Models or local Ollama. | Recorded eight-case synthetic run accepted five edits and fell back on three; not a quality benchmark. |
| Reading | Mac system voices, mobile AVSpeechSynthesizer, optional online Speko on Mac. | Local generation/playback evidence; transport fixtures do not prove live remote synthesis. |
| Vision/generation | No integrated semantic screenshot or image-generation engine found. | Image capture/composition is not semantic understanding. |

See [providers](../model-providers.md), [cleanup](../../Sources/LocalVoice/Cleanup.swift), [local refinement](../../Sources/LocalVoice/LocalRefinement.swift), [mobile speech](../../Mobile/Workbench/SpeechService.swift) and [dated evidence](../preview-2.0.md). [Apple's system language model](https://developer.apple.com/documentation/foundationmodels/systemlanguagemodel) requires availability checks; record OS/runtime context when evaluating it.

Natural guards factual-token order, numbers and negations and can fall back to Light; a passed guard does not prove meaning equivalence. Snap & Talk currently bypasses refinement and writes the recognition result as both original and initial edited narration. Evaluate recognition, refinement and correction separately. Saved literal replacements are not acoustic personalisation: Apple's [contextual strings](https://developer.apple.com/documentation/speech/analysiscontext/contextualstrings) concern DictationTranscriber, while this mobile app uses SpeechTranscriber.

The [14 September voice review](voice-category-2026-09.md) predates capture recovery. The [15 September verification](../verification/2026-09-15-recent-journeys.md) and current `CaptureRecovery.swift` supersede that proposed fix.

## Experiments and stop rules

Proposed tests, not results. Use synthetic public examples. Record versions, hardware, input fixture, observations and gaps in the existing verification area; no production analytics or private-history collection is required.

| Trial | Procedure/output | Proposed gate |
| --- | --- | --- |
| Real receiver | Three-minute demo in one meeting app: persona, destination, mark/clear, phone, interruption/reopen, finish. Observe whole-display and window sharing separately on a second device. Save a verified walkthrough. | Repeat the supported route twice without losing input focus or essential content. Receiver identifies two intended takeaways. Repair before extending the host/display matrix. |
| Useful handoff | Compare five screenshots plus notes, Snap & Talk and an ordinary recording for the same explanation. Independently brief the recipient; an AI-only evaluation is a proxy. Include reorder/correction and a missing section. | Correct order/selection, readable complete images, faithful notes, originals intact, explicit access. Record author/recipient minutes, clarifications, retries and corrections. If a simpler method is equally useful and easier, narrow the proposition or fix delivery first. |
| Context continuity | Three captures under two explicitly selected contexts, an unrelated import, rename/delete a source, reopen an old session. | No incorrect association; earlier snapshots remain useful; import stays unassigned; only chosen labels export. Reduce fields if review takes more effort than it saves. |
| Reusable environment | Adapt one synthetic scene to a second fictional audience later. Compare duplication/manual brief against a parameterised brief on three layouts. Include missing asset and final-size inspection. | Record first/repeat preparation time, accepted outputs, attempts/corrections/spend. Defer a new control if manual reuse is easy; fix composition before generation if legibility fails. |
| Useful local inference | Follow [#24](https://github.com/EthDawg/workbench/issues/24) with 15–30 licensed/consented natural-speech samples, held-out cases, names/numbers/negation/noise/silence. Compare available engines and Original/Light/Natural on identical inputs. | Report correction time and critical errors beside latency/setup/resource costs. Any introduced critical meaning error blocks a default change. Compatibility or best-case speed is insufficient. |

For inference, record input volume, provider/model/prompt version, calls/retries and tokens if exposed; otherwise say unavailable. Set a small explicit run limit before generation. Measure cost per accepted result, with time and money separately. Refresh claims when providers change.

## Queue reconciliation and contribution health

This is a dated reconciliation, not a parallel backlog. Recheck live issues/PRs before starting. Existing owners keep their work; this document closes or merges nothing.

| Existing work | Treatment |
| --- | --- |
| [#56](https://github.com/EthDawg/workbench/issues/56), [#57](https://github.com/EthDawg/workbench/issues/57), [#58](https://github.com/EthDawg/workbench/issues/58), [PR #62](https://github.com/EthDawg/workbench/pull/62) | Finish active usability and validate; avoid a competing redesign. |
| [#29](https://github.com/EthDawg/workbench/issues/29), [#31](https://github.com/EthDawg/workbench/issues/31), [#7](https://github.com/EthDawg/workbench/issues/7), [#2](https://github.com/EthDawg/workbench/issues/2) | Acceptance/newcomer tasks, not missing feature implementations. Useful non-coding contributions. |
| [#60](https://github.com/EthDawg/workbench/issues/60), [PR #61](https://github.com/EthDawg/workbench/pull/61), [#20](https://github.com/EthDawg/workbench/issues/20) | Core handoff sequence, retaining mobile/team/scene nuance. |
| [#24](https://github.com/EthDawg/workbench/issues/24), [#25](https://github.com/EthDawg/workbench/issues/25), [#14](https://github.com/EthDawg/workbench/issues/14), [#15](https://github.com/EthDawg/workbench/issues/15) | Model evidence, safe storage, insertion and first success support everyday voice. Prioritise observed failures. |
| [#17](https://github.com/EthDawg/workbench/issues/17), [#10](https://github.com/EthDawg/workbench/issues/10), [#21](https://github.com/EthDawg/workbench/issues/21) | Selected-text Services, typed audio-in/text-out Shortcuts and timer placement exist. Reconcile native acceptance rather than rebuilding old proposals. |
| [#28](https://github.com/EthDawg/workbench/issues/28), [#59](https://github.com/EthDawg/workbench/issues/59), [#26](https://github.com/EthDawg/workbench/issues/26) | Keep scene defaults, settings and private paired sync distinct; validate simpler reuse first. |
| [#19](https://github.com/EthDawg/workbench/issues/19), [#27](https://github.com/EthDawg/workbench/issues/27), [#37](https://github.com/EthDawg/workbench/issues/37), [#38](https://github.com/EthDawg/workbench/issues/38), [PR #55](https://github.com/EthDawg/workbench/pull/55) | Retain focused proposals/active browser work; expand when a demonstrated bottleneck justifies it. |

The project already has a license, contributor/conduct/security guidance, issue forms, checks and preview records. Improve their connection to jobs rather than adding governance machinery. GitHub's [maintainer guidance](https://opensource.guide/best-practices/) and [project-start guidance](https://opensource.guide/starting-a-project/) support explicit scope, public decisions and accessible contribution paths.

A useful breadcrumb is **job → evidence/workaround → smallest change → input/output and owner → acceptance/limits → why broader work waits**. The issue holds the decision, the owning contract holds implemented behaviour, and dated records hold actual observations. A newcomer should reproduce a baseline and understand “done” without private conversations.

At the two-week review, inspect outcome artifacts, reuse without coaching, correction/support effort and failed assumptions. Continue demonstrated improvements; revise or stop ideas that did not save effort. PR count, generated code and consumed tokens measure activity, not product outcomes.
