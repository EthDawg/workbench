# Production bug reporting: evidence and decision

Checked 6 October 2026. The [build brief](../bug-reporting.md) owns the decided behavior, protocol, implementation order and acceptance. This research record explains why. Neither document establishes a working upload or provider acceptance.

## Goal and decisions

The audience is ordinary production users who may barely know Workbench. Success is a useful private report arriving in a developer's queue after one Send action, with minimal interruption. No accounts, file management, technical ticket writing or model setup. Screenshot, short voice note and exact build/context are Workbench's useful contribution.

The initial export-first proposal was rejected because it left delivery to the user. Export remains recovery. The next proposal to embed a managed SDK was narrowed after reading actual SDK source: its submission callbacks do not prove durable receipt. The final choice is **native URLSession → durable receipt gateway → Sentry private feedback inbox**, with GitHub retaining engineering work and no custom dashboard. Automatic delivery is baseline, not a future enhancement.

| Alternative | Decision and reconsideration |
| --- | --- |
| Screenshot + public GitHub form | Keep external fallback instructions, not default submission. Reconsider only for explicitly technical contributors with knowingly public evidence. |
| Full Snap & Talk session / bug-report recipe | Too much preparation for one failure. Revisit for multi-step/temporal issues after still images and short voice notes prove insufficient. |
| Direct Sentry Cocoa feedback SDK | Rejected for this delivery contract: no public per-report receipt, cache eviction/drop behavior and internal event identity. Reconsider if a supported API establishes attachment-complete durable receipt and restart-safe identity. |
| Native composer + Sentry inbox via gateway | Selected. Provider owns triage; the small gateway owns our stronger durability/idempotency promise. Account-specific receiver proof remains required. |
| Fully custom private GitHub intake / support dashboard | Not first choice. It adds attachment storage/viewing and queue operations; reconsider if Sentry fails the live modern-feedback/attachment gate or budget/access requirements. |
| Always-on replay / automatic AI diagnosis | Outside this slice. Neither is needed to receive a useful report; revisit only from demonstrated missing evidence, with a separate collection decision. |

## Repository evidence

Implementation planning baseline: `c989f9016a53d71fe6c25f41e74958e3f4118bcb`, freshly fetched main in an isolated worktree. Live GitHub metadata identifies **Ship-Work/workbench**, public, issues enabled. No reporting-backend path was found in the inspected main tree; website docs explicitly describe static distribution with no stored feedback. Do not reuse `site/.env.local`, private-pack credentials or the website deployment procedure for intake.

Source inspected:

- `WorkbenchBuild` (`Sources/LocalVoice/WorkbenchUpdates.swift`) already records actual edition/version/build/source/dirty status and OS. Use it rather than the website's latest version.
- `Sources/LocalVoice/main.swift` has Help → Workbench Guide, host-level microphone/screenshot admission and quit/update coordination. `AppModel.report(_:on:from:)` owns typed attention routing. Reporting needs its own support action; no dedicated native report composer was established.
- `SnapCaptureHost.begin` and its host callback hide Workbench and floating controls. Reuse acquisition, not normal capture visibility policy, when reporting Workbench itself.
- `ReadbackModel.startNarration` is tied to an existing screenshot section and session. It is not an independent ready-made report recorder. `RecognitionEngine` has Parakeet and local-server selection; no new speech backend is needed, because a WAV voice note can be sent without transcription.
- Current `site/privacy.html` includes an explicit no-developer-server promise. Voluntary uploads require an accurate public-policy change before activation, not an invisible SDK addition.
- Current main retains macOS 14 deployment in `Package.swift`. Read retirement does not retire `Readback`/Snap & Talk; mobile/browser work remains paused.

