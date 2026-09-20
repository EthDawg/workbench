# Phone presentation: connection and audio

Reviewed 15 September 2026. This record owns the route decision and recovery contract; the [structured visual contract](../site/handbook/contract.json) owns capability status and acceptance. [Read the human guide](https://workbench-mac.vercel.app/phone-presenting/).

## Outcome

A presenter chooses a route for the actual job, can change to an Apple fallback without a capture conflict, and understands which device owns input and audio. Workbench remains a video-only scene compositor. This increment adds no driver, wireless receiver, microphone forwarding, meeting integration or workplace-policy detector.

| Job | First route to consider | Important limit |
| --- | --- | --- |
| Show a phone inside a branded scene | Workbench USB | Operate the physical phone; no phone audio enters Workbench. |
| Demonstrate an agent that listens and speaks | Rehearse QuickTime USB; in Zoom consider its native iPhone/iPad via Cable route with Share computer sound | Playback support is not proof of simultaneous microphone use, interruption or audience audibility. |
| Control a phone with Mac keyboard and mouse | Apple iPhone Mirroring, when available and permitted | The iPhone microphone and camera are unavailable in Mirroring. |
| No allowed USB route | AirPlay to an allowed receiver, or Teams/Zoom screen sharing directly from iPhone | Network policy, protected content and the phone app's audio mode may prevent the intended workflow. |

The three priorities were **route clarity and safe handoff**, an evidence-based phone-audio path, and a first-class wireless receiver. Implement the first now. Keep the second conditional on real duplex tests. Do not add the third merely to duplicate Apple, Teams or Zoom.

## Before, during, after

**Before:** Present a device → Connection & audio… opens without starting capture or prompting for permissions. Choose Show a phone, Voice conversation or Control from Mac. Select a route to see steps, limitations and official instructions. Preparation should happen before screen sharing; this guide is an ordinary visible window.

**During:** Workbench's phone tile stays small and click-operated. Source includes the same guide. A first capture needs an explicit source choice, even when only one muxed external source is available. Muxed media metadata is not verified phone identity. Subsequent reconnects use only the exact saved ID; losing that device never selects a different camera or customer's phone.

**Changing route:** End preview & open QuickTime Player / iPhone Mirroring explicitly ends this device presentation. The guide and source sheet dismiss first. App launching waits for both the presentation window to close and the capture queue to stop its session and remove observers. These completions may arrive in either order. Repeated clicks cannot launch twice or change the accepted destination. A launch failure produces a visible native error and does not restart capture. Opening an unavailable app leaves the existing view intact.

**After:** End stops Workbench's capture, control and keep-awake assertion. It does not end a meeting, stop a separately started phone broadcast, close an Apple app, restore wallpaper or alter saved scenes. The presenter ends those independent jobs explicitly.

## Voice rehearsal

Keep four owners distinct: the phone microphone receives the question; the phone app generates its reply; the meeting microphone carries the presenter; the meeting's shared-audio path carries the reply to attendees. A Mac microphone is not forwarded into an iPhone app by choosing a QuickTime audio input.

1. Choose the actual phone app, route and meeting variant. Use the physical phone for its voice interaction.
2. Verify its reply plays on the intended output. Workbench USB alone cannot provide this audio.
3. Ask a receiving participant to confirm the picture, presenter and reply, with no doubled sound.
4. Interrupt the agent and ask a follow-up. Check it still listens and replies.
5. Reconnect once and repeat. Stop each capture/broadcast after the rehearsal.

QuickTime exposes separate Camera, Microphone and monitoring controls. Zoom documents phone-audio sharing via cable. Neither document is evidence that every third-party voice app remains duplex. Apple documents that certain conversation audio modes disable AirPlay mirroring. Direct mobile meeting sharing also needs rehearsal because two apps may compete for the phone's audio session.

## Workplace Macs

USB avoids matching Apple Accounts and a wireless receiver; it still needs allowed pairing, a data cable, device trust and video access. Managed Apple Accounts are not a categorical exclusion from Mirroring: Apple lists it as available when both devices use the same account, with policy and hardware requirements still applying. Workbench does not inspect MDM or change policy. A restricted camera status offers an approved route or IT help. A denied status directs the user to Camera settings and Reconnect. Those are different recovery paths.

Teams computer audio on Mac may require its audio component and restart; use an approved installation route. Never install drivers, sign out of accounts or weaken security to make a demo appear ready. AirPlay network requirements and workplace accessory restrictions vary.

## Architecture

- `NativePresentationApps.swift`: one shared native guide and installed-Apple-app launcher. Static route information, no new service or persisted readiness flag.
- `DemoPresentation.swift`: sheet dismissal and explicit end-and-open intent. Owns the presentation's native window lifecycle.
- `PresentationLifecycle.swift`: a small handoff coordinator joins capture release and window closure exactly once, independent of callback order.
- `DemoCapture.swift`: serial capture queue, exact source identity, video-access diagnostics. Stop completion returns to main only after cleanup; it retains pending handoff even after the scene owner releases its presenter.
- Existing speech, wallpaper, overlay and personal sync owners stay independent. No file schema migration is required for this increment.

Do not infer screenshot exclusion from NSWindow flags, generic playback from an API's existence, or connectivity from successful app launch. An audio extension would need explicit source identity, disposable endpoint tests, interruption/reconnect lifecycle and a participant-confirmed duplex matrix before being offered as ready.

## Verification

Evidence is recorded with the implementation revision and native screenshots in the human guide and structured contract. Six focused regressions cover restricted/denied access, explicit first source, callback order, duplicate/failing launch, fullscreen transition failure and retained asynchronous capture cleanup. The native guide fixture injects a fake launch boundary: it does not establish a real USB transfer or meeting route.

Physical cable unplug/reconnect, second-display behavior, workplace policy, Teams/Zoom desktop and browser receiver views, and live agent microphone/playback are separate acceptance rows. App Store submission, notarization and a public downloadable build are separate release outcomes.

## Research and design record

The [primary-source comparison](research/phone-presentation.md) separates official product documentation from hands-on evidence. Claude reviewed a packet containing public source summaries and helped expose the gap between playback and audience audibility. The parent checked claims and rejected unsupported route guarantees. No competitor app was installed or exercised for this review.

The first generated concept invented a Workbench Wi-Fi route and misrepresented voice routing. It was rejected. A revised study explains the three jobs but still simplifies reply audio; actual native screenshots and the instructions above govern implementation. No generated picture establishes platform capability.
