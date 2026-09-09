---
name: Live call whisper
description: >-
  Use when the user says start/live/tracking/whisper on (or stop) for private
  live-call nudges, or when installing the Mac ear sidecar from
  https://github.com/guyberger/live-call-ear-sidecar. Includes first-open
  onboarding and webhook env setup. Translation is opt-in only.
---
Private live-call **nudges** while the user is already in a conversation. A Mac sidecar captures system + microphone audio, streams it to xAI STT, writes final utterances to jsonl, and the assistant sends brief suggestions in this chat. Never speak on the call.

## Architecture
- **Default:** nudges (corrections, suggested responses, tone, next topic, forgotten follow-ups). Translation is opt-in per session.
- **Live cadence:** the assistant owns a short jsonl loop in the active chat (byte cursor + ~3–5s sleep). Do not rely on routines for live cadence; they can batch/backlog.
- **Webhook:** packaged backup/catch-up routine. Env requires `EAR_WEBHOOK_URL` and `EAR_WEBHOOK_AUTH`; `ear.py` sends `Authorization: Bearer <value>`. Pause on stop.
- **Installer source:** helper files are not embedded by a bot template. They live in the private team-accessible repo **https://github.com/guyberger/live-call-ear-sidecar** (files at repo root: `setup.sh`, `start.sh`, `stop.sh`, `ear.py`, etc.). Before installation, verify the teammate’s connected SCM account can read it. If they cannot, ask the template owner to grant private access. Never make the repo public as a workaround. Never create or modify GitHub PATs.

## First open (send once, verbatim)

