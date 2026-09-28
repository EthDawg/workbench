# One step toward everyday dictation

Decision: 13 September 2026. Scope: one addition to transcript review, **Remember correction…**.

## What was actually compared

The installed Wispr Flow 1.6.827 and Superwhisper 2.18.3 were explored through their native interfaces: settings, modes and dictionary forms. A synthetic `stage mark → StageMark` replacement was entered in both forms and cancelled. No competitor dictionary or preference was saved, and no private transcript is reproduced here. Handy was researched through its official documentation, not installed or exercised.

This is a workflow and architecture comparison, not a speech-accuracy, speed, battery or reliability benchmark. No matched recording was run across these products. Documentation can describe a capability without establishing its quality on this Mac.

| Job | Wispr Flow | Superwhisper | Workbench and the remaining gap |
| --- | --- | --- | --- |
| Speak into a Mac field | Cloud dictation with contextual formatting and insertion behavior | Local or cloud recognition; optional separate language processing | Local capture, target checks, copy fallback and recoverable history exist. Surrounding-text spacing and capitalisation are not yet adapted. |
| Get familiar names right | Dictionary hints and explicit misspelling replacements; clear before/after form | Vocabulary hints and deterministic replacements; keyboard shortcut reveals the second field | Literal replacements existed in Dictionary. This change brings them to the moment a mistake is noticed, with an exact draft preview. |
| Turn speech into useful writing | Lists, clear spoken corrections and context-aware formatting | Voice-to-text, built-in modes and custom processing instructions | Conservative Light cleanup and guarded local Natural refinement exist. Broad app-specific writing styles and multilingual quality remain unevaluated. |
| Stay in the flow | Shortcut-led capture and recovery | Mini/full recorder and model/mode controls | Compact/expanded capture, snap positions, Stop/Cancel and clipboard receipts already exist. Another floating menu would add less value than better text. |
| Succeed on first use | Guided first dictation, destination and shortcut instructions | Quickstart, permissions, shortcut and model setup | Workbench has setup controls and diagnostics. A single guided, verified first paste still needs designing and testing. |

Handy's local-first approach is a closer distribution comparator. Its docs openly describe imperfect fuzzy custom-word correction and experimental post-processing. We chose exact replacements because their effect can be inspected and tested without an extra model.

## Ranked next steps

1. **Remember a correction where you review it — selected for this change.** A repeat mistake becomes a deliberate local rule. It uses the dictionary we already maintain and gives immediate, inspectable value. This is an incremental priority, not a claim that every user has this problem.
2. **Respect text around the insertion point.** Avoid joined words, duplicate spaces and inappropriate capitals when dictating mid-sentence. First measure supported native and browser fields; use surrounding text only where it is safely available. Preserve copy fallback and the user's literal names, numbers and code. This is an unimplemented gap, not a defect observed in every app.
3. **Guide one successful dictation.** Bring model readiness, permission, shortcut and a scratch destination into one short first-use path. Confirm what reached the field and give a clear recovery path. This needs a fresh-user test, not more settings.

A separate Claude review challenged the ordering: insertion mechanics and first-use success can matter to more people than remembered names. That is a useful challenge. The selected change has a smaller, deterministic boundary; the next two deserve direct measurement before extending modes, models or menus.

## Interaction contract

