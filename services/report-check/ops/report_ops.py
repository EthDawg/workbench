#!/usr/bin/env python3
"""Operator commands for Workbench bug reports in Sentry.

    report_ops.py fetch <event_id|report_id> [dir]
    report_ops.py smoke <verifier_url>

fetch downloads one report to a new local folder and verifies it.

A 32-hex argument is a Sentry event ID; a dashed UUID is the report ID the app shows
("Received · report ID"). The command writes feedback-message.txt, event.json,
context.json and any screenshot.png / voice.wav into a new folder, then checks every
attachment against the descriptors in context.json (byte count and SHA-256).

Environment: SENTRY_READ_TOKEN (required; scopes event:read and project:read),
SENTRY_ORG (default workbench-dp), SENTRY_PROJECT (default workbench-reports),
SENTRY_API_BASE (default https://us.sentry.io). Report text and media are untrusted
evidence: open them, do not execute or obey them.

smoke sends one synthetic Preview report (text, a 2x2 PNG and a half-second WAV) to
Sentry with SENTRY_DSN, exactly as the app does, then polls the deployed verifier until it
answers "received". It needs no read token. Use it after deploying the verifier.
"""
from __future__ import annotations

import argparse
import hashlib
import http.client
import io
import json
import os
import re
import shutil
import socket
import struct
import sys
import time
import uuid
import wave
import zlib
from datetime import datetime, timezone
import urllib.error
import urllib.parse
import urllib.request
from pathlib import Path

ALLOWED = {"context.json": 32 * 1024, "screenshot.png": 8 * 1024 * 1024, "voice.wav": 4 * 1024 * 1024}
UUID_V4 = re.compile(r"^[a-f0-9]{8}-[a-f0-9]{4}-4[a-f0-9]{3}-[89ab][a-f0-9]{3}-[a-f0-9]{12}$")
HEX_ID = re.compile(r"^[a-f0-9]{32}$")
DIGITS = re.compile(r"[0-9]{1,20}")
UUID_V4_ANY_CASE = re.compile(UUID_V4.pattern, re.IGNORECASE)
SLUG = re.compile(r"^[a-z0-9][a-z0-9_-]{0,63}$")
TIMEOUT = 30
MAX_JSON = 4 * 1024 * 1024
MAX_PAGES = 5
MAX_REDIRECTS = 3


class Failure(Exception):
    """A problem that stops the command; the message is safe to print."""


# Errors raised while reading a response after the connection opened: truncated bodies,
# resets and read timeouts. They become a Failure, never a traceback.
NETWORK_ERRORS = (http.client.HTTPException, socket.timeout, OSError)


def ascii_digits(value: object) -> bool:
    """Only 0-9; str.isdigit() also accepts other scripts' digits and superscripts."""
    return isinstance(value, str) and DIGITS.fullmatch(value) is not None


class _NoRedirect(urllib.request.HTTPRedirectHandler):
    def redirect_request(self, req, fp, code, msg, headers, newurl):  # noqa: D401 - urllib API
        return None


