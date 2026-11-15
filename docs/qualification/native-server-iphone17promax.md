# Native server qualification: iPhone 17 Pro Max

Physical qualification status: **NOT RUN**. This document describes a repeatable
procedure; it does not certify a working IPA, native compiler result, model,
Tailscale path, memory envelope, or thermal result.

The standard-library probe at `scripts/qualification/native_server_probe.py`
tests the `phone-coder-api/1` text-chat transport. Its fake-server tests exercise
the probe itself. macOS XCTest, on-device inference, image generation and visual
accessibility remain separate qualifications.

## Evidence and status meanings

| Status | Meaning |
| --- | --- |
| NOT RUN | The scenario or required owner action has not been performed. |
| PASS | The named observation was made and all assertions passed. |
| FAIL | An observation contradicted the contract. Preserve the error category. |
| BLOCKED | The attempted run could not establish a required observation. |

Do not turn missing evidence into PASS. `queue_not_saturated` means six requests
completed too quickly to observe queue rejection. `background_terminal_unobserved`
means the socket closed before an explicit interruption terminal was received;
a fresh successful request alone cannot prove the old request's terminal state.
`completion_won_race` means a valid ordinary completion finished before DELETE
or the owner's background action could exercise interruption. That attempt is
BLOCKED rather than a cancellation/lifecycle failure. Repeat it with the app
and model ready; the background scenario still returns through the foreground
checkpoint and verifies a fresh request before reporting its result.

The probe exits 0 for all selected scenarios passing, 1 for any failure, and 2
for a blocked/not-run scenario or invalid configuration. A selected subset
passing does not qualify the full device matrix. JSON explicitly labels its
scope as `selected_scenarios`.

## Prepare the build and device

1. Run the macOS Simulator test/archive workflow for the exact source commit.
   Inspect its annotations and artifact checksum. Record its run and app SHA.
2. Download and verify that IPA, sign/install it through the supported SideStore
   procedure, and launch Phone Coder. Keep the app in the foreground while
   serving. Verify that the installed build matches the recorded artifact.
3. Connect both Ubuntu and iPhone to the same tailnet. Copy the numeric tailnet
   address shown by Server. This release accepts only numeric Tailscale
   `100.64.0.0/10` / `fd7a:115c:a1e0::/48` addresses and loopback. The probe
   rejects DNS names, credentials in URLs, URL paths, public addresses and LAN
   addresses; it does not follow HTTP redirects.
4. In Models, download and load a small compatible text model. Use a model with
   a useful text context and an output limit of at least 64 tokens. Start Server.
5. Pair this Ubuntu client through **Pair a device** and approve its name on the
   phone. Keep the reusable bearer in protected local storage or supply it at
   the probe's hidden prompt. It must never enter Git, shell history, a URL,
   screenshots, logs, or qualification evidence.

If no paired client exists yet, the following optional one-process bootstrap
performs the same exchange without printing or saving the bearer. Run from the
repository root after setting the non-secret numeric base URL. Type the
one-time token from the pairing payload at the hidden prompt, then approve the
client on the phone. Ordinary probe runs can instead use an existing client's
bearer. The bootstrap uses the same bounded HTTP client and address gate.

```bash
export PHONE_CODER_BASE_URL='http://100.64.0.2:11434'
python3 - <<'PY'
import getpass
import json
import os
from scripts.qualification.native_server_probe import Client, Probe, ProbeError, exit_code

try:
    client = Client(os.environ['PHONE_CODER_BASE_URL'], '0' * 64, timeout=120)
    payload = json.dumps({'token': getpass.getpass('One-time pairing token (hidden): '),
                          'name': 'Ubuntu qualification'}).encode()
    paired = client.json('POST', '/pair/exchange', payload)
    credential = paired.get('bearer')
    # Constructing a new client validates the returned credential format.
    probe = Probe(Client(os.environ['PHONE_CODER_BASE_URL'], credential, timeout=120))
    result = probe.run(['unauthorized', 'sequential', 'reattach', 'unicode'])
    print(json.dumps(result, indent=2))
    raise SystemExit(exit_code(result))
except (ProbeError, OSError, ValueError, EOFError, KeyboardInterrupt):
    print('Pairing/qualification blocked; no credential or response was logged.')
    raise SystemExit(2)
PY
```

Replace the example numeric address with the address displayed by the phone.
The bootstrap intentionally keeps its newly issued key in that process only;
create/redeem another approved pairing for a later process if no protected
client credential is already available.

## Run the probe

First exercise the deterministic Ubuntu tests:

```bash
python3 -m unittest scripts/qualification/tests/test_native_server_probe.py -v
python3 -m py_compile scripts/qualification/native_server_probe.py
```

Run automated scenarios with the bearer entered at the hidden prompt:

```bash
python3 scripts/qualification/native_server_probe.py \
  --scenarios sequential,unauthorized,cancel,reattach,queue,unicode \
  --timeout 120 --output /tmp/phone-coder-small-model.json
```