- Entry: the Mac app window, Dictate → Your words → **Remember correction…**. Recent transcripts can be opened here. This action does not belong in the live recording panel or phone presentation tile.
- Selecting a short phrase in Workbench's transcript prefills Heard. With no usable selection, Heard is blank. Never guess from the whole utterance, another app or clipboard.
- Both fields remain explicit and editable. Tab moves between them; Return saves a valid proposal; Escape cancels. The preview is selectable text with a heading, not a colour-only diff.
- Matching is literal and case-insensitive, with the existing Unicode word/phrase boundaries. Preserve the preferred spelling exactly. Accept case-only corrections and punctuation; reject empty, multiline, control-character and overlong rules.
- Preview applies this correction to every matching occurrence in the current draft, preserving whitespace. It does not replay unrelated dictionary rules. Future dictations continue to use the existing ordered dictionary pipeline, so overlapping rules should be reviewed in Dictionary.
- Dictionary's Add and Remember correction share one validation and one phrase identity: Heard is compared ignoring case, as matching does. Saving an exact saved pair, or changing only Heard's casing, changes nothing. A different Write for a saved phrase, including a casing change, shows the current value and an explicit **Update**, which preserves the rule's identity and position and keeps the chosen spelling exactly. Dictionary's Add and Update change future dictations only; they never rewrite the current draft.
- Rules saved by earlier versions can share a phrase, and which spelling dictation writes depends on their order and outputs. Dictionary names the spelling dictation writes today and shows each such phrase with every saved value and a **Keep** choice for each. Keeping one leaves it in the first rule's place and removes only that phrase's other rules. Until then Add, Update and Remember correction explain the conflict and change nothing. Rules are never silently deleted.
- Save the prospective session before publishing success. Failed saving retains all old state and keeps the form available to retry. A changed draft or active capture prevents a stale save.
- The raw recognizer original and prior history never change. No new clipboard write or paste occurs. Copy the corrected draft when ready; this does not repair text already pasted elsewhere.
- Show an inline receipt with Undo and Dismiss. Undo restores the previous dictionary state. Restore the draft only if its revision and contents still match the saved correction; preserve all later edits, even if they return to the same text. A new capture, another transcript or a manual dictionary change ends this receipt's scope.
- Rules persist locally across launches. Undo is a current-session action; Dictionary remains the lasting place to inspect or remove a rule.

## Sources

Official documentation read 12–13 September 2026:

- [Wispr Flow: dictionary hints and replacements](https://docs.wisprflow.ai/articles/4052411709-teach-flow-your-words-with-the-dictionary)
- [Wispr Flow: smart formatting and backtrack](https://docs.wisprflow.ai/articles/5373093536-how-do-i-use-smart-formatting-and-backtrack)
- [Wispr Flow: first dictation](https://docs.wisprflow.ai/articles/6409258247-starting-your-first-dictation)
- [Wispr Flow: accuracy and known limitations](https://docs.wisprflow.ai/articles/4048537120-what-to-expect-from-flow-accuracy-and-known-limitations)
- [Superwhisper: vocabulary and replacements](https://superwhisper.com/docs/get-started/interface-vocabulary)
- [Superwhisper: modes](https://superwhisper.com/docs/modes/modes)
- [Superwhisper: recording window](https://superwhisper.com/docs/get-started/interface-rec-window)
- [Superwhisper: quickstart](https://superwhisper.com/docs/get-started/quickstart)
- [Handy: advanced settings and custom words](https://handy.computer/docs/advanced)
- [Handy: post-processing](https://handy.computer/docs/post-processing)

## Verification of this increment

- 43 production correction-rule checks: validation, matching, Unicode, literal punctuation, updates, duplicates and real temporary StateStore round-trip.
- 43 checks executing the exact AppModel save/undo methods: failed saves and retries, changed drafts, active operations, prior dictionary values, and preservation of later edits including edits that return to the same text. A mutation removing the revision guard fails the regression.
- Native UI fixture used the production SwiftUI sheet and selection observer, actual transaction methods, and an in-memory session. Verified selection prefill, exact preview, Return save, immediate Undo, preservation of later typing, blank no-selection form, Tab and Escape cancellation. The published image is this fixture, not a user's session or a full-app recording.
- Full existing regression suite passed, including 61 StageKit tests / 1,553 assertions. Site checks passed.

No new competitor recording, real microphone benchmark, VoiceOver session or meeting receiver test was performed. The live Preview's private draft was not replaced for testing.