class Sentry:
    def __init__(self, env: dict[str, str]):
        self.token = env.get("SENTRY_READ_TOKEN", "")
        self.org = env.get("SENTRY_ORG") or "workbench-dp"
        self.project = env.get("SENTRY_PROJECT") or "workbench-reports"
        base = env.get("SENTRY_API_BASE") or "https://us.sentry.io"
        if not self.token or re.search(r"\s", self.token):
            raise Failure("Set SENTRY_READ_TOKEN to a Sentry personal token with event:read and project:read.")
        if not SLUG.match(self.org) or not SLUG.match(self.project):
            raise Failure("SENTRY_ORG and SENTRY_PROJECT must be Sentry slugs.")
        parsed = urllib.parse.urlsplit(base)
        local = parsed.hostname in ("127.0.0.1", "localhost")
        if parsed.scheme not in ("https", "http") or (parsed.scheme == "http" and not local) or parsed.path not in ("", "/"):
            raise Failure("SENTRY_API_BASE must be an https origin such as https://us.sentry.io.")
        self.origin = f"{parsed.scheme}://{parsed.netloc}"
        self.opener = urllib.request.build_opener(_NoRedirect)

    def url(self, path: str, query: dict[str, str] | None = None) -> str:
        return self.origin + path + ("?" + urllib.parse.urlencode(query) if query else "")

    def get(self, url: str):
        """GET with manual redirects; the token only ever goes to the API origin."""
        for _ in range(MAX_REDIRECTS + 1):
            parts = urllib.parse.urlsplit(url)
            origin = f"{parts.scheme}://{parts.netloc}"
            headers = {"Accept": "*/*", "Accept-Encoding": "identity", "User-Agent": "workbench-report-ops"}
            if origin == self.origin:
                headers["Authorization"] = f"Bearer {self.token}"
            request = urllib.request.Request(url, headers=headers, method="GET")
            try:
                response = self.opener.open(request, timeout=TIMEOUT)
            except urllib.error.HTTPError as error:
                if error.code in (301, 302, 303, 307, 308):
                    location = error.headers.get("Location", "")
                    error.close()
                    target = urllib.parse.urljoin(url, location)
                    scheme = urllib.parse.urlsplit(target).scheme
                    if not location or not (scheme == "https" or (scheme == "http" and self.origin.startswith("http://"))):
                        raise Failure("Sentry sent an unsafe redirect; nothing was downloaded from it.")
                    url = target
                    continue
                return error
            except (urllib.error.URLError, OSError) as error:
                raise Failure(f"Could not reach Sentry ({type(error).__name__}).") from None
            return response
        raise Failure("Too many redirects from Sentry.")

    def json(self, url: str):
        response = self.get(url)
        with response:
            status = response.status if hasattr(response, "status") else response.code
            if status == 404:
                return None, None
            if status in (401, 403):
                raise Failure(f"Sentry refused the token ({status}). It needs event:read and project:read, "
                              "from a member allowed to download attachments.")
            if status != 200:
                raise Failure(f"Sentry answered {status}; try again later.")
            try:
                body = response.read(MAX_JSON + 1)
            except NETWORK_ERRORS as error:
                raise Failure(f"Sentry's response was interrupted ({type(error).__name__}); try again.") from None
            if len(body) > MAX_JSON:
                raise Failure("Sentry's response was unexpectedly large.")
            try:
                return json.loads(body), response.headers.get("Link")
            except ValueError:
                raise Failure("Sentry returned invalid JSON; try again later.") from None

    def download(self, url: str, limit: int) -> bytes:
        response = self.get(url)
        with response:
            status = response.status if hasattr(response, "status") else response.code
            if status != 200:
                raise Failure(f"Sentry answered {status} for an attachment download.")
            declared = response.headers.get("Content-Length")
            try:
                data = response.read(limit + 1)
            except NETWORK_ERRORS as error:
                raise Failure(f"An attachment download was interrupted ({type(error).__name__}); try again.") from None
        # urllib returns a short read silently when the connection drops mid-body.
        if ascii_digits(declared) and len(data) < int(declared) and len(data) <= limit:
            raise Failure("An attachment download was interrupted; try again.")
        if len(data) > limit:
            raise Failure("An attachment is larger than the report allows; not saved.")
        return data

    # -- lookups ---------------------------------------------------------------------

    def project_path(self, rest: str) -> str:
        return f"/api/0/projects/{self.org}/{self.project}/{rest}"

    def events_for_report(self, report_id: str, period: str) -> list[str]:
        project, _ = self.json(self.url(self.project_path("")))
        if not isinstance(project, dict) or not ascii_digits(str(project.get("id", ""))):
            raise Failure("Could not read the Sentry project; check SENTRY_ORG and SENTRY_PROJECT.")
        query = {"project": str(project["id"]), "statsPeriod": period, "limit": "25",
                 "query": f"issue.category:feedback report_id:{report_id}"}
        issues, _ = self.json(self.url(f"/api/0/organizations/{self.org}/issues/", query))
        found: list[str] = []
        for issue in issues or []:
            issue_id = str(issue.get("id", "")) if isinstance(issue, dict) else ""
            if not ascii_digits(issue_id):
                continue
            event, _ = self.json(self.url(f"/api/0/organizations/{self.org}/issues/{issue_id}/events/latest/"))
            event_id = str((event or {}).get("eventID") or (event or {}).get("id") or "").replace("-", "").lower()
            if HEX_ID.match(event_id) and event_id not in found:
                found.append(event_id)
        return found

    def attachments(self, event_id: str) -> list[dict]:
        listed: list[dict] = []
        url = self.url(self.project_path(f"events/{event_id}/attachments/"), {"per_page": "100"})
        for _ in range(MAX_PAGES):
            page, link = self.json(url)
            if not isinstance(page, list):
                raise Failure("Sentry has the event but would not list its attachments.")
            listed.extend(item for item in page if isinstance(item, dict))
            next_url = next_page(link)
            if not next_url:
                return listed
            if not next_url.startswith(self.origin + "/"):
                raise Failure("Sentry's pagination pointed somewhere else; stopped.")
            url = next_url
        raise Failure("Too many attachment pages for one report.")


