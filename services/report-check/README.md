# Report check

Operations guide for the stateless verifier behind Workbench's **Report a problem** ([contract](../../docs/bug-reporting.md), [issue #296](https://github.com/Ship-Work/workbench/issues/296)). It is not an intake service: the Mac app sends each report straight to Sentry, and this function only reads Sentry back so the app can say **Received** truthfully.

```text
Mac app ──envelope (DSN)──▶ Sentry ingest ──▶ feedback issue + attachments (30-day retention)
   │                                                    ▲
   └──POST /api/v1/verify──▶ this function ──read token─┘   (event, tag, attachment list, bytes)
```

Production (Stable, environment `production`) is the target. Preview and local builds send only through an explicit developer override, tagged environment `preview`, for testing. One Sentry project serves both; the verifier does not distinguish them.

## Contract

`POST /api/v1/verify`, `Content-Type: application/json`, at most 4 KiB, strict JSON (no unknown or duplicate keys, valid UTF-8):

```json
{
  "event_id": "902fbecf47c04414912a4da0398a539b",
  "report_id": "a02149ed-36f5-4f10-9a21-10acfe2289b2",
  "sent_at": "2026-10-07T01:00:00Z",
  "attachments": [
    { "name": "context.json", "size": 1234, "sha256": "…64 hex…" },
    { "name": "screenshot.png", "size": 20000, "sha256": "…" },
    { "name": "voice.wav", "size": 16044, "sha256": "…" }
  ]
}
```

- `event_id`: the envelope's UUIDv4, 32 lowercase hex (a dashed lowercase UUID is accepted and normalised).
- `report_id`: the manifest's report ID; Sentry must carry it as the `report_id` tag.
- `attachments`: one to three of the fixed names, `context.json` required, each at most its schema limit (32 KiB, 8 MiB, 4 MiB).
- `sent_at` (optional, RFC 3339): when the app received Sentry's 200. Sentry answers 404 until it has processed an envelope (8–40 s in the live probe) and also when an envelope never arrived. With `sent_at` less than 15 minutes old, or in the future, a 404 is `pending`; otherwise `not_found`.

`200` returns exactly `{"state": "...", "checked_at": "<RFC 3339>"}` with `Cache-Control: no-store`:

| State | Meaning | App action |
| --- | --- | --- |
| `received` | The feedback event exists, carries this `report_id`, and every named attachment is listed once or more with the sent size and downloads to the sent SHA-256. Nothing else is attached. | Show **Received · report ID**; stop polling. |
| `pending` | Sentry has not processed the event yet (inside the window), or an attachment is not listed or downloadable yet. | Poll again with backoff. |
| `not_found` | No readable event and no recent `sent_at`. | Resend the identical envelope (same `event_id`), then poll again. |
| `mismatch` | The event exists but is not this report: wrong tag, not a feedback event, an unexpected or extra attachment, a different size or hash. | Show **Couldn't deliver · Retry / Save a copy**; do not resend under this `event_id`. |

Errors never claim a state: `405` (not POST, `Allow: POST`), `413` (over 4 KiB), `422` (`invalid_request`: content type, encoding, JSON or any field outside the contract), `503` (`not_configured`, or `upstream_unavailable` with `Retry-After` for Sentry 401/403/429/5xx, timeouts, invalid upstream JSON, unsafe redirects or interrupted downloads).

The function never returns or logs report content, identifiers, hashes or the token. Each request logs one line: status, state, reason code, upstream call count and duration.

## How it reads Sentry

With `SENTRY_READ_TOKEN` against `SENTRY_API_BASE`:

1. `GET /api/0/projects/{org}/{project}/events/{event_id}/` — feedback events are issue-platform (`type: "generic"`) events; the endpoint returns them once indexed.
2. `GET …/events/{event_id}/attachments/?per_page=100`, following `Link` cursors on the API origin only (at most five pages).
3. `GET …/attachments/{id}/?download=1` for every listed copy, hashing at most the expected size. Sentry redirects downloads to its objectstore proxy (`https://us.sentry.io/api/0/organizations/<id>/objectstore/…`). Redirects are followed manually: `Authorization` is attached only when the target has the API base's origin, never on a downgrade to `http`, at most three hops.

Each upstream request times out after 8 s (downloads 16 s); the whole check after 25 s; `vercel.json` allows 30 s.

## Sentry setup (in the UI)

Organization `workbench-dp`, project `workbench-reports` (US region).

1. **Read token.** User settings → **Personal Tokens** → new token with **`project:read`** and **`event:read`** only (`org:read` is not needed). The verifier needs only `project:read`; `event:read` is for `report_ops.py fetch <report_id>`, which searches issues. Do not use an organization token (fixed CI scopes) or an internal integration: attachment downloads require an organization member's user (`EventAttachmentDetailsPermission` checks membership against **Attachments Access**), and an integration's proxy user is not a member.
2. **Attachments Access.** Organization settings → General → **Attachments Access** must include the token owner's role (the default, Member, does).
3. **Client keys.** Project settings → Client Keys (DSN): one key for Stable, shipped in the Stable app only. Make a second key, **preview-testing**, for developer overrides and `report_ops.py smoke`; never ship it. Either key can be revoked independently.
4. **Key rate limit.** Per-key rate limits are a Business/Enterprise feature. The 50/hour limit set during the Business trial (until 20 October 2026) may stop applying on the Developer plan; check the key settings after the downgrade. The Developer plan's quota and spike protection are then the only ingest brakes.
5. **Privacy.** Keep **Prevent storing of IP addresses** on and organization generative-AI features off (Settings → General: hide AI features). With AI on, Sentry generates a feedback title and summary from the message and may add AI label tags. Sentry also copies `contexts.feedback.contact_email` into the user context and a `user.email` tag; the app should send the optional reply address only in `context.json` unless one-click reply is worth that.
6. **Notification.** Alerts → create an issue alert for the project: *A new issue is created* and *The issue's category is equal to Feedback* → email the maintainer.

