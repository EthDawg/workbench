# Running a release-lead session

A playbook for a coding agent (Claude, Codex or another harness) asked to choose, build, integrate and verify the work for the next Workbench release. It is written as steps, not as a diary. Every path and command below exists in this repository. A lead that follows it should finish faster than the first one did, with the same standard of evidence. The first run's records are the verification folders dated 6 October 2026 under [docs/verification](verification/) and its ledger of decisions not taken under [docs/research](research/).

Keep the roles apart throughout: a lead chooses and integrates; workers implement; an independent reviewer challenges each branch; one integration owner alone touches the shared installed Preview; the release step packages and publishes. Being a lead does not make you the integration owner.

## 1. Read first

Read these before deciding anything. They are the rules the work will be judged by.

1. [Grammar](workbench.md#grammar) and [Fit](workbench.md#fit) in the product contract: the classification of every change (Quality, Option, new capability), the surface registry rule, and the seven Fit rules with the check that holds each one.
2. [Installing, testing and updating](updating.md): the two app identities, the one workflow, the merge queue, and what counts as evidence for each state (source checked, Preview installed, native acceptance, merged, packaged, published).
3. [CONTRIBUTING.md](../CONTRIBUTING.md): the four test phases, the fixed member lists the Python harnesses compile, the galleries and the native History acceptance host.
4. [The focused Mac foundation](mac-foundation.md), the decided refinement brief: what is retired, what is paused and the outcomes a change must serve; its dated decisions supersede older proposals and any candidate list, including the one in a previous batch's research record.
5. Issue #7, the Mac release gate, its open acceptance items and its current checkpoint comment, which is the implementation queue.
6. The open issues and PRs, and every comment posted in the last day, which is where another lead's claim will be:

```sh
gh issue list --repo Ship-Work/workbench --state open --limit 200
gh pr list --repo Ship-Work/workbench --state all --limit 40
gh api 'repos/Ship-Work/workbench/issues/comments?since=YYYY-MM-DDT00:00:00Z&per_page=100' --jq '.[] | [.issue_url, .created_at, .user.login] | @tsv'
```

7. Live writers on this Mac: `git worktree list` shows every checkout, and a worktree with recent commits on an unpushed branch is someone's work in progress even when no PR exists. Never write in another worktree.

## 2. Ground the choice

Choose from what the maintainer has repeatedly asked for and from what the installed app does, not from features the model thinks are missing.

**The maintainer's request history.** Read the local assistant logs privately and reduce them to themes: the intent, how many times it was asked, when it was first and last asked, and how it turned out. Only the themes enter the repository. Never quote a prompt, a session identifier or a local path into an issue, a PR or a document. Count a request once per session, exclude task briefs that agents wrote, and keep the maintainer's own words for the objective's name.

**The installed app's evidence.** The unified log holds what the app did on this Mac; count fault families before and after, never guess. These predicates found the families that mattered last time:

```sh
log show --last 7d --predicate 'process BEGINSWITH "Workbench" AND messageType IN {16,17}' --style compact
log show --last 7d --predicate 'process BEGINSWITH "Workbench" AND subsystem == "com.apple.Accessibility" AND eventMessage CONTAINS "unsafeForcedSync"' --style compact | wc -l
log show --last 7d --predicate 'process BEGINSWITH "Workbench" AND subsystem == "com.apple.siri" AND eventMessage CONTAINS "AFLocalization"' --style compact | wc -l
log show --last 7d --predicate 'process BEGINSWITH "Workbench" AND subsystem == "com.apple.runtime-issues"' --style compact | grep -c -E "Invalid view geometry|Publishing changes|Accessing State"
```

Group a flood by process and thread before explaining it: bursts of one size in the same second as another subsystem's lines point to one call site. A capture filtered to one subsystem cannot count another subsystem's lines, so count each family under its own predicate. Crash, hang and spin reports live in `~/Library/Logs/DiagnosticReports` and `/Library/Logs/DiagnosticReports`; a report for a scratch binary is tooling, not the app. Usage signals are folder counts only: count the saved-work folders under each edition's Application Support folder (named in [the release README](../scripts/release/README.md)) and never open their contents. `python3 scripts/release/status.py` inventories the installed editions and their builds.

**The branch audit.** Decide what is merged by ancestry, not by name:

```sh
git fetch origin
git branch -a --no-merged origin/main
git merge-base --is-ancestor <branch> origin/main && echo merged
git cherry origin/main <branch>
git log origin/main --oneline --grep='#<issue>'
```

`git cherry` compares patch ids: a minus means that commit's patch is already on main; a plus means it is not, and a matching subject is not proof of anything. Before calling a plus-commit superseded, show patch equivalence: `git range-diff origin/main...<branch>` against the commits that landed, or an empty `git diff <landed commit> <branch commit>` for the files it touches. A branch whose net diff against main is empty is superseded. A non-empty diff proves nothing by itself: a fully landed branch that sits behind later main commits also differs from main. Decide by patch equivalence (`git range-diff`, or `git cherry` minuses for every commit) and ancestry (`git merge-base --is-ancestor`), never by the diff alone or by subjects. A closed PR with a maintainer decision stays closed.

**The backlog map.** For each open ticket, find its landing commits with the `git log --grep` above and read its last comment. Many QA tickets stay open only for native acceptance of work already on main; they are not candidates, and reopening them with new scope wastes the next lead's hour.

## 3. Choose and claim

Write one objective in the maintainer's own words, with the user outcome, the streams, each stream's acceptance and the branch names. Post it as a comment on #7 and on each ticket a stream touches. Read the other lead's claims first and divide scope by journey, never by file: two leads changing one function on parallel branches is the conflict you cannot review your way out of. Agree in the same comments who owns the shared installed Preview; if the other lead already holds it, verify from scratch builds and hand installed acceptance to them (section 8).

Prefer Quality changes to existing capabilities, foundations before the work that depends on them, and a stream per worktree that one worker can finish in a session. Say in the claim what you will not build and why.

## 4. Build

Make one worktree per stream from current main, named for the stream:

```sh
git worktree add ../wb-<stream> -b <harness>/<stream> origin/main
```

Give each worker a brief with the outcome, the scope (files and surfaces), the acceptance (the check modes, harness, render or fixture that will prove it) and the rules:

- Classify the change by the Grammar before building and say the classification in the PR.
- A new or renamed entry point needs a deliberate change to [docs/surfaces.json](surfaces.json); run `python3 scripts/check-surfaces.py`.
- A visible change ships with renders of the surfaces it touches, with synthetic content, under `docs/verification/<date>-<topic>/`.
- Write `Refs #N`, not `Fixes #N`: a ticket closes after native acceptance, not at merge.
- Keep the repository's attribution lines on commits and PR descriptions.
- Keep private data, local paths and assistant-log text out of the repository.

Then run an independent adversarial reviewer on each branch with the diff, the brief and the contract, asking for failures with reproduction steps rather than opinions, and a fix pass that answers every finding. Read the reviewer's findings yourself before accepting the fix.

The harness rule: the Python harnesses in `scripts/` compile production Swift from fixed lists of files and members ([scripts/test-live-dictation.py](../scripts/test-live-dictation.py), [scripts/test-capture-persistence.py](../scripts/test-capture-persistence.py), [scripts/test-reading-playback.py](../scripts/test-reading-playback.py), [scripts/test-read-selection-service.py](../scripts/test-read-selection-service.py)). A new file, a new member or a renamed member in `Sources/LocalVoice/AppModel.swift`, the delivery code or the Read code fails CI's Harnesses and StageKit job until those lists are taught about it. Before pushing any such change:

```sh
bash scripts/test.sh harnesses
python3 scripts/swift_extract.py Sources/LocalVoice/AppModel.swift AppModel
```

## 5. Integrate

Read every diff first-hand before queueing it; a worker's summary and a reviewer's verdict are inputs, not evidence. Post the review on the PR, mark it ready and queue it:

```sh
gh pr diff <n> --repo Ship-Work/workbench
gh pr review <n> --repo Ship-Work/workbench --comment --body-file <review.md>
gh pr ready <n> --repo Ship-Work/workbench
gh pr merge <n> --repo Ship-Work/workbench --merge
```

`gh pr merge` enables auto-merge while checks are pending and queues the PR when they pass; use the `--repo Ship-Work/workbench` spelling that [docs/updating.md](updating.md) documents. Queue foundations first and let the dependent branch rebase onto the merged foundation.

Runner contention: the merge queue, PR runs and post-merge push runs share five macOS slots, and a queue entry can wait more than an hour behind them (the first run saw waits of 37 to 90 minutes). A run that fails while cloning a dependency is a runner network error, not a regression; re-queue it. Watch with `gh run list --repo Ship-Work/workbench --limit 30`. A post-merge push run repeats the merge-group run that validated that exact tree, and a PR run for a head that a newer push superseded proves nothing; both are safe to cancel with `gh run cancel <id> --repo Ship-Work/workbench`. Never cancel a merge-group run.

Two branches, one function: when two streams change the same function, decide which root-cause fix owns it, merge that branch first, then rebuild the other on top of it rather than taking a textual merge. Record the decision in the second PR's description. A clean `git merge-tree` is not a build: two branches can add a local with the same name to one function on different lines and compile only apart. Before queueing siblings that touch one file, merge them into a scratch checkout and run `swift build --disable-sandbox` once, or queue them one at a time; a failed merge-group run for a sibling means dequeue it, fix the clash on its branch, and queue it again (`gh api graphql` with `dequeuePullRequest`, then `gh pr merge` again).

## 6. Verify on integrated main

With no Workbench edition running (the suite skips two exclusive-shortcut checks while one holds the defaults), run the whole suite on main after the last merge:

```sh
bash scripts/test.sh
```

Build a signed scratch Preview without installing it, unpack it in a scratch folder and run the packaged binary's check modes under the log:

```sh
bash scripts/build.sh --preview
ditto -x -k "dist/Workbench Preview.zip" .build/verify
bash scripts/verify-preview.sh ".build/verify/Workbench Preview.app" .build/verify/out
```

`scripts/verify-preview.sh` prints one row per check mode with four columns: `exit` is the mode's exit code, `axsync` counts Accessibility "unsafeForcedSync" faults, `siri` counts Siri AFLocalization errors and `runtime` counts AppKit and SwiftUI runtime-issue faults logged by that process id while the mode ran (the log window opens in local time, which is how `log show --start` reads a zone-less date). Before any mode runs it validates the bundle through the release tooling (exact Preview identity, executable and channel, absence of the retired Read Service, strict codesign, Developer ID) and refuses a Stable, ad-hoc or tampered bundle. It never installs or touches saved data and opens no visible or interactive window; a check may host an invisible view. A failed log query prints capture-failed instead of a number and fails the script, so unavailable evidence never reads as a clean pass. This is source evidence from the packaged binary, not installed acceptance. Its mode list names the check modes on `main`; add a mode when the PR that brings it merges. Read is retired; `--check-read-retirement` checks preservation and inactive admission without a TTS provider. Any non-zero count on a mode that was zero before is a regression to explain before release.

Render the galleries for every visible change and compare them with the renders in the PRs:

```sh
BIN_DIR="$(swift build -c release --disable-sandbox --show-bin-path)"
"$BIN_DIR/LocalVoice" --render-surfaces .build/verify/surfaces
swift run --disable-sandbox ToolbarGalleryRenderer .build/verify/toolbar
```

What counts as evidence follows [docs/updating.md](updating.md): a source check, an offscreen render, a CI pass and a scratch build are source evidence. Installed acceptance needs the exact installed path, Copy build details and the changed workflow exercised there, and only the integration owner provides it.

## 7. Record

Write three records before handing off, so nothing learnt is lost:

1. `docs/verification/<date>-<topic>/README.md` per stream or batch: branch and base commit, what was found, what changed, the counts before and after with the exact capture command, the renders, and what was not verified. The folders dated 2026-10-06 under [docs/verification](verification/) are the model.
2. `docs/research/<date>-<batch>.md`: the ledger of decisions not taken. For each one write what was proposed, why it was not built, and the observation or request that would change the decision. A deferred idea with its trigger is worth more to the next lead than a built feature with no reason.
3. Issue comments: the objective and scope on #7, the acceptance owed on each ticket, and the list of native checks the lead could not perform.

Keep a private memory of what is owed (installed-app fault counts after a day of use, real dictation into several editors, a real selection read, VoiceOver, real downloads surviving a page change) so the next session starts from the debt rather than rediscovering it.

## 8. Hand off

Tell the integration owner the exact main commit and the scratch build they should reproduce, then what to install and check: `bash scripts/install.sh --no-open` with Preview quit, Copy build details from the installed path, and each owed native check from section 7. Installed acceptance is their report, not yours.

The release step owns packaging, notarization, publication and the website, by [scripts/release/README.md](../scripts/release/README.md) and `scripts/release/prepare_update.py`; a lead prepares nothing there. Write the maintainer a short note: what users gain, the main commit, the PR numbers, what was verified and how, what is owed and to whom, and whether the evidence supports a release. Keep investigation detail in the records above, not in the note.

## 9. Clean up worktrees

Remove each stream worktree once its PR is merged or closed, and prune the rest:

```sh
git worktree remove ../wb-<stream>
git worktree prune
git branch --merged origin/main
```

Leave another lead's worktrees alone. Remove a scratch verify folder under `.build/` only after its counts are in a record.