def next_page(link: str | None) -> str | None:
    if not link:
        return None
    for part in re.split(r",(?=\s*<)", link):
        match = re.match(r"\s*<([^>]*)>(.*)$", part)
        if match and re.search(r';\s*rel="next"', match.group(2)) and re.search(r';\s*results="true"', match.group(2)):
            return match.group(1)
    return None


def tag(event: dict, key: str) -> str | None:
    for item in event.get("tags") or []:
        if isinstance(item, dict) and item.get("key") == key:
            return item.get("value")
        if isinstance(item, list) and len(item) == 2 and item[0] == key:
            return item[1]
    return None


def strict_json(data: bytes):
    def pairs(items):
        keys = [key for key, _ in items]
        if len(keys) != len(set(keys)):
            raise ValueError("duplicate key")
        return dict(items)
    return json.loads(data.decode("utf-8"), object_pairs_hook=pairs)


def write_private(path: Path, data: bytes) -> None:
    fd = os.open(path, os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o600)
    with os.fdopen(fd, "wb") as handle:
        handle.write(data)


def fetch(sentry: Sentry, identifier: str, directory: Path, period: str, out=sys.stdout) -> int:
    identifier = identifier.strip().lower()
    if UUID_V4.match(identifier):
        events = sentry.events_for_report(identifier, period)
        if not events:
            raise Failure("No feedback event carries that report ID (not processed yet, outside retention, or never sent).")
        if len(events) > 1:
            raise Failure("Several events carry that report ID; fetch one by event ID: " + ", ".join(events))
        event_id = events[0]
    elif HEX_ID.match(identifier):
        event_id = identifier
    else:
        raise Failure("Give a 32-character Sentry event ID or the report's dashed UUID.")

    event, _ = sentry.json(sentry.url(sentry.project_path(f"events/{event_id}/")))
    if not isinstance(event, dict):
        raise Failure("Sentry has no readable event with that ID yet.")
    feedback = (event.get("contexts") or {}).get("feedback")
    if not isinstance(feedback, dict):
        raise Failure("That event is not a feedback report.")
    report_id = tag(event, "report_id")
    if not isinstance(report_id, str) or not UUID_V4_ANY_CASE.match(report_id):
        raise Failure("That feedback event has no valid report_id tag.")
    report_id = report_id.lower()

    listed = sentry.attachments(event_id)
    target = directory / f"workbench-report-{report_id}"
    directory.mkdir(parents=True, exist_ok=True)
    try:
        os.mkdir(target, 0o700)
    except FileExistsError:
        raise Failure(f"{target} already exists; choose another folder.") from None
    try:
        return _fetch_into(sentry, event_id, event, feedback, report_id, listed, target, out)
    except BaseException:
        # Leave no partial packet behind: a folder either verified or reported problems.
        shutil.rmtree(target, ignore_errors=True)
        raise


