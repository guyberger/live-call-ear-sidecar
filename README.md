# EAR sidecar

Listen-only. Meeting audio on this Mac → Grok Voice streaming STT → the whisperer agent’s file.

Not a talking agent. Does not use `wss://api.x.ai/v1/realtime`.

## Session (smallest path)

The user says **start** in the whisperer agent. The agent runs this sidecar. the whisperer agent reads speech_final lines and nudges.

```bash
~/projects/ear-sidecar/start.sh          # system/loopback (default)
~/projects/ear-sidecar/stop.sh
```

Smoke-test STT without loopback:

```bash
~/projects/ear-sidecar/start.sh --mic
```

## Key

Mint at https://console.x.ai. Never paste it in chat.

```bash
mkdir -p ~/.config/ear-sidecar && chmod 700 ~/.config/ear-sidecar
printf 'XAI_API_KEY=...\n' > ~/.config/ear-sidecar/env
chmod 600 ~/.config/ear-sidecar/env
```

Or `export XAI_API_KEY` in the shell that runs `start.sh`.

## Output (the whisperer agent)

Append-only JSONL: `~/sand-knowledge/live-call.jsonl`

Each utterance (STT `is_final` + `speech_final`):

```json
{"ts":"...Z","source":"live-call-sidecar","sessionId":"ear-...","isFinal":true,"speech_final":true,"type":"transcript","speaker":"spk0","text":"..."}
```

Optional webhook: set `EAR_WEBHOOK_URL` and `EAR_WEBHOOK_AUTH` (raw key; `ear.py` adds `Bearer `).

## Capture

Default is ScreenCaptureKit system audio (the call, not mic-only). First run: System Settings → Privacy & Security → Screen Recording → allow the app that launched `start.sh` (Cursor or Terminal).

BlackHole is not required for v1.

## Stop

`~/projects/ear-sidecar/stop.sh`