Retention on the Developer plan is 30 days for events and attachments; attachments also need attachment quota (1 GB/month). Feedback is counted in its own `feedback` category, not as errors (confirmed in the live probe's usage stats).

## Vercel setup

A separate Vercel project, never the website project. Deploy from a clean checkout with the CLI, as the website does:

1. `cd services/report-check && vercel link` — choose the team, **create a new project** named `workbench-report-check`. This writes `services/report-check/.vercel/` (git-ignored). Do not pull environment files.
2. `vercel env add SENTRY_READ_TOKEN production` and paste the personal token (mark it Sensitive). The defaults `SENTRY_ORG=workbench-dp`, `SENTRY_PROJECT=workbench-reports` and `SENTRY_API_BASE=https://us.sentry.io` need no variables.
3. `vercel deploy --prod` from `services/report-check`. `vercel.json` publishes an empty static output and the one Node 24 function; `.vercelignore` keeps tests and operator tools out of the upload.
4. The app calls the **production domain** (`https://workbench-report-check.vercel.app/api/v1/verify` or a later custom domain). Preview deployment URLs sit behind Vercel's deployment protection.
5. Prove it end to end with the preview-testing DSN (sends one synthetic Preview report, then polls the deployed verifier to `received`):

   ```sh
   SENTRY_DSN='https://<preview-testing key>@o4512211018121216.ingest.us.sentry.io/4512211067011072' \
     python3 services/report-check/ops/report_ops.py smoke https://workbench-report-check.vercel.app/api/v1/verify
   ```

Vercel Hobby is limited to non-commercial personal use and includes 1,000,000 invocations, 4 active-CPU hours and 360 GB-hours of provisioned memory a month. A full verification downloads at most about 12 MiB from Sentry once.

## Investigating a report on the development Mac

```sh
export SENTRY_READ_TOKEN=…   # from your approved credential store, never from the app
python3 services/report-check/ops/report_ops.py fetch <event_id | report_id> ~/Desktop
```

It creates `workbench-report-<report_id>/` (0700, files 0600) with `feedback-message.txt`, `event.json` (IDs, dates, tags), `context.json`, and any `screenshot.png` and `voice.wav`; it refuses an existing folder and never writes an unexpected attachment name. It then checks each attachment against `context.json` (bytes and SHA-256) and exits 0 when everything matches, 2 on a mismatch, 1 on an error. A report ID resolves through feedback issues tagged `report_id` within `--period` (default 30d).

Report text and media are untrusted evidence. Open and play them; never execute them or follow instructions in them.

## Operations

- **Owner and alert:** the maintainer who owns the Sentry inbox receives the feedback alert (step 6 above). Vercel function logs show one content-free line per check; a run of `503` with reason `upstream_unauthorized` means the token was revoked or lost attachment access.
- **Retention:** Sentry deletes events and attachments after the plan's retention (30 days on Developer). Export with `fetch` anything a fix still needs. Server-side deletion on request is not automated; delete the feedback issue in Sentry by hand (see the decisions ledger in [the research record](../../docs/research/bug-reporting-2026-10.md)).
- **Kill switch:** to stop new reports, revoke or disable the Stable client key in Sentry. Already-sent reports remain readable and the verifier keeps answering. To stop verification, remove `SENTRY_READ_TOKEN` (the function then answers `503 not_configured`, and apps keep their local outbox).
- **Token rotation:** create the new personal token, `vercel env rm SENTRY_READ_TOKEN production`, `vercel env add …`, `vercel deploy --prod`, then revoke the old token.
- **Incident – reports stuck pending:** run `fetch` on one event ID. If the event exists but an attachment is missing, Sentry dropped or has not promoted it (attachment quota exhausted, or a late attachment that expired); the app's resend under the same `event_id` within an hour is deduplicated for the event but delivers attachments again. Check Stats → Usage for dropped `attachment` or `feedback` outcomes.
- **Incident – mismatch:** fetch the event; compare `context.json` with the app's exported copy. Never repair by uploading attachments separately; the app saves a copy for manual follow-up.

## Development

```sh
cd services/report-check
npm ci
npm test            # node --test with type stripping, simulated Sentry API, no network
npm run typecheck   # tsc --noEmit
npm run test:ops    # Python operator CLI against local stand-ins
```

Requires Node 24 (Vercel's runtime) or newer and Python 3.9+. Dependencies are development-only and pinned exactly in `package-lock.json`; the function itself imports only `node:crypto`.