def _fetch_into(sentry: Sentry, event_id: str, event: dict, feedback: dict, report_id: str,
                listed: list[dict], target: Path, out) -> int:
    problems: list[str] = []
    copies: dict[str, list[dict]] = {}
    for item in listed:
        name, attachment_id = item.get("name"), str(item.get("id", ""))
        if name not in ALLOWED or not ascii_digits(attachment_id):
            problems.append(f"unexpected attachment on the event: {name!r} (not saved)")
            continue
        copies.setdefault(name, []).append(item)

    def first_copy(name: str) -> bytes | None:
        """Download one copy per name (the lowest ID), as the verifier hashes one copy."""
        entries = sorted(copies.get(name, []), key=lambda entry: int(entry["id"]))
        if not entries:
            return None
        data = sentry.download(sentry.url(sentry.project_path(f"events/{event_id}/attachments/{entries[0]['id']}/"),
                                          {"download": "1"}), ALLOWED[name])
        listed_size = entries[0].get("size")
        if isinstance(listed_size, int) and len(data) < listed_size:
            # A short body is an interrupted transfer, not evidence that the stored bytes differ.
            raise Failure(f"{name} downloaded short of its listed size; the transfer was interrupted, try again.")
        if listed_size != len(data):
            problems.append(f"{name}: Sentry listed {listed_size} bytes but served {len(data)}")
        write_private(target / name, data)
        return data

    context = first_copy("context.json")
    descriptors: dict[str, dict] = {}
    if context is None:
        problems.append("context.json is missing from the event")
    else:
        try:
            manifest = strict_json(context)
            for descriptor in manifest.get("attachments", []):
                descriptors[descriptor["name"]] = descriptor
            if str(manifest.get("report_id", "")).lower() != report_id:
                problems.append("context.json report_id does not match the event's report_id tag")
        except (ValueError, KeyError, TypeError, AttributeError):
            problems.append("context.json is not a valid report manifest")
        if any(entry.get("size") != len(context) for entry in copies.get("context.json", [])):
            problems.append("context.json: a duplicate copy has a different size")

    saved: dict[str, bytes] = {}
    for name in ("screenshot.png", "voice.wav"):
        if name not in copies:
            continue
        want = descriptors.get(name, {}).get("bytes")
        if want is not None and any(entry.get("size") != want for entry in copies[name]):
            problems.append(f"{name}: a listed copy's size differs from context.json")
        data = first_copy(name)
        if data is not None:
            saved[name] = data

    message = feedback.get("message") if isinstance(feedback.get("message"), str) else ""
    write_private(target / "feedback-message.txt", (message + "\n").encode("utf-8"))
    summary = {key: event.get(key) for key in ("eventID", "groupID", "dateCreated", "dateReceived", "platform")}
    summary["tags"] = event.get("tags")
    write_private(target / "event.json", (json.dumps(summary, indent=2, sort_keys=True) + "\n").encode("utf-8"))

    for name, descriptor in descriptors.items():
        data = saved.get(name)
        if data is None:
            problems.append(f"{name}: described in context.json but missing from the event")
            continue
        digest = hashlib.sha256(data).hexdigest()
        if descriptor.get("bytes") != len(data) or descriptor.get("sha256") != digest:
            problems.append(f"{name}: bytes or SHA-256 differ from context.json")
        else:
            print(f"{name}: {len(data)} bytes, SHA-256 matches context.json", file=out)
    for name in saved:
        if name not in descriptors:
            problems.append(f"{name}: on the event but not described in context.json")

    print(f"Saved to {target}", file=out)
    if problems:
        for problem in problems:
            print("PROBLEM: " + problem, file=out)
        return 2
    print("Verified: every attachment matches context.json.", file=out)
    return 0


# -- smoke -------------------------------------------------------------------------------

def synthetic_png() -> bytes:
    def chunk(kind: bytes, data: bytes) -> bytes:
        return struct.pack(">I", len(data)) + kind + data + struct.pack(">I", zlib.crc32(kind + data) & 0xFFFFFFFF)
    rows = b"".join(b"\x00" + bytes([200, 40, 40] * 2) for _ in range(2))
    return (b"\x89PNG\r\n\x1a\n" + chunk(b"IHDR", struct.pack(">IIBBBBB", 2, 2, 8, 2, 0, 0, 0))
            + chunk(b"IDAT", zlib.compress(rows)) + chunk(b"IEND", b""))


