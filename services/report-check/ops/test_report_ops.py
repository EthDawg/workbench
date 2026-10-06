#!/usr/bin/env python3
"""report_ops fetch against local stand-ins for Sentry's API and attachment storage."""
from __future__ import annotations

import hashlib
import io
import json
import os
import sys
import tempfile
import threading
import time
import unittest
import uuid
from contextlib import redirect_stderr
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path
from urllib.parse import parse_qs, urlsplit

sys.path.insert(0, str(Path(__file__).resolve().parent))
import report_ops  # noqa: E402

TOKEN = "sntryu_synthetic_ops_token_0123456789"


class FakeSentry:
    """Routes for the API origin and a second, cross-origin storage server."""

    def __init__(self):
        self.events: dict[str, dict] = {}
        self.attachments: dict[str, list[dict]] = {}
        self.seen: list[tuple[str, str, str | None]] = []
        self.page_size = 100
        self.storage_mode = "ok"  # or "truncated" / "slow"
        self.api = self._serve("api")
        self.storage = self._serve("storage")

    def _serve(self, role: str) -> ThreadingHTTPServer:
        fake = self

        class Handler(BaseHTTPRequestHandler):
            def log_message(self, *args):
                pass

            def do_GET(self):
                fake.seen.append((role, self.path, self.headers.get("Authorization")))
                status, headers, body = fake.route(role, self.path, self.headers.get("Authorization"))
                if role == "storage" and fake.storage_mode == "slow":
                    time.sleep(1.0)
                self.send_response(status)
                for key, value in headers.items():
                    self.send_header(key, value)
                truncated = role == "storage" and fake.storage_mode == "truncated"
                self.send_header("Content-Length", str(len(body)))
                self.end_headers()
                # A dropped connection: the declared length is never delivered.
                self.wfile.write(body[:-50] if truncated else body)
                if truncated:
                    self.close_connection = True

        server = ThreadingHTTPServer(("127.0.0.1", 0), Handler)
        threading.Thread(target=server.serve_forever, daemon=True).start()
        return server

    def origin(self, server: ThreadingHTTPServer) -> str:
        return f"http://127.0.0.1:{server.server_address[1]}"

    def close(self):
        for server in (self.api, self.storage):
            server.shutdown()
            server.server_close()

    def route(self, role: str, path: str, auth: str | None):
        url = urlsplit(path)
        query = parse_qs(url.query)
        if role == "storage":
            item = self._attachment(url.path.rsplit("/", 1)[-1])
            return (200, {}, item["bytes"]) if item else (404, {}, b"")
        if auth != f"Bearer {TOKEN}":
            return 401, {}, b"{}"
        parts = [part for part in url.path.split("/") if part]
        if parts[:4] == ["api", "0", "projects", "workbench-dp"] and parts[4:] == ["workbench-reports"]:
            return self._json({"id": "4512211067011072", "slug": "workbench-reports"})
        if parts[:5] == ["api", "0", "organizations", "workbench-dp", "issues"] and len(parts) == 5:
            report = query["query"][0].split("report_id:")[1]
            return self._json([{"id": str(1000 + index)} for index, (event_id, event) in enumerate(self.events.items())
                               if {"key": "report_id", "value": report} in event["tags"]])
        if parts[:5] == ["api", "0", "organizations", "workbench-dp", "issues"] and parts[6:] == ["events", "latest"]:
            event_id = list(self.events)[int(parts[5]) - 1000]
            return self._json({"eventID": event_id})
        if parts[:5] != ["api", "0", "projects", "workbench-dp", "workbench-reports"] or parts[5] != "events":
            return 404, {}, b"{}"
        event = self.events.get(parts[6])
        if not event:
            return 404, {}, b"{}"
        if len(parts) == 7:
            return self._json(event)
        items = sorted(self.attachments.get(parts[6], []), key=lambda item: item["name"])
        if len(parts) == 8:
            offset = int(query.get("cursor", ["0"])[0])
            page = items[offset:offset + self.page_size]
            more = "true" if offset + self.page_size < len(items) else "false"
            link = (f'<{self.origin(self.api)}{url.path}?per_page=100&cursor={offset + self.page_size}>; '
                    f'rel="next"; results="{more}"; cursor="x"')
            return self._json([{"id": item["id"], "name": item["name"], "size": len(item["bytes"])} for item in page],
                              {"Link": link})
        item = self._attachment(parts[8])
        if not item or "download" not in query:
            return 404, {}, b"{}"
        return 302, {"Location": f"{self.origin(self.storage)}/v1/objects/{item['id']}?os_auth=presigned"}, b""

    def _attachment(self, attachment_id: str):
        for items in self.attachments.values():
            for item in items:
                if item["id"] == attachment_id:
                    return item
        return None

    @staticmethod
    def _json(body, headers=None):
        return 200, {"Content-Type": "application/json", **(headers or {})}, json.dumps(body).encode()

    def add_report(self, *, tamper: bool = False, extra: str | None = None, copies: int = 1,
                   upper_tag: bool = False):
        report_id = str(uuid.uuid4())
        event_id = uuid.uuid4().hex
        png, wav = os.urandom(5000), os.urandom(3000)
        manifest = {"schema_version": 1, "report_id": report_id, "explanation": "synthetic",
                    "attachments": [
                        {"name": "screenshot.png", "content_type": "image/png", "bytes": len(png),
                         "sha256": hashlib.sha256(png).hexdigest()},
                        {"name": "voice.wav", "content_type": "audio/wav", "bytes": len(wav),
                         "sha256": hashlib.sha256(wav).hexdigest()}]}
        if tamper:
            wav = wav[:-1] + bytes([wav[-1] ^ 1])
        files = [("context.json", json.dumps(manifest).encode()), ("screenshot.png", png), ("voice.wav", wav)]
        if extra:
            files.append((extra, b"surprise"))
        tag_value = report_id.upper() if upper_tag else report_id
        self.events[event_id] = {"eventID": event_id, "contexts": {"feedback": {"message": "The Snap window vanished"}},
                                 "tags": [{"key": "report_id", "value": tag_value}]}
        self.attachments[event_id] = [{"id": str(abs(hash((event_id, name, copy))) % 10**9), "name": name, "bytes": data}
                                      for copy in range(copies) for name, data in files]
        return report_id, event_id