`PHONE_CODER_KEY` is also supported for an already protected environment.
Avoid `--key`: process arguments may be visible to local tools. The probe
warns when that option is used, without echoing its value. Do not enable shell
tracing around credential handling. Summary files are created with mode 0600
and existing files are never overwritten; choose a fresh path for every run.

The loaded callable model is discovered through authenticated `/health` and
`/v1/models`. Generation is capped by its live `max_output_tokens`. Each request
uses a fresh UUID; reattachment resends identical body bytes with the original
ID and `Last-Event-ID`, then compares the reconstructed result to full replay
using an in-memory digest. No text or digest is written into the summary.

The Unicode scenario asks for one short known Unicode marker. A marker mismatch
is a failed model/transport observation; do not disguise it as success. A client
can verify replay identity and sequence integrity; proving exactly one native
execution also requires checking the phone's redacted activity/native tests.

The queue scenario submits six bounded concurrent requests against the one
active/four-waiter contract. If none receives `429 queue_full`, it reports
BLOCKED rather than claiming the queue limit was exercised. Do not increase
unbounded concurrency to force device failure.

Run the explicit lifecycle and credential checks separately:

```bash
python3 scripts/qualification/native_server_probe.py \
  --scenarios background,rotation --interactive \
  --timeout 180 --output /tmp/phone-coder-owner-checks.json
```

For background, the script opens an active stream, then asks the owner to
background the app. Return to the foreground only when the next checkpoint
requests it; wait for Ready and continue. The script requires an explicit
background/session-ended terminal, then a fresh successful request. iOS may
close the socket before delivering the terminal; record that as BLOCKED and
use device/native ledger evidence to resolve it. The script never claims to
control the phone lifecycle. Without `--interactive`, both manual scenarios
are NOT RUN and exit 2.

For rotation, revoke/rotate that exact paired client on the phone, redeem a new
one-time exchange through an approved client process, and enter the new bearer
at the hidden prompt. The probe verifies the old key returns 401 and the new
key works. It never echoes either key. Do not rotate another user's client.

After the small model, stop serving, load the target 3B–8B quantized coding
model, restart serving, and repeat the automated and owner scenarios into new
summary files. Observe model download/validation, residency transitions,
memory/thermal state, and long-output behavior directly on the phone. Check
that manual Stop stays stopped and a model reload cannot deliver old output.

## Required physical record

Keep full model repository/revision details in a private owner record outside
Git. Public evidence uses a model alias and quantization plus a redacted
identity. Do not include prompts, answers, QR payloads, tokens, keys or full
request/model/session identifiers. The probe summary includes only fixed
scenario/category names, status, durations, counts and token usage. The app
source commit and artifact checksum may be recorded in full.

| Evidence field | Small model | Target coding model |
| --- | --- | --- |
| Device | iPhone 17 Pro Max — NOT RUN | iPhone 17 Pro Max — NOT RUN |
| Installed iOS build | NOT RUN | NOT RUN |
| macOS workflow run / annotations | NOT RUN | NOT RUN |
| App source SHA / IPA SHA-256 | NOT RUN | NOT RUN |
| Model alias / revision redacted / quantization | NOT RUN | NOT RUN |
| Runtime (MLX or GGUF), context/output limits | NOT RUN | NOT RUN |
| Start/end memory available and process footprint | NOT RUN | NOT RUN |
| Start/end battery/charging and ambient conditions | NOT RUN | NOT RUN |
| Thermal transitions / timestamps | NOT RUN | NOT RUN |
| Automated probe summary path/checksum | NOT RUN | NOT RUN |
| Lifecycle/rotation summary path/checksum | NOT RUN | NOT RUN |
| Native test / device observations | NOT RUN | NOT RUN |
| Operator, date, outcome, failure categories | NOT RUN | NOT RUN |

| Required scenario | Small model | Target coding model |
| --- | --- | --- |
| Twenty consecutive completions and usage | NOT RUN | NOT RUN |
| Unauthorized credential rejected | NOT RUN | NOT RUN |
| Explicit/idempotent cancellation, one terminal | NOT RUN | NOT RUN |
| Disconnect/reattach/full replay, one native execution | NOT RUN | NOT RUN |
| Queue rejection at bounded pressure | NOT RUN | NOT RUN |
| Split Unicode, contiguous event IDs, no duplicate output | NOT RUN | NOT RUN |
| Background terminal and fresh foreground request | NOT RUN | NOT RUN |
| Old-key rejection/new-key success | NOT RUN | NOT RUN |
| Manual Stop never reconnects | NOT RUN | NOT RUN |
| Model reload rejects stale output | NOT RUN | NOT RUN |
| Memory/thermal interruption and recovery | NOT RUN | NOT RUN |
| Long-output backpressure/recovery | NOT RUN | NOT RUN |
| Light/dark, large text, RTL, landscape, VoiceOver | NOT RUN | NOT RUN |

The next physical action is to obtain the exact reviewed build from a passing
macOS test/archive run, install/sign it, load the small model, pair Ubuntu,
and execute the automated command above. Increment B is not device-qualified
until both model columns and their required evidence have been completed.
