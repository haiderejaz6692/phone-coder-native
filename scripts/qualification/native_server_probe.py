#!/usr/bin/env python3
"""Bounded, metadata-only qualification client for phone-coder-api/1."""

import argparse
import concurrent.futures
import getpass
import hashlib
import http.client
import ipaddress
import json
import os
import socket
import sys
import threading
import time
import uuid
from urllib.parse import urlsplit


SCENARIOS = ("sequential", "unauthorized", "cancel", "reattach", "queue", "unicode", "background", "rotation")
ERROR_CODES = frozenset(("unauthorized", "request_cancelled", "background_interrupted", "session_ended", "stale_session", "request_conflict", "replay_expired", "queue_full", "subscriber_limit", "model_unavailable", "model_switching", "memory_pressure", "thermal_limit", "runtime_occupied", "runtime_failure", "deadline_exceeded", "output_limit", "context_length_exceeded", "output_tokens_exceeded", "request_timeout", "connection_closed", "invalid_request", "invalid_tool_output"))


class ProbeError(Exception):
    """Only fixed categories cross the reporting boundary."""

    def __init__(self, category, status=None):
        self.category = category
        self.status = status
        super().__init__(category)


def error_code(value):
    code = value.get("error", {}).get("code") if isinstance(value, dict) else None
    return code if code in ERROR_CODES else "server_error"


class SSEParser:
    """Incremental byte framing keeps split UTF-8 intact; no payload is logged."""

    def __init__(self, after=0, max_bytes=2_097_152, max_events=4096):
        self.buffer = b""
        self.bytes = 0
        self.last = after
        self.events = 0
        self.max_bytes = max_bytes
        self.max_events = max_events

    def feed(self, chunk):
        self.bytes += len(chunk)
        if self.bytes > self.max_bytes:
            raise ProbeError("response_limit")
        self.buffer += chunk
        # The server emits LF; CRLF is accepted without decoding partial bytes.
        while True:
            lf = self.buffer.find(b"\n\n")
            crlf = self.buffer.find(b"\r\n\r\n")
            boundaries = [(pos, size) for pos, size in ((lf, 2), (crlf, 4)) if pos >= 0]
            if not boundaries:
                return
            index, width = min(boundaries)
            frame, self.buffer = self.buffer[:index], self.buffer[index + width:]
            try:
                lines = frame.decode("utf-8", errors="strict").splitlines()
            except UnicodeError:
                raise ProbeError("invalid_utf8") from None
            fields = {}
            for line in lines:
                if not line or line.startswith(":"):
                    continue
                key, separator, value = line.partition(":")
                if not separator or key not in ("id", "data", "event") or key in fields:
                    raise ProbeError("invalid_event")
                fields[key] = value.removeprefix(" ")
            if not fields:
                continue
            raw_id = fields.get("id", "")
            if not raw_id.isascii() or not raw_id.isdecimal() or len(raw_id) > 12:
                raise ProbeError("invalid_event_id")
            number = int(raw_id)
            if number == self.last:
                raise ProbeError("duplicate_event")
            if number < self.last:
                raise ProbeError("out_of_order_event")
            if number != self.last + 1:
                raise ProbeError("missing_event")
            self.events += 1
            if self.events > self.max_events:
                raise ProbeError("event_limit")
            self.last = number
            if "data" not in fields:
                raise ProbeError("invalid_event")
            raw = fields["data"]
            if raw == "[DONE]":
                yield number, None
            else:
                try:
                    payload = json.loads(raw)
                except (ValueError, RecursionError):
                    raise ProbeError("invalid_json") from None
                if not isinstance(payload, dict):
                    raise ProbeError("invalid_event")
                yield number, payload

    def finish(self):
        if self.buffer.strip():
            raise ProbeError("truncated_stream")