def synthetic_wav() -> bytes:
    buffer = io.BytesIO()
    with wave.open(buffer, "wb") as output:
        output.setnchannels(1)
        output.setsampwidth(2)
        output.setframerate(16000)
        output.writeframes(b"\x00\x00" * 8000)
    return buffer.getvalue()


def synthetic_report(now: datetime) -> tuple[str, str, dict[str, bytes], bytes]:
    report_id, event_id = str(uuid.uuid4()), uuid.uuid4().hex
    media = {"screenshot.png": synthetic_png(), "voice.wav": synthetic_wav()}
    types = {"screenshot.png": "image/png", "voice.wav": "audio/wav"}
    manifest = {
        "schema_version": 1, "report_id": report_id,
        "created_at": now.strftime("%Y-%m-%dT%H:%M:%SZ"),
        "explanation": "Synthetic smoke report from report_ops.py; safe to delete.",
        "build": {"edition": "preview", "version": "smoke", "build": "smoke", "revision": "unknown",
                  "dirty": None, "kind": "local", "os_version": "smoke", "os_build": "smoke"},
        "context": {"surface": "help", "screenshot": {"width": 2, "height": 2, "scale": 1}},
        "attachments": [{"name": name, "content_type": types[name], "bytes": len(data),
                         "sha256": hashlib.sha256(data).hexdigest()} for name, data in media.items()],
    }
    files = {"context.json": json.dumps(manifest, separators=(",", ":")).encode(), **media}
    return report_id, event_id, files, manifest["explanation"].encode()


def envelope(dsn: str, event_id: str, report_id: str, files: dict[str, bytes], now: datetime) -> bytes:
    stamp = now.strftime("%Y-%m-%dT%H:%M:%S.%fZ")
    event = {
        "event_id": event_id, "timestamp": now.timestamp(), "platform": "other", "level": "info",
        "environment": "preview", "release": "workbench@smoke",
        "tags": {"report_id": report_id, "edition": "preview", "tool": "help", "schema": "1", "build": "smoke"},
        "contexts": {"feedback": {"message": "Synthetic smoke report from report_ops.py; safe to delete."}},
    }
    lines = [json.dumps({"event_id": event_id, "sent_at": stamp, "dsn": dsn}).encode(),
             json.dumps({"type": "feedback"}).encode(), json.dumps(event).encode()]
    types = {"context.json": "application/json", "screenshot.png": "image/png", "voice.wav": "audio/wav"}
    for name, data in files.items():
        lines.append(json.dumps({"type": "attachment", "length": len(data), "filename": name,
                                 "content_type": types[name], "attachment_type": "event.attachment"}).encode())
        lines.append(data)
    return b"\n".join(lines) + b"\n"


def ingest_url(dsn: str) -> tuple[str, str]:
    parts = urllib.parse.urlsplit(dsn)
    project = parts.path.strip("/")
    if parts.scheme != "https" or not parts.username or not ascii_digits(project) or not parts.hostname:
        raise Failure("SENTRY_DSN must look like https://<key>@<host>/<project_id>.")
    port = f":{parts.port}" if parts.port else ""
    return f"https://{parts.hostname}{port}/api/{project}/envelope/", parts.username


def blocked_categories(header: str | None) -> set[str]:
    blocked: set[str] = set()
    for limit in (header or "").split(","):
        fields = limit.strip().split(":")
        if len(fields) >= 2 and fields[0]:
            blocked.update(fields[1].split(";") if fields[1] else {"<all>"})
    return blocked