class FetchTests(unittest.TestCase):
    def setUp(self):
        self.fake = FakeSentry()
        self.temp = tempfile.TemporaryDirectory()
        self.env = {"SENTRY_READ_TOKEN": TOKEN, "SENTRY_API_BASE": self.fake.origin(self.fake.api)}

    def tearDown(self):
        self.fake.close()
        self.temp.cleanup()

    def run_fetch(self, identifier: str):
        out, err = io.StringIO(), io.StringIO()
        with redirect_stderr(err):
            code = report_ops.main(["fetch", identifier, self.temp.name], self.env, out)
        return code, out.getvalue(), err.getvalue()

    def test_fetch_by_event_id_verifies_and_keeps_token_off_storage(self):
        report_id, event_id = self.fake.add_report()
        self.fake.page_size = 1
        code, out, err = self.run_fetch(event_id)
        self.assertEqual(code, 0, out + err)
        folder = Path(self.temp.name) / f"workbench-report-{report_id}"
        self.assertEqual(sorted(path.name for path in folder.iterdir()),
                         ["context.json", "event.json", "feedback-message.txt", "screenshot.png", "voice.wav"])
        self.assertEqual((folder / "feedback-message.txt").read_text(), "The Snap window vanished\n")
        self.assertEqual(oct(folder.stat().st_mode & 0o777), "0o700")
        self.assertEqual(oct((folder / "voice.wav").stat().st_mode & 0o777), "0o600")
        storage = [auth for role, _, auth in self.fake.seen if role == "storage"]
        api = [auth for role, _, auth in self.fake.seen if role == "api"]
        self.assertEqual(len(storage), 3)
        self.assertTrue(all(auth is None for auth in storage))
        self.assertTrue(all(auth == f"Bearer {TOKEN}" for auth in api))
        self.assertNotIn(TOKEN, out + err)

    def test_fetch_by_report_id(self):
        report_id, _ = self.fake.add_report()
        self.fake.add_report()
        code, out, err = self.run_fetch(report_id)
        self.assertEqual(code, 0, out + err)
        self.assertIn("Verified", out)

    def test_hash_mismatch_is_reported(self):
        _, event_id = self.fake.add_report(tamper=True)
        code, out, _ = self.run_fetch(event_id)
        self.assertEqual(code, 2)
        self.assertIn("voice.wav: bytes or SHA-256 differ", out)

    def test_unexpected_attachment_is_not_written(self):
        report_id, event_id = self.fake.add_report(extra="../escape.sh")
        code, out, _ = self.run_fetch(event_id)
        self.assertEqual(code, 2)
        self.assertIn("unexpected attachment", out)
        self.assertFalse((Path(self.temp.name) / "escape.sh").exists())
        self.assertFalse((Path(self.temp.name) / f"workbench-report-{report_id}" / "escape.sh").exists())

    def test_one_copy_per_name_is_downloaded(self):
        report_id, event_id = self.fake.add_report(copies=4, upper_tag=True)
        code, out, err = self.run_fetch(event_id)
        self.assertEqual(code, 0, out + err)
        self.assertEqual(len([1 for role, _, _ in self.fake.seen if role == "storage"]), 3)
        self.assertTrue((Path(self.temp.name) / f"workbench-report-{report_id}").is_dir())

    def test_duplicate_with_different_listed_size_is_a_problem(self):
        _, event_id = self.fake.add_report(copies=2)
        self.fake.attachments[event_id][-1]["bytes"] += b"x"
        code, out, _ = self.run_fetch(event_id)
        self.assertEqual(code, 2)
        self.assertIn("a listed copy's size differs", out)

    def test_non_ascii_digit_ids_are_not_downloaded(self):
        _, event_id = self.fake.add_report()
        self.fake.attachments[event_id].append({"id": "\u0661\u0662", "name": "voice.wav", "bytes": b"x"})
        code, out, _ = self.run_fetch(event_id)
        self.assertEqual(code, 2)
        self.assertIn("unexpected attachment", out)
        self.assertFalse(any("\u0661" in path for _, path, _ in self.fake.seen))

    def test_interrupted_download_is_an_error_and_leaves_no_folder(self):
        report_id, event_id = self.fake.add_report()
        self.fake.storage_mode = "truncated"
        code, out, err = self.run_fetch(event_id)
        self.assertEqual(code, 1, out + err)
        self.assertTrue(err.startswith("error: "), err)
        self.assertNotIn("Traceback", err)
        self.assertFalse((Path(self.temp.name) / f"workbench-report-{report_id}").exists())

    def test_read_timeout_is_an_error_and_leaves_no_folder(self):
        report_id, event_id = self.fake.add_report()
        self.fake.storage_mode = "slow"
        original = report_ops.TIMEOUT
        report_ops.TIMEOUT = 0.3
        try:
            code, out, err = self.run_fetch(event_id)
        finally:
            report_ops.TIMEOUT = original
        self.assertEqual(code, 1, out + err)
        self.assertTrue(err.startswith("error: "), err)
        self.assertFalse((Path(self.temp.name) / f"workbench-report-{report_id}").exists())

    def test_refuses_existing_folder_and_missing_token(self):
        report_id, event_id = self.fake.add_report()
        (Path(self.temp.name) / f"workbench-report-{report_id}").mkdir()
        code, _, err = self.run_fetch(event_id)
        self.assertEqual(code, 1)
        self.assertIn("already exists", err)
        self.env = {"SENTRY_API_BASE": self.fake.origin(self.fake.api)}
        code, _, err = self.run_fetch(event_id)
        self.assertEqual(code, 1)
        self.assertIn("SENTRY_READ_TOKEN", err)

    def test_rejects_plain_http_api_base_and_bad_identifiers(self):
        self.env["SENTRY_API_BASE"] = "http://sentry.example"
        self.assertEqual(self.run_fetch(uuid.uuid4().hex)[0], 1)
        self.env["SENTRY_API_BASE"] = self.fake.origin(self.fake.api)
        self.assertEqual(self.run_fetch("not-an-id")[0], 1)
        self.assertEqual(self.run_fetch(uuid.uuid4().hex)[0], 1)  # unknown event