class StreamResult:
    def __init__(self):
        self.events = 0
        self.last = 0
        self.done = 0
        self.finishes = 0
        self.category = None
        self.input_tokens = 0
        self.output_tokens = 0
        self.digest = hashlib.sha256()
        self.marker_count = 0
        self.marker_tail = ""
        self.has_usage = False

    def consume(self, number, value):
        if self.done:
            raise ProbeError("event_after_done")
        self.events += 1
        self.last = number
        if value is None:
            self.done += 1
            return
        if "error" in value:
            if self.category is not None:
                raise ProbeError("duplicate_terminal")
            self.category = error_code(value)
        choices = value.get("choices", [])
        if not isinstance(choices, list):
            raise ProbeError("invalid_event")
        for choice in choices:
            if not isinstance(choice, dict):
                raise ProbeError("invalid_event")
            delta = choice.get("delta", {})
            text = delta.get("content", "") if isinstance(delta, dict) else ""
            if not isinstance(text, str):
                raise ProbeError("invalid_event")
            self.digest.update(text.encode("utf-8"))
            marker = "hello 🌍"
            combined = self.marker_tail + text
            self.marker_count += combined.count(marker)
            self.marker_tail = combined[-(len(marker) - 1):]
            if choice.get("finish_reason") is not None:
                self.finishes += 1
        usage = value.get("usage")
        if isinstance(usage, dict):
            self.has_usage = True
            for field, attribute in (("prompt_tokens", "input_tokens"), ("completion_tokens", "output_tokens")):
                count = usage.get(field)
                if type(count) is not int or not 0 <= count <= 10_000_000:
                    raise ProbeError("invalid_usage")
                setattr(self, attribute, count)

    def validate(self, terminal=None):
        if self.done != 1 or self.finishes + int(self.category is not None) != 1:
            raise ProbeError("invalid_terminal")
        if terminal is None and self.category is not None:
            raise ProbeError(self.category)
        if terminal is None and not self.has_usage:
            raise ProbeError("missing_usage")
        if terminal is not None and self.category not in terminal:
            raise ProbeError("unexpected_terminal")

    def metadata(self):
        return {"events": self.events, "completed": self.finishes, "terminal_errors": int(self.category is not None), "input_tokens": self.input_tokens, "output_tokens": self.output_tokens, "duplicate_events": 0, "missing_events": 0}


class Response:
    def __init__(self, connection, response, deadline, max_bytes, timer, expired):
        self.connection = connection
        self.response = response
        self.status = response.status
        self.max_bytes = max_bytes
        self.deadline = deadline
        self.timer = timer
        self.expired = expired

    def __enter__(self):
        return self

    def __exit__(self, *_):
        self.close()

    def close(self):
        self.timer.cancel()
        self.response.close()
        self.connection.close()

    def chunks(self):
        count = 0
        try:
            while True:
                remaining = self.deadline - time.monotonic()
                if remaining <= 0:
                    raise ProbeError("timeout")
                if self.connection.sock:
                    self.connection.sock.settimeout(remaining)
                data = self.response.read1(4096)
                if self.expired.is_set():
                    raise ProbeError("timeout")
                if not data:
                    break
                count += len(data)
                if count > self.max_bytes:
                    raise ProbeError("response_limit")
                yield data
        except (TimeoutError, socket.timeout):
            raise ProbeError("timeout") from None
        except (OSError, http.client.HTTPException):
            raise ProbeError("timeout" if self.expired.is_set() else "transport_closed") from None

    def json(self):
        try:
            value = json.loads(b"".join(self.chunks()))
        except (ValueError, UnicodeError, RecursionError):
            raise ProbeError("invalid_json") from None
        if not isinstance(value, dict):
            raise ProbeError("invalid_json")
        return value

    def events(self, after=0):
        if self.status != 200:
            raise ProbeError(error_code(self.json()), self.status)
        content_type = self.response.getheader("Content-Type", "").split(";")[0].strip().lower()
        if content_type != "text/event-stream":
            raise ProbeError("invalid_content_type")
        parser = SSEParser(after=after, max_bytes=self.max_bytes)
        for chunk in self.chunks():
            yield from parser.feed(chunk)
        parser.finish()