def smoke(verifier: str, dsn: str, out=sys.stdout, poll_seconds: float = 5, timeout_seconds: float = 180,
          ingest_override: str | None = None) -> int:
    now = datetime.now(timezone.utc)
    report_id, event_id, files, _ = synthetic_report(now)
    url, key = ingest_url(dsn)
    url = ingest_override or url
    body = envelope(dsn, event_id, report_id, files, now)
    request = urllib.request.Request(url, data=body, method="POST", headers={
        "Content-Type": "application/x-sentry-envelope",
        "X-Sentry-Auth": f"Sentry sentry_version=7, sentry_key={key}, sentry_client=workbench-report-smoke/1"})
    try:
        with urllib.request.urlopen(request, timeout=TIMEOUT) as response:
            status, limits = response.status, response.headers.get("X-Sentry-Rate-Limits")
    except urllib.error.HTTPError as error:
        raise Failure(f"Sentry ingest answered {error.code}; nothing was sent.") from None
    except (urllib.error.URLError, OSError) as error:
        raise Failure(f"Could not reach Sentry ingest ({type(error).__name__}).") from None
    blocked = blocked_categories(limits) & {"<all>", "feedback", "attachment", "attachment_item"}
    if status != 200 or blocked:
        raise Failure(f"Sentry ingest did not accept the report (status {status}, limited {sorted(blocked)}).")
    accepted = time.monotonic()
    print(f"Sent synthetic report {report_id} as event {event_id}", file=out)
    attachments = [{"name": name, "size": len(data), "sha256": hashlib.sha256(data).hexdigest()}
                   for name, data in files.items()]
    deadline = accepted + timeout_seconds
    while True:
        # Seconds since Sentry's 200, measured on this machine's monotonic clock.
        check = json.dumps({"event_id": event_id, "report_id": report_id,
                            "elapsed_seconds": int(time.monotonic() - accepted),
                            "attachments": attachments}).encode()
        verify = urllib.request.Request(verifier, data=check, method="POST",
                                        headers={"Content-Type": "application/json"})
        try:
            with urllib.request.urlopen(verify, timeout=TIMEOUT) as response:
                state = json.loads(response.read(4096)).get("state")
        except urllib.error.HTTPError as error:
            state = f"http {error.code}"
        except (urllib.error.URLError, ValueError, AttributeError, *NETWORK_ERRORS) as error:
            # Any non-200 or non-JSON answer (including Vercel's own errors) means try later.
            state = f"unreachable ({type(error).__name__})"
        print(f"verifier: {state}", file=out)
        if state == "received":
            return 0
        if state in ("mismatch", "not_found") or time.monotonic() > deadline:
            return 2
        time.sleep(poll_seconds)


def main(argv: list[str] | None = None, env: dict[str, str] | None = None, out=sys.stdout) -> int:
    parser = argparse.ArgumentParser(description=__doc__.split("\n\n")[0])
    commands = parser.add_subparsers(dest="command", required=True)
    fetch_parser = commands.add_parser("fetch", help="download and verify one report")
    fetch_parser.add_argument("identifier", help="Sentry event ID (32 hex) or report ID (dashed UUID)")
    fetch_parser.add_argument("directory", nargs="?", default=".", help="parent folder for the new report folder")
    fetch_parser.add_argument("--period", default="30d", help="search window for a report ID (default 30d)")
    smoke_parser = commands.add_parser("smoke", help="send a synthetic Preview report and wait for the verifier")
    smoke_parser.add_argument("verifier", help="deployed verify URL, e.g. https://<project>.vercel.app/api/v1/verify")
    args = parser.parse_args(argv)
    environment = dict(os.environ) if env is None else env
    try:
        if args.command == "smoke":
            if not environment.get("SENTRY_DSN"):
                raise Failure("Set SENTRY_DSN to the project's client key DSN.")
            return smoke(args.verifier, environment["SENTRY_DSN"], out)
        sentry = Sentry(environment)
        return fetch(sentry, args.identifier, Path(args.directory), args.period, out)
    except Failure as failure:
        print(f"error: {failure}", file=sys.stderr)
        return 1
    except NETWORK_ERRORS as error:
        print(f"error: the connection to Sentry failed ({type(error).__name__}); try again.", file=sys.stderr)
        return 1


if __name__ == "__main__":
    sys.exit(main())
