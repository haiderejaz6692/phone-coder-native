import contextlib
import importlib
import io
import json
import os
import socket
import tempfile
import threading
import time
import unittest
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer


def event(number, payload):
    return (f"id: {number}\ndata: " + (payload if isinstance(payload, str) else json.dumps(payload, ensure_ascii=False)) + "\n\n").encode()


def completion(text="hello 🌍", ids=(1, 2, 3, 4)):
    return b"".join([
        event(ids[0], {"choices": [{"delta": {"content": text}, "finish_reason": None}]}),
        event(ids[1], {"choices": [{"delta": {}, "finish_reason": "stop"}]}),
        event(ids[2], {"choices": [], "usage": {"prompt_tokens": 8, "completion_tokens": 3, "total_tokens": 11}}),
        event(ids[3], "[DONE]"),
    ])


class Fixture:
    def __init__(self):
        self.key = "a" * 64
        self.records = {}
        self.executions = 0
        self.active = 0
        self.lock = threading.Lock()
        self.cancelled = set()
        self.completed = set()
        self.completion_wins = False
        self.background = False
        self.bad_ids = None
        self.delay = 0
        self.large = False
        self.output_limit = 2048
        self.secret = "PRIVATE_RESPONSE_CANARY"
        fixture = self

        class Handler(BaseHTTPRequestHandler):
            protocol_version = "HTTP/1.1"

            def log_message(self, *_):
                pass

            def send(self, status, body, content_type="application/json"):
                self.send_response(status)
                self.send_header("Content-Type", content_type)
                self.send_header("Content-Length", str(len(body)))
                self.send_header("Cache-Control", "no-store")
                self.send_header("X-Content-Type-Options", "nosniff")
                self.end_headers()
                try:
                    self.wfile.write(body)
                    self.wfile.flush()
                except (BrokenPipeError, ConnectionResetError):
                    pass

            def authorized(self):
                if self.headers.get("Authorization") != "Bearer " + fixture.key:
                    self.send(401, json.dumps({"error": {"code": "unauthorized", "message": fixture.secret}}).encode())
                    return False
                return True

            def do_GET(self):
                if not self.authorized():
                    return
                time.sleep(fixture.delay)
                if fixture.large:
                    self.send(200, b"x" * 10000)
                elif self.path == "/v1/models":
                    self.send(200, json.dumps({"object": "list", "data": [{"id": "private-model-id", "loaded": True, "callable": True, "max_output_tokens": fixture.output_limit}]}).encode())
                else:
                    self.send(200, json.dumps({"ready": True, "api_version": "phone-coder-api/1", "model": "private-model-id", "session_id": "private-session-id", "thermal": "nominal", "memory_available_bytes": 123456}).encode())

            def do_DELETE(self):
                if not self.authorized():
                    return
                rid = self.headers.get("X-Phone-Coder-Request-ID")
                with fixture.lock:
                    changed = rid not in fixture.cancelled and rid not in fixture.completed
                    if changed:
                        fixture.cancelled.add(rid)
                self.send(200, json.dumps({"id": rid, "cancelled": changed}).encode())

            def do_POST(self):
                if not self.authorized():
                    return
                body = self.rfile.read(int(self.headers["Content-Length"]))
                raw = json.loads(body)
                if raw.get("max_tokens", 0) > fixture.output_limit:
                    self.send(400, b'{"error":{"code":"output_tokens_exceeded"}}')
                    return
                rid = self.headers["X-Phone-Coder-Request-ID"]
                after = int(self.headers.get("Last-Event-ID", "0"))
                with fixture.lock:
                    if rid not in fixture.records:
                        if fixture.active >= 5:
                            self.send(429, b'{"error":{"code":"queue_full"}}')
                            return
                        fixture.records[rid] = body
                        fixture.executions += 1
                    elif fixture.records[rid] != body:
                        self.send(409, b'{"error":{"code":"request_conflict"}}')
                        return
                    fixture.active += 1
                try:
                    if not raw["stream"]:
                        self.send(200, json.dumps({"choices": [{"message": {"content": fixture.secret}, "finish_reason": "stop"}], "usage": {"prompt_tokens": 8, "completion_tokens": 3, "total_tokens": 11}}).encode())
                        return
                    self.send_response(200)
                    self.send_header("Content-Type", "text/event-stream")
                    self.send_header("Connection", "close")
                    self.send_header("Cache-Control", "no-store")
                    self.send_header("X-Content-Type-Options", "nosniff")
                    self.end_headers()
                    self.close_connection = True
                    if fixture.bad_ids:
                        data = completion(ids=fixture.bad_ids)
                    else:
                        text = "hello 🌍" if "🌍" in body.decode() else fixture.secret
                        data = completion(text)
                    parts = data.split(b"\n\n")[:-1]
                    if fixture.completion_wins:
                        with fixture.lock:
                            fixture.completed.add(rid)
                    for part in parts:
                        number = int(part.split(b"\n", 1)[0][4:])
                        if number <= after:
                            continue
                        if number > 1:
                            time.sleep(0.03)
                        with fixture.lock:
                            cancelled = rid in fixture.cancelled
                        if not fixture.completion_wins and (cancelled or fixture.background):
                            code = "request_cancelled" if cancelled else "background_interrupted"
                            self.wfile.write(event(number, {"error": {"code": code, "message": fixture.secret}}) + event(number + 1, "[DONE]"))
                            self.wfile.flush()
                            return
                        # Split every multibyte code point across transport writes.
                        for byte in part + b"\n\n":
                            self.wfile.write(bytes([byte]))
                        self.wfile.flush()
                except (BrokenPipeError, ConnectionResetError):
                    pass
                finally:
                    with fixture.lock:
                        fixture.active -= 1

        self.server = ThreadingHTTPServer(("127.0.0.1", 0), Handler)
        self.thread = threading.Thread(target=self.server.serve_forever, daemon=True)

    def __enter__(self):
        self.thread.start()
        return self

    def __exit__(self, *_):
        self.server.shutdown()
        self.server.server_close()
        self.thread.join()

    @property
    def url(self):
        return f"http://127.0.0.1:{self.server.server_port}"


class ProbeTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.probe = importlib.import_module("scripts.qualification.native_server_probe")

    def client(self, fixture, **kwargs):
        return self.probe.Client(fixture.url, fixture.key, **kwargs)

    def test_twenty_sequential_completions_and_summary_redaction(self):
        with Fixture() as f:
            result = self.probe.Probe(self.client(f)).run(["sequential", "unauthorized"])
            self.assertEqual(result["status"], "PASS")
            self.assertEqual(result["scenarios"][0]["completed"], 20)
            self.assertEqual(f.executions, 20)
            encoded = json.dumps(result)
            for private in (f.key, f.secret, "private-model-id", "private-session-id", "messages", "content"):
                self.assertNotIn(private, encoded)

    def test_cancel_is_idempotent_and_stream_ends_once(self):
        with Fixture() as f:
            result = self.probe.Probe(self.client(f)).run(["cancel"])
            self.assertEqual(result["status"], "PASS", result)
            self.assertEqual(f.executions, 1)

    def test_normal_completion_before_delete_is_blocked_and_other_checks_continue(self):
        with Fixture() as f:
            f.completion_wins = True
            result = self.probe.Probe(self.client(f)).run(["cancel", "unauthorized"])
            self.assertEqual(result["status"], "BLOCKED", result)
            self.assertEqual(result["scenarios"][0]["category"], "completion_won_race")
            self.assertEqual(result["scenarios"][1]["status"], "PASS")
            self.assertEqual(self.probe.exit_code(result), 2)

    def test_disconnect_reattaches_exact_body_and_replay_matches(self):
        with Fixture() as f:
            result = self.probe.Probe(self.client(f)).run(["reattach"])
            self.assertEqual(result["status"], "PASS", result)
            self.assertEqual(f.executions, 1)

    def test_unicode_split_bytes_have_one_intact_marker(self):
        with Fixture() as f:
            result = self.probe.Probe(self.client(f)).run(["unicode"])
            self.assertEqual(result["status"], "PASS", result)

    def test_queue_pressure_requires_explicit_queue_full(self):
        with Fixture() as f:
            result = self.probe.Probe(self.client(f)).run(["queue"])
            self.assertEqual(result["status"], "PASS", result)
            self.assertGreaterEqual(result["scenarios"][0]["rejected"], 1)

    def test_probe_respects_small_models_effective_output_limit(self):
        with Fixture() as f:
            f.output_limit = 128
            result = self.probe.Probe(self.client(f)).run(["cancel", "queue"])
            self.assertEqual(result["status"], "PASS", result)

    def test_background_checkpoint_requires_terminal_then_fresh_request(self):
        with Fixture() as f:
            def checkpoint(stage):
                f.background = stage == "background"
            result = self.probe.Probe(self.client(f), checkpoint=checkpoint).run(["background"])
            self.assertEqual(result["status"], "PASS", result)
            self.assertEqual(f.executions, 2)

    def test_normal_completion_before_background_returns_foreground_and_checks_fresh_request(self):
        with Fixture() as f:
            f.completion_wins = True
            stages = []
            def checkpoint(stage):
                stages.append(stage)
                f.background = stage == "background"
            result = self.probe.Probe(self.client(f), checkpoint=checkpoint).run(["background"])
            self.assertEqual(result["status"], "BLOCKED", result)
            self.assertEqual(result["scenarios"][0]["category"], "completion_won_race")
            self.assertEqual(stages, ["background", "foreground"])
            self.assertEqual(f.executions, 2)
            self.assertEqual(self.probe.exit_code(result), 2)

    def test_malformed_background_stream_still_restores_foreground_and_checks_fresh_request(self):
        with Fixture() as f:
            f.completion_wins = True
            f.bad_ids = (1, 1, 2, 3)
            stages = []
            def checkpoint(stage):
                stages.append(stage)
                if stage == "foreground":
                    f.bad_ids = None
            result = self.probe.Probe(self.client(f), checkpoint=checkpoint).run(["background"])
            self.assertEqual(result["status"], "FAIL", result)
            self.assertEqual(result["scenarios"][0]["category"], "duplicate_event")
            self.assertEqual(stages, ["background", "foreground"])
            self.assertEqual(f.executions, 2)

    def test_manual_scenarios_are_not_run_without_checkpoints(self):
        with Fixture() as f:
            result = self.probe.Probe(self.client(f)).run(["background", "rotation"])
            self.assertEqual(result["status"], "NOT RUN")
            self.assertEqual(self.probe.exit_code(result), 2)
            self.assertEqual(f.executions, 0)

    def test_rotation_verifies_old_key_rejected_and_new_key_works(self):
        with Fixture() as f:
            def rotate(_):
                f.key = "b" * 64
                return f.key
            result = self.probe.Probe(self.client(f), checkpoint=rotate).run(["rotation"])
            self.assertEqual(result["status"], "PASS", result)
            self.assertNotIn(f.key, json.dumps(result))

    def test_duplicate_missing_and_out_of_order_events_fail(self):
        for ids, category in [((1, 1, 2, 3), "duplicate_event"), ((1, 3, 4, 5), "missing_event"), ((1, 2, 1, 3), "out_of_order_event")]:
            with self.subTest(ids=ids), Fixture() as f:
                f.bad_ids = ids
                result = self.probe.Probe(self.client(f)).run(["unicode"])
                self.assertEqual(result["status"], "FAIL")
                self.assertEqual(result["scenarios"][0]["category"], category)
                self.assertEqual(self.probe.exit_code(result), 1)

    def test_parser_rejects_invalid_utf8_unterminated_or_oversized_events(self):
        for data, category in [(b"id: 1\ndata: \xff\n\n", "invalid_utf8"), (b"id: 1\ndata: {}", "truncated_stream"), (b"x" * 100, "response_limit")]:
            with self.subTest(category=category):
                parser = self.probe.SSEParser(max_bytes=64)
                with self.assertRaises(self.probe.ProbeError) as caught:
                    list(parser.feed(data))
                    parser.finish()
                self.assertEqual(caught.exception.category, category)

    def test_timeouts_and_response_bounds_are_redacted(self):
        with Fixture() as f:
            f.delay = 0.1
            with self.assertRaises(self.probe.ProbeError) as caught:
                self.client(f, timeout=0.02).json("GET", "/health")
            self.assertEqual(caught.exception.category, "timeout")
        with Fixture() as f:
            f.large = True
            with self.assertRaises(self.probe.ProbeError) as caught:
                self.client(f, max_bytes=128).json("GET", "/health")
            self.assertEqual(caught.exception.category, "response_limit")

    def test_url_gate_rejects_public_lan_userinfo_redirects_and_dns_names(self):
        for url in ("http://192.168.1.2:11434", "https://example.com", "http://100.64.1.2@8.8.8.8", "http://localhost.evil", "http://127.0.0.1/a", "http://100.64.1.2?key=secret"):
            with self.subTest(url=url), self.assertRaises(self.probe.ProbeError):
                self.probe.Client(url, "a" * 64)
        for url in ("http://127.0.0.1:11434", "http://100.127.255.254", "http://[fd7a:115c:a1e0::1]:11434"):
            self.probe.Client(url, "a" * 64)

    def test_cli_errors_never_echo_sensitive_args_or_exception_text(self):
        output = io.StringIO()
        with contextlib.redirect_stdout(output), contextlib.redirect_stderr(output):
            status = self.probe.main(["--base-url", "http://public.example/PRIVATE_URL_CANARY", "--key", "PRIVATE_KEY_CANARY"])
        self.assertEqual(status, 2)
        self.assertNotIn("PRIVATE", output.getvalue())

    def test_terminal_rejects_text_after_done_and_missing_usage(self):
        result = self.probe.StreamResult()
        result.consume(1, {"choices": [{"delta": {}, "finish_reason": "stop"}]})
        result.consume(2, None)
        with self.assertRaises(self.probe.ProbeError) as caught:
            result.consume(3, {"choices": [{"delta": {"content": "private"}}]})
        self.assertEqual(caught.exception.category, "event_after_done")
        with self.assertRaises(self.probe.ProbeError) as caught:
            result.validate()
        self.assertEqual(caught.exception.category, "missing_usage")

    def test_stream_rejects_unknown_finish_and_post_terminal_deltas_before_done(self):
        finish = {"choices": [{"delta": {}, "finish_reason": "stop"}]}
        error = {"error": {"code": "request_cancelled"}}
        for events, category in [
            ([{"choices": [{"delta": {}, "finish_reason": "arbitrary"}]}], "invalid_finish_reason"),
            ([{"choices": [{"delta": {}, "finish_reason": "tool_calls"}]}], "invalid_finish_reason"),
            ([finish, {"choices": [{"delta": {"content": "late"}}]}], "event_after_terminal"),
            ([finish, {"choices": [{"delta": {"role": "assistant"}}]}], "event_after_terminal"),
            ([error, {"choices": [{"delta": {"content": "late"}}]}], "event_after_terminal"),
            ([error, {"choices": [], "usage": {"prompt_tokens": 1, "completion_tokens": 1, "total_tokens": 2}}], "event_after_terminal"),
            ([finish, error], "duplicate_terminal"),
        ]:
            with self.subTest(category=category):
                result = self.probe.StreamResult()
                with self.assertRaises(self.probe.ProbeError) as caught:
                    for number, value in enumerate(events, 1):
                        result.consume(number, value)
                self.assertEqual(caught.exception.category, category)

    def test_usage_requires_coherent_integer_counts_after_one_finish(self):
        for usage in [
            {"prompt_tokens": 1, "completion_tokens": 2},
            {"prompt_tokens": 1, "completion_tokens": 2, "total_tokens": 4},
            {"prompt_tokens": True, "completion_tokens": 2, "total_tokens": 3},
            {"prompt_tokens": -1, "completion_tokens": 2, "total_tokens": 1},
            {"prompt_tokens": 1, "completion_tokens": 2.0, "total_tokens": 3},
            {"prompt_tokens": 1, "completion_tokens": 2, "total_tokens": "3"},
        ]:
            with self.subTest(usage=usage):
                result = self.probe.StreamResult()
                result.consume(1, {"choices": [{"delta": {}, "finish_reason": "length"}]})
                with self.assertRaises(self.probe.ProbeError) as caught:
                    result.consume(2, {"choices": [], "usage": usage})
                self.assertEqual(caught.exception.category, "invalid_usage")
        valid = {"choices": [], "usage": {"prompt_tokens": 1, "completion_tokens": 2, "total_tokens": 3}}
        result = self.probe.StreamResult()
        with self.assertRaises(self.probe.ProbeError) as caught:
            result.consume(1, valid)
        self.assertEqual(caught.exception.category, "invalid_usage_order")
        result = self.probe.StreamResult()
        result.consume(1, {"choices": [{"delta": {}, "finish_reason": "stop"}]})
        result.consume(2, valid)
        with self.assertRaises(self.probe.ProbeError) as caught:
            result.consume(3, valid)
        self.assertEqual(caught.exception.category, "duplicate_usage")

    def test_fail_takes_precedence_over_blocked_when_aggregating_scenarios(self):
        with Fixture() as f:
            f.completion_wins = True
            result = self.probe.Probe(self.client(f), checkpoint=lambda _: f.key).run(["cancel", "rotation"])
            self.assertEqual(result["scenarios"][0]["status"], "BLOCKED")
            self.assertEqual(result["status"], "FAIL")
            self.assertEqual(self.probe.exit_code(result), 1)

    def test_total_deadline_interrupts_trickling_response_headers(self):
        listener = socket.socket()
        listener.bind(("127.0.0.1", 0))
        listener.listen()
        stop = threading.Event()
        def trickle():
            connection, _ = listener.accept()
            with connection:
                connection.recv(4096)
                try:
                    for byte in b"HTTP/1.1 200 OK\r\nContent-Type: application/json\r\n\r\n{}":
                        connection.sendall(bytes([byte]))
                        if stop.wait(0.01):
                            break
                except OSError:
                    pass
        worker = threading.Thread(target=trickle, daemon=True)
        worker.start()
        started = time.monotonic()
        try:
            client = self.probe.Client(f"http://127.0.0.1:{listener.getsockname()[1]}", "a" * 64, timeout=0.05)
            with self.assertRaises(self.probe.ProbeError) as caught:
                client.json("GET", "/health")
            self.assertEqual(caught.exception.category, "timeout")
            self.assertLess(time.monotonic() - started, 0.3)
        finally:
            stop.set()
            listener.close()
            worker.join(timeout=1)

    def test_cli_writes_owner_only_summary_and_never_overwrites(self):
        with Fixture() as f, tempfile.TemporaryDirectory() as directory:
            path = os.path.join(directory, "summary.json")
            args = ["--base-url", f.url, "--key", f.key, "--scenarios", "unauthorized", "--output", path]
            output = io.StringIO()
            with contextlib.redirect_stdout(output), contextlib.redirect_stderr(output):
                self.assertEqual(self.probe.main(args), 0)
                with open(path, encoding="utf-8") as saved:
                    first = saved.read()
                self.assertEqual(self.probe.main(args), 2)
            self.assertEqual(os.stat(path).st_mode & 0o777, 0o600)
            with open(path, encoding="utf-8") as saved:
                self.assertEqual(saved.read(), first)
            self.assertNotIn(f.key, output.getvalue())
            self.assertNotIn(f.secret, first)


if __name__ == "__main__":
    unittest.main()