class Client:
    def __init__(self, base_url, key, timeout=30, max_bytes=2_097_152):
        try:
            url = urlsplit(base_url)
            address = ipaddress.ip_address(url.hostname or "")
            if address.version == 6 and address.ipv4_mapped:
                address = address.ipv4_mapped
            allowed = address.is_loopback or address in ipaddress.ip_network("100.64.0.0/10") or address in ipaddress.ip_network("fd7a:115c:a1e0::/48")
            if url.scheme != "http" or url.username or url.password or url.path not in ("", "/") or url.query or url.fragment or not allowed:
                raise ValueError()
            port = url.port or 80
            if not 1 <= port <= 65535 or not 0.01 <= timeout <= 300 or not 64 <= max_bytes <= 8_388_608:
                raise ValueError()
        except (ValueError, TypeError):
            raise ProbeError("invalid_configuration") from None
        if not isinstance(key, str) or len(key) != 64 or any(c not in "0123456789abcdef" for c in key):
            raise ProbeError("invalid_credential")
        self.host, self.port, self.key = str(address), port, key
        self.timeout, self.max_bytes = timeout, max_bytes

    def open(self, method, path, body=None, request_id=None, after=None, key=None):
        connection = http.client.HTTPConnection(self.host, self.port, timeout=self.timeout)
        deadline = time.monotonic() + self.timeout
        expired = threading.Event()
        timer = None
        headers = {"Authorization": "Bearer " + (key if key is not None else self.key), "Connection": "close"}
        if body is not None:
            headers["Content-Type"] = "application/json"
        if request_id:
            headers["X-Phone-Coder-Request-ID"] = request_id
        if after is not None:
            headers["Last-Event-ID"] = str(after)
        try:
            connection.connect()
            connected_socket = connection.sock
            def expire():
                expired.set()
                try:
                    connected_socket.shutdown(socket.SHUT_RDWR)
                except OSError:
                    pass
            timer = threading.Timer(max(0, deadline - time.monotonic()), expire)
            timer.daemon = True
            timer.start()
            connection.request(method, path, body=body, headers=headers)
            response = connection.getresponse()
            if expired.is_set():
                response.close()
                raise ProbeError("timeout")
            if response.getheader("Cache-Control") != "no-store" or response.getheader("X-Content-Type-Options") != "nosniff":
                response.close()
                raise ProbeError("missing_security_headers")
            length = response.getheader("Content-Length")
            if length is not None and (not length.isdecimal() or int(length) > self.max_bytes):
                response.close()
                raise ProbeError("response_limit")
            return Response(connection, response, deadline, self.max_bytes, timer, expired)
        except ProbeError:
            if timer:
                timer.cancel()
            connection.close()
            raise
        except (TimeoutError, socket.timeout):
            if timer:
                timer.cancel()
            connection.close()
            raise ProbeError("timeout") from None
        except (OSError, http.client.HTTPException, ValueError):
            if timer:
                timer.cancel()
            connection.close()
            raise ProbeError("timeout" if expired.is_set() else "transport_closed") from None

    def json(self, method, path, body=None, request_id=None, key=None, expected=200):
        with self.open(method, path, body, request_id, key=key) as response:
            value = response.json()
            if response.status != expected:
                raise ProbeError(error_code(value), response.status)
            return value