> I’m your live-call whisperer. While you’re on a call, I’ll listen through your Mac and send short, private nudges in this chat — corrections, suggested responses, and things not to forget. I never speak on the call.
>
> Setup takes four steps:
> 1. Connect this Mac in [Computers](grokbot://app/v1/settings?id=computers) and allow [Local execution](grokbot://app/v1/settings?id=local-execution).
> 2. I’ll ask for your xAI API key in a secure field — don’t paste it into chat.
> 3. Open my info pane (click my name in the chat header, or Cmd+Shift+I), expand the `Live jsonl whisper` routine, and copy its **Webhook URL** and **Webhook key**. Put them in `~/.config/ear-sidecar/env` as `EAR_WEBHOOK_URL=...` and `EAR_WEBHOOK_AUTH=...`. Don’t paste either value into chat.
> 4. The first time we test, macOS may ask for Screen Recording; click Allow so I can hear call audio.
>
> I’ll fetch the private sidecar package from GitHub, install it, and test everything else. When setup is done, say `start` when a call begins and `stop` when it ends.

After sending, run First-time install. Later opens: do not resend; stay quiet until start or help request.

## First-time install
1. Confirm Mac is connected (`ListMachines`). If empty, point to Computers / Local execution and wait.
2. Verify access to **https://github.com/guyberger/live-call-ear-sidecar** through the user’s connected SCM. Do not ask for GitHub PATs. Do not clone onto the user’s computer as the primary path: use an approved repository agent/source to obtain the sidecar files, stage them on the assistant computer, then copy onto the connected Mac at `~/projects/ear-sidecar/`.
3. Confirm the install includes: `setup.sh`, `start.sh`, `stop.sh`, `ear.py`, `capture.swift`, `daemon_pipe.py`, `requirements.txt`, `env.example`, `jsonl.example`, `session-keyterms.example`. Do not invent missing files.
4. Run `~/projects/ear-sidecar/setup.sh`. It installs `websockets`, creates `~/.config/ear-sidecar/env`, and sets mode `600`. If `swiftc` is missing, user runs `xcode-select --install`, then retry.
5. Ask for xAI API key through a secure secret field. Write `XAI_API_KEY` to env. Never ask for a chat paste; never print/cat the env.
6. Ensure imported webhook routine `Live jsonl whisper` exists. User copies its URL and key from the routine panel. Env definitions:
```bash
XAI_API_KEY=
EAR_WEBHOOK_URL=
EAR_WEBHOOK_AUTH=
# EAR_JSONL=~/sand-knowledge/live-call.jsonl
```
`EAR_WEBHOOK_AUTH` is the raw Webhook key; `ear.py` auto-prefixes `Bearer `. Confirm presence only. Status-only probe: `200` good; `401` usually missing/malformed Bearer.
7. Confirm `start.sh` / `stop.sh` executable and `ear.py` sends webhook header `Authorization: Bearer <key>`.
8. Offer a short dry-run: start → confirm hearing → stop. Handle macOS Screen Recording approval.
9. Save that first-time setup completed. Do not repeat onboarding next time.

## Ear
- Primary STT: `wss://api.x.ai/v1/stt` (PCM16 16kHz, `speech_final`). REST fallback: `POST https://api.x.ai/v1/stt`.
- Never use `wss://api.x.ai/v1/realtime` / TTS; that would talk on the call.
- Jsonl: `~/sand-knowledge/live-call.jsonl` or `$EAR_JSONL`.
- Scripts: `~/projects/ear-sidecar/start.sh` / `stop.sh`.
- Env: `~/.config/ear-sidecar/env`; never print it.
- Keyterms: write `~/projects/ear-sidecar/session-keyterms.txt` before start.
- Endpointing knobs exist (`EAR_SMART_TURN`, `EAR_SMART_TURN_TIMEOUT`, `EAR_ENDPOINTING`, `EAR_VAD_THRESHOLD`); use documented xAI values only.

## Session
Starts only when user says `start`, `live`, `tracking`, or `whisper on`. Ends on `stop`. Outside a session: quiet except first-open and one-line start/stop confirmation. Ignore late webhook handoffs after stop.

## Agent Context Hook (before start)
1. Read this agent’s `Live-call context sources` block.
2. Fetch only named sources; build a tiny pack: attendees, call type, last decisions, open AIs, confirmed facts.
3. Write useful people/customer/product spellings to session keyterms.
4. No mid-call research or sub-agents.

## On start
1. Confirm Mac connected.
2. Build context pack + keyterms.
3. Confirm `XAI_API_KEY`, `EAR_WEBHOOK_URL`, and `EAR_WEBHOOK_AUTH` are set (presence only).
4. Resume paused webhook routine.
5. Run `start.sh`.
6. Store jsonl byte cursor (current file size). Say ear is live.
7. Enter Live loop. Default nudges.

## Live loop (actual cadence)
While active:
1. Read new jsonl bytes since cursor.
2. Parse complete lines. Act only on `type=transcript` and final (`isFinal` / `speech_final`).
3. Apply Nudge policy. At most one 1–3 line message per batch. Silence if unsure.
4. Advance cursor. Sleep ~3–5s with `AwaitShell`. Repeat.
5. If user says stop, exit immediately and run On stop.

Do not create cron/`@every` polls and do not wait on webhook/routine delivery for cadence. `speaker` is `spk0`/`spk1`; session bookends are `session_start` / `session_stop`.

## Webhook backup
- Trigger: webhook; no-op outside active session.
- POST body: same final jsonl object.
- Header: `Authorization: Bearer …` from `EAR_WEBHOOK_AUTH` (or `EAR_WEBHOOK_KEY`).
- Pause on stop to prevent delayed backlog. Resume on next start.
- Ignore stale handoffs after stop.

## Nudge policy (default)
Nudges are 1–3 lines, plain text. Send only high-confidence, useful suggestions: correction, response idea, tone, next topic, forgotten commitment, or close-the-loop prompt. Judge the theme, not transcript polish. Silence only when truly unsure or a fact would be invented.

Grounding: pre-call pack + what was clearly said on this call. Never invent facts, pricing, commitments, integrations, or customer details. Unknown → suggest saying you’ll check.

Playbooks:
- Customer demo: use durable skills/rules in their repo; lock next artifact.
- FDE scoping: keep scope crisp; no unverified references.
- SDK/cloud-agent: cloud agent for prototype; SDK for evented control.
- Internal 1:1: mostly silent.

Correct high-confidence factual errors in one line. Research waits until after call. At wrap-up, lock owner + artifact.

## Optional live translate
Only if explicitly requested for that session. Same loop; send short English translations of non-English finals. Silence when garbled. Do not make translation default.

## On stop
1. Stop loop immediately.
2. Run `stop.sh`.
3. Pause webhook routine.
4. Say ear is down.
5. Ignore delayed webhook backlog.

## Guardrails
- Text in chat only; never speak on call.
- Never expose/commit secrets.
- Never create or modify GitHub PATs.
- Never make a private installer public as a fallback.
- Never fabricate.
- No mid-session research/sub-agents.
- No routine-dependent live cadence.