class SmokeTests(unittest.TestCase):
    """smoke against a local ingest stand-in and a scripted verifier; no live calls."""

    def setUp(self):
        self.envelopes: list[tuple[dict, bytes]] = []
        self.checks: list[dict] = []
        self.states = ["pending", "pending", "received"]
        self.limits: str | None = None
        test = self

        class Handler(BaseHTTPRequestHandler):
            def log_message(self, *args):
                pass

            def do_POST(self):
                body = self.rfile.read(int(self.headers["Content-Length"]))
                if self.path.endswith("/envelope/"):
                    test.envelopes.append((dict(self.headers), body))
                    reply = json.dumps({"id": "x"}).encode()
                    self.send_response(200)
                    if test.limits:
                        self.send_header("X-Sentry-Rate-Limits", test.limits)
                else:
                    test.checks.append(json.loads(body))
                    reply = json.dumps({"state": test.states.pop(0), "checked_at": "2026-10-07T00:00:00Z"}).encode()
                    self.send_response(200)
                self.send_header("Content-Length", str(len(reply)))
                self.end_headers()
                self.wfile.write(reply)

        self.server = ThreadingHTTPServer(("127.0.0.1", 0), Handler)
        threading.Thread(target=self.server.serve_forever, daemon=True).start()
        self.base = f"http://127.0.0.1:{self.server.server_address[1]}"

    def tearDown(self):
        self.server.shutdown()
        self.server.server_close()

    def run_smoke(self):
        out = io.StringIO()
        code = report_ops.smoke(self.base + "/api/v1/verify", "https://publickey@o1.ingest.us.sentry.io/42", out,
                                poll_seconds=0, timeout_seconds=5, ingest_override=self.base + "/api/42/envelope/")
        return code, out.getvalue()

    def test_envelope_matches_the_app_contract_and_polls_to_received(self):
        code, out = self.run_smoke()
        self.assertEqual(code, 0, out)
        headers, body = self.envelopes[0]
        self.assertIn("sentry_key=publickey", headers["X-Sentry-Auth"])
        header, rest = body.split(b"\n", 1)
        envelope_header = json.loads(header)
        item_header, rest = rest.split(b"\n", 1)
        self.assertEqual(json.loads(item_header), {"type": "feedback"})
        payload, rest = rest.split(b"\n", 1)
        event = json.loads(payload)
        self.assertEqual(event["event_id"], envelope_header["event_id"])
        self.assertEqual(event["environment"], "preview")
        attachments = {}
        while rest:
            item_header, rest = rest.split(b"\n", 1)
            item = json.loads(item_header)
            attachments[item["filename"]] = rest[:item["length"]]
            self.assertEqual(item["attachment_type"], "event.attachment")
            rest = rest[item["length"] + 1:]
        self.assertEqual(sorted(attachments), ["context.json", "screenshot.png", "voice.wav"])
        manifest = json.loads(attachments["context.json"])
        self.assertEqual(manifest["report_id"], event["tags"]["report_id"])
        check = self.checks[0]
        self.assertEqual(check["event_id"], event["event_id"])
        self.assertNotIn("sent_at", check)
        self.assertIsInstance(check["elapsed_seconds"], int)
        self.assertTrue(0 <= check["elapsed_seconds"] < 5)
        self.assertEqual({a["name"]: a["sha256"] for a in check["attachments"]},
                         {name: hashlib.sha256(data).hexdigest() for name, data in attachments.items()})
        self.assertEqual(len(self.checks), 3)

    def test_rate_limited_ingest_is_not_sent(self):
        self.limits = "60:feedback;attachment:key"
        with self.assertRaises(report_ops.Failure):
            self.run_smoke()
        self.assertEqual(self.checks, [])

    def test_blocked_categories(self):
        self.assertEqual(report_ops.blocked_categories(None), set())
        self.assertEqual(report_ops.blocked_categories("60::organization"), {"<all>"})
        self.assertEqual(report_ops.blocked_categories("60:error;transaction:key, 10:feedback:project"),
                         {"error", "transaction", "feedback"})


if __name__ == "__main__":
    unittest.main()