class Probe:
    def __init__(self, client, model=None, checkpoint=None):
        self.client = client
        self.model = model
        self.checkpoint = checkpoint
        self.output_limit = 64

    def body(self, stream=True, unicode=False, max_tokens=64):
        prompt = "Reply exactly once with: hello 🌍" if unicode else "Write a short Python function that adds two integers."
        return json.dumps({"model": self.model, "messages": [{"role": "user", "content": prompt}], "stream": stream, "stream_options": {"include_usage": True}, "max_tokens": min(max_tokens, self.output_limit)}, ensure_ascii=False, separators=(",", ":")).encode()

    def stream(self, body, request_id=None, after=None, result=None, first=None):
        result = result or StreamResult()
        with self.client.open("POST", "/v1/chat/completions", body, request_id or str(uuid.uuid4()), after=after) as response:
            for number, value in response.events(after=after or 0):
                result.consume(number, value)
                if first is not None:
                    action, first = first, None
                    action()
        return result

    def sequential(self):
        total_in = total_out = 0
        for _ in range(20):
            value = self.client.json("POST", "/v1/chat/completions", self.body(stream=False), str(uuid.uuid4()))
            choices = value.get("choices", [])
            usage = value.get("usage", {})
            if len(choices) != 1 or choices[0].get("finish_reason") not in ("stop", "length") or not isinstance(choices[0].get("message", {}).get("content"), str):
                raise ProbeError("invalid_completion")
            counts = [usage.get(k) for k in ("prompt_tokens", "completion_tokens", "total_tokens")]
            if any(type(n) is not int or not 0 <= n <= 10_000_000 for n in counts) or counts[0] + counts[1] != counts[2]:
                raise ProbeError("invalid_usage")
            total_in += counts[0]
            total_out += counts[1]
        return {"completed": 20, "input_tokens": total_in, "output_tokens": total_out}

    def unauthorized(self):
        self.client.json("GET", "/health", key=("f" if self.client.key == "0" * 64 else "0") * 64, expected=401)
        return {"http_status": 401}

    def cancel(self):
        rid = str(uuid.uuid4())
        def cancel():
            first = self.client.json("DELETE", "/v1/requests/" + rid, request_id=rid)
            second = self.client.json("DELETE", "/v1/requests/" + rid, request_id=rid)
            if first.get("cancelled") is not True or second.get("cancelled") is not False:
                raise ProbeError("cancel_not_idempotent")
        result = self.stream(self.body(max_tokens=512), rid, first=cancel)
        result.validate({"request_cancelled"})
        return result.metadata()

    def reattach(self):
        rid, body, result = str(uuid.uuid4()), self.body(unicode=True), StreamResult()
        with self.client.open("POST", "/v1/chat/completions", body, rid) as response:
            for number, value in response.events():
                result.consume(number, value)
                if result.digest.digest() != hashlib.sha256().digest():
                    break
        self.stream(body, rid, after=result.last, result=result).validate()
        replay = self.stream(body, rid, after=0)
        replay.validate()
        if replay.digest.digest() != result.digest.digest() or replay.events != result.events:
            raise ProbeError("replay_mismatch")
        return result.metadata()

    def unicode(self):
        result = self.stream(self.body(unicode=True))
        result.validate()
        if result.marker_count != 1:
            raise ProbeError("unicode_marker_mismatch")
        return result.metadata()

    def queue(self):
        with concurrent.futures.ThreadPoolExecutor(max_workers=6) as pool:
            futures = [pool.submit(self.stream, self.body(max_tokens=512)) for _ in range(6)]
            completed = rejected = 0
            for future in futures:
                try:
                    future.result().validate()
                    completed += 1
                except ProbeError as error:
                    if error.category != "queue_full" or error.status != 429:
                        raise
                    rejected += 1
        if rejected == 0:
            return {"status": "BLOCKED", "category": "queue_not_saturated", "completed": completed, "rejected": 0}
        return {"completed": completed, "rejected": rejected}

    def background(self):
        if self.checkpoint is None:
            return {"status": "NOT RUN", "category": "owner_checkpoint_required"}
        result = None
        interrupted = False
        try:
            result = self.stream(self.body(max_tokens=512), first=lambda: self.checkpoint("background"))
            result.validate({"background_interrupted", "session_ended"})
            interrupted = True
        except ProbeError as error:
            if error.category not in ("transport_closed", "truncated_stream", "invalid_terminal"):
                raise
        self.checkpoint("foreground")
        self.client.json("GET", "/health")
        fresh = self.stream(self.body())
        fresh.validate()
        if not interrupted:
            return {"status": "BLOCKED", "category": "background_terminal_unobserved", "completed": 1}
        return {"completed": 1, "terminal_errors": 1}

    def rotation(self):
        if self.checkpoint is None:
            return {"status": "NOT RUN", "category": "owner_checkpoint_required"}
        old = self.client.key
        new = self.checkpoint("rotation")
        if not isinstance(new, str) or len(new) != 64 or new == old or any(c not in "0123456789abcdef" for c in new):
            raise ProbeError("invalid_rotation_credential")
        self.client.json("GET", "/health", key=old, expected=401)
        self.client.json("GET", "/health", key=new)
        self.client.key = new
        return {"http_status": 401, "completed": 1}

    def run(self, scenarios=SCENARIOS):
        results = []
        for name in scenarios:
            start = time.monotonic()
            try:
                if name not in SCENARIOS:
                    raise ProbeError("invalid_scenario")
                if name in ("background", "rotation") and self.checkpoint is None:
                    metadata = {"status": "NOT RUN", "category": "owner_checkpoint_required"}
                else:
                    health = self.client.json("GET", "/health")
                    if health.get("api_version") != "phone-coder-api/1" or health.get("ready") is not True:
                        raise ProbeError("model_unavailable")
                    if self.model is None:
                        self.model = health.get("model")
                    if not isinstance(self.model, str) or not self.model or len(self.model.encode()) > 1024:
                        raise ProbeError("invalid_model_metadata")
                    catalog = self.client.json("GET", "/v1/models").get("data")
                    if not isinstance(catalog, list):
                        raise ProbeError("invalid_model_metadata")
                    selected = [row for row in catalog if isinstance(row, dict) and row.get("id") == self.model and row.get("callable") is True]
                    if len(selected) != 1 or type(selected[0].get("max_output_tokens")) is not int or not 1 <= selected[0]["max_output_tokens"] <= 1_000_000:
                        raise ProbeError("invalid_model_metadata")
                    self.output_limit = selected[0]["max_output_tokens"]
                    metadata = getattr(self, name)()
                results.append({"scenario": name, "status": "PASS", **metadata, "duration_seconds": round(time.monotonic() - start, 3)})
            except ProbeError as error:
                row = {"scenario": name, "status": "FAIL", "category": error.category, "duration_seconds": round(time.monotonic() - start, 3)}
                if error.status is not None:
                    row["http_status"] = error.status
                results.append(row)
            except (Exception, KeyboardInterrupt):
                results.append({"scenario": name, "status": "FAIL", "category": "probe_interrupted", "duration_seconds": round(time.monotonic() - start, 3)})
                break
        statuses = {row["status"] for row in results}
        status = next((s for s in ("FAIL", "BLOCKED", "NOT RUN") if s in statuses), "PASS") if results else "NOT RUN"
        return {"schema": "phone-coder-qualification/1", "status": status, "scope": "selected_scenarios", "scenarios": results}