Adjacent ownership at inspection: [#291](https://github.com/Ship-Work/workbench/pull/291) covers manual-first assistant handoff, [#285](https://github.com/Ship-Work/workbench/pull/285) Present, [#282](https://github.com/Ship-Work/workbench/issues/282) complete-journey contribution acceptance, and [#7](https://github.com/Ship-Work/workbench/issues/7) release quality. Reporting does not depend on connecting an assistant or changing Present. Refresh exact main/PR status when implementation begins.

## Primary-source findings

Dates below are checks on 6 October 2026 unless separately noted. API/source evidence has high confidence; deployed plan behavior and actual Mac/device acceptance remain unverified. Vendor examples establish possibility, not a working Workbench feature.

### Managed receiver: Sentry

Live latest stable Cocoa release inspected: **9.30.0**, released 30 September 2026, commit `b539e098293067be54fa5cf1f11d9e16cdbba94a`. The parent checked public API, callback ordering and HTTP-response deletion against downloaded source, independently of the research worker's conclusion. [Release](https://github.com/getsentry/sentry-cocoa/releases/tag/9.30.0).

- [`capture(feedback:)`](https://github.com/getsentry/sentry-cocoa/blob/b539e098293067be54fa5cf1f11d9e16cdbba94a/Sources/Swift/Helper/SentrySDK.swift#L539) returns Void; feedback [`eventId`](https://github.com/getsentry/sentry-cocoa/blob/b539e098293067be54fa5cf1f11d9e16cdbba94a/Sources/Swift/Integrations/UserFeedback/SentryFeedback.swift#L23) is private SPI. Public flush is not a report-specific receiver receipt. The managed form is iOS-guarded, not a native Mac interface.
- [`onSubmitSuccess`](https://github.com/getsentry/sentry-cocoa/blob/b539e098293067be54fa5cf1f11d9e16cdbba94a/Sources/Swift/Integrations/UserFeedback/SentryUserFeedbackFormController.swift#L216) runs after form validation and before the capture call. It cannot justify “Received”.
- [HTTP transport](https://github.com/getsentry/sentry-cocoa/blob/b539e098293067be54fa5cf1f11d9e16cdbba94a/Sources/Sentry/SentryHttpTransport.m#L399) retains a nil-response envelope but removes it on HTTP 2xx/4xx/5xx. Attachment construction may omit unreadable/oversized files; cache capacity is finite. A telemetry SDK's transport contract is different from a durable support outbox.
- The [feedback protocol](https://develop.sentry.dev/sdk/telemetry/feedbacks/) inspected is stable 1.5.0, dated 15 September 2026; its local-validation subsection is marked draft. A caller-generated event UUID binds feedback and envelope. Attachments must be in the same envelope. `associated_event_id` is optional correlation with a separate error. Preserve original bytes; attachment-only repair is not the solution to partial ingestion.
- That protocol limits the message to 4,096 scalar values and feedback context normalization to 8,192 bytes. The Workbench brief chooses a smaller 2,048-scalar/4,096-byte explanation plus a serialized-context check. No silent trimming.
- Readback exists through [event details](https://docs.sentry.io/api/events/retrieve-an-event-for-a-project/), [attachment listing](https://docs.sentry.io/api/events/list-an-events-attachments/) and [attachment download](https://docs.sentry.io/api/events/retrieve-an-event-attachment/). Server-only `project:read`, `event:read` for private issue inspection, and the attachment feature are needed. The account trial must prove they cover modern feedback, every attachment and private issue visibility. A list contains metadata, not proof that downloaded bytes match; the brief requires hashing downloads.
- The [legacy feedback list](https://docs.sentry.io/api/projects/list-a-projects-user-feedback/) excludes modern feedback. Use the issue APIs/category filter. No exactly-once or durable repeated-event-ID guarantee was established in the [transport specification](https://develop.sentry.dev/sdk/foundations/transport/offline-caching/). Stable IDs alone cannot replace gateway reconciliation.
- [Attachment documentation](https://docs.sentry.io/platforms/apple/guides/macos/enriching-events/attachments/) identifies permission, quota and plan-dependent retention limits. WAV can be downloaded for local listening; in-inbox audio playback and an integrated customer reply workflow were not established. Do not promise either. Use ordinary support replies when the person provides contact.

Deletion is an additional receiver constraint: [permissions](https://docs.sentry.io/api/permissions/) allow event deletion only through deleting the whole issue; [issue removal](https://docs.sentry.io/api/events/remove-an-issue/) requires `event:admin` and is asynchronous. The contract requires isolated report issues, separate deletion credentials, link-only duplicate handling and verified removal. A review also tightened delete/upload races, expired-token behavior, contact placement and immutable-report corrections.

### Mac platform

[Apple's feedback guidance](https://developer.apple.com/feedback-assistant/) supports timely context and visual evidence, not copying sysdiagnose into this app. [SCScreenshotManager](https://developer.apple.com/documentation/screencapturekit/scscreenshotmanager) headers in local Xcode 26.6 show filtered capture at macOS 14, rectangle capture at 15.2 and newer screenshot configuration at 26. The existing baseline suffices. The [system sharing picker](https://developer.apple.com/documentation/ScreenCaptureKit/SCContentSharingPicker) is preferred to a custom sharing picker; it does not establish TCC bypass or self-capture correctness.

[SpeechAnalyzer](https://developer.apple.com/videos/play/wwdc2025/277/) is a future adapter candidate, not a report prerequisite. [URLSession](https://developer.apple.com/documentation/foundation/urlsession) supports uploads, but real quit/relaunch/permission behavior must be tested; do not promise transfer while the Mac is off. [Apple's 27.0.1 entry](https://developer.apple.com/news/releases/?id=09282026c) is dated 28 September 2026; the research Mac runs 26.5.1 with Xcode 26.6. Released-27 behavior was not tested. Published roadmap/beta declarations are not deployment evidence.

### Durable intake and operations

[Durable Object alarms](https://developers.cloudflare.com/durable-objects/api/alarms/) provide at-least-once execution with limited retries, so the design requires explicit durable rescheduling and reconciliation. [R2's Worker API](https://developers.cloudflare.com/r2/api/workers/workers-api-reference/) supplies private bounded-object staging. These primitives justify the reference service; they do not remove the need for race, deletion and recovery tests. Current [Worker limits](https://developers.cloudflare.com/workers/platform/limits/) and [Durable Object pricing](https://developers.cloudflare.com/durable-objects/platform/pricing/) must be checked against the account before deployment.

No account cost or free allowance is assumed. Budget from report volume × mean media bytes × retention plus ingress, readback/download operations, durable-object work and Sentry plan. For example, 1,000 reports/month averaging 2 MiB is about 2 GiB/month of raw media before copies/readback; it is not a price quote or adoption forecast. Set hard admission/storage budgets and assign the operator before launch.

GitHub's [issue API](https://docs.github.com/en/rest/issues/issues#create-an-issue) creates issues with authorised write access; it does not by itself provide anonymous private media intake. [Public attachment behavior](https://docs.github.com/en/get-started/writing-on-github/working-with-advanced-formatting/attaching-files) is why raw customer reports must not go straight into the public code repository.

## What is and is not verified

Verified: main/source/adjacent ownership inspection; pinned Sentry API/transport source; documented feedback/readback protocol; Mac SDK availability and platform docs; a concrete native/service contract, source seams, failure matrix and activation checklist.

Not verified: provisioned service/account/plan, private real receiver receipt, native capture or microphone flow, deployed retry/deletion/retention, novice usability, costs for the chosen account or production release. No customer data, provider credentials, synthetic submissions or cloud resources were used or created. Do not mark the feature complete from merging this research PR.

## Build-brief validation

The manifest JSON Schema was checked with Python `jsonschema==4.23.0`, `rfc3339-validator==0.1.4` and format assertions enabled: six valid synthetic inputs passed (text, unknown time, optional contact, image-only, voice-only and combined media); 21 invalid inputs were rejected across missing/unknown fields, identity/enums, text/email/date limits, duplicate descriptors, MIME/size/hash and dimensions. No media was uploaded. Byte/media decoding, service races and native behavior remain implementation tests. A format-checker object alone was insufficient without its date-time validator dependency; the negative date case caught that validation-environment gap.