def exit_code(summary):
    return {"PASS": 0, "FAIL": 1, "NOT RUN": 2, "BLOCKED": 2}.get(summary.get("status"), 2)


class RedactedArgumentParser(argparse.ArgumentParser):
    def error(self, _message):
        raise ProbeError("invalid_arguments")


def owner_checkpoint(stage):
    if stage == "background":
        input("Background Phone Coder now, wait for its serving indication to pause, then press Enter. ")
    elif stage == "foreground":
        input("Return Phone Coder to the foreground, wait for Ready, then press Enter. ")
    else:
        input("On iPhone revoke/rotate this client and approve a fresh pairing; press Enter when complete. ")
        return getpass.getpass("New paired bearer (hidden): ")


def main(argv=None):
    parser = RedactedArgumentParser(description=__doc__)
    parser.add_argument("--base-url", default=os.environ.get("PHONE_CODER_BASE_URL"))
    parser.add_argument("--key", help="Prefer hidden input or PHONE_CODER_KEY; command arguments are visible to local process tools.")
    parser.add_argument("--model", default=None)
    parser.add_argument("--timeout", type=float, default=60)
    parser.add_argument("--scenarios", default=",".join(SCENARIOS))
    parser.add_argument("--interactive", action="store_true")
    parser.add_argument("--output", help="Write redacted JSON with owner-only permissions; existing files are not replaced.")
    try:
        args = parser.parse_args(argv)
        if args.key:
            print("Credential supplied as a process argument; use hidden input next time.", file=sys.stderr)
        key = args.key or os.environ.get("PHONE_CODER_KEY") or getpass.getpass("Paired bearer (hidden): ")
        client = Client(args.base_url, key, timeout=args.timeout)
        scenarios = args.scenarios.split(",")
        if not scenarios or len(scenarios) > len(SCENARIOS) or len(set(scenarios)) != len(scenarios) or any(name not in SCENARIOS for name in scenarios):
            raise ProbeError("invalid_scenario")
        summary = Probe(client, args.model, owner_checkpoint if args.interactive else None).run(scenarios)
        encoded = json.dumps(summary, indent=2, sort_keys=True) + "\n"
        if args.output:
            descriptor = os.open(args.output, os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o600)
            with os.fdopen(descriptor, "w") as output:
                output.write(encoded)
        print(encoded, end="")
        return exit_code(summary)
    except (ProbeError, OSError, ValueError, EOFError, KeyboardInterrupt):
        print('{"status":"BLOCKED","category":"configuration_or_input_error"}', file=sys.stderr)
        return 2


if __name__ == "__main__":
    raise SystemExit(main())
