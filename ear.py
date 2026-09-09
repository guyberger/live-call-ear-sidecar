#!/usr/bin/env python3
"""Listen-only EAR sidecar: PCM16 LE 16 kHz mono on stdin → xAI Grok Voice STT → Wren jsonl.

Uses wss://api.x.ai/v1/stt only. Never the realtime (talking-agent) API.
"""

from __future__ import annotations

import argparse
import asyncio
import json
import os
import signal
import sys
import uuid
import urllib.error
import urllib.request
from datetime import datetime, timezone
from pathlib import Path
from urllib.parse import urlencode

CHUNK_BYTES = 3200  # 100 ms of PCM16 LE mono @ 16 kHz
STT_HOST = "wss://api.x.ai/v1/stt"
SOURCE = "live-call-sidecar"
DEFAULT_OUT = Path.home() / "sand-knowledge" / "live-call.jsonl"
KEY_HELP = (
    "XAI_API_KEY is not set. Mint a key at https://console.x.ai "
    "and export it (or put KEY=value in ~/.config/ear-sidecar/env, chmod 600). "
    "Do not paste the key into chat."
)


def utc_ts() -> str:
    return datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%S.%f")[:-3] + "Z"


def fail_if_no_key() -> str:
    key = os.environ.get("XAI_API_KEY") or ""
    if not key.strip():
        print(KEY_HELP, file=sys.stderr)
        raise SystemExit(2)
    return key


def speaker_label(event: dict) -> str | None:
    """Map diarize word.speaker int → spkN. Do not guess local vs remote."""
    counts: dict[int, int] = {}
    for word in event.get("words") or []:
        if not isinstance(word, dict) or "speaker" not in word:
            continue
        try:
            spk = int(word["speaker"])
        except (TypeError, ValueError):
            continue
        counts[spk] = counts.get(spk, 0) + 1
    if not counts:
        return None
    return f"spk{max(counts, key=counts.get)}"


def stt_url(keyterms: list[str], diarize: bool) -> str:
    params: list[tuple[str, str]] = [
        ("sample_rate", "16000"),
        ("encoding", "pcm"),
        ("interim_results", "true"),
        ("language", "en"),
    ]
    if diarize:
        params.append(("diarize", "true"))
    for term in keyterms:
        if term:
            params.append(("keyterm", term))
    return f"{STT_HOST}?{urlencode(params)}"


class Jsonl:
    def __init__(self, path: Path, session_id: str, webhook: str | None):
        self.path = path
        self.session_id = session_id
        self.webhook = webhook.strip() if webhook else None
        path.parent.mkdir(parents=True, exist_ok=True)
        self._fp = path.open("a", encoding="utf-8")

    def write(self, obj: dict) -> None:
        self._fp.write(json.dumps(obj, ensure_ascii=False) + "\n")
        self._fp.flush()

    def event(self, typ: str, text: str, *, speaker: str | None = None) -> dict:
        obj: dict = {
            "ts": utc_ts(),
            "source": SOURCE,
            "sessionId": self.session_id,
            "isFinal": True,
            "type": typ,
            "text": text,
        }
        if speaker:
            obj["speaker"] = speaker
        self.write(obj)
        return obj

    def close(self) -> None:
        try:
            self._fp.close()
        except OSError:
            pass


def post_webhook(url: str, obj: dict) -> None:
    try:
        data = json.dumps(obj, ensure_ascii=False).encode("utf-8")
        headers = {"Content-Type": "application/json"}
        # Grok Bot webhook: EAR_WEBHOOK_AUTH or EAR_WEBHOOK_KEY (Authorization: Bearer <value>)
        auth = (os.environ.get("EAR_WEBHOOK_AUTH") or os.environ.get("EAR_WEBHOOK_KEY") or "").strip()
        if auth:
            if not auth.lower().startswith("bearer "):
                auth = "Bearer " + auth
            headers["Authorization"] = auth
        req = urllib.request.Request(
            url,
            data=data,
            headers=headers,
            method="POST",
        )
        with urllib.request.urlopen(req, timeout=2) as resp:
            resp.read()
    except (urllib.error.URLError, TimeoutError, OSError) as exc:
        print(f"ear: webhook failed: {exc}", file=sys.stderr)


class Ear:
    def __init__(self, out: Path, session_id: str, keyterms: list[str], diarize: bool, webhook: str | None):
        self.key = fail_if_no_key()
        self.url = stt_url(keyterms, diarize)
        self.jsonl = Jsonl(out, session_id, webhook)
        self.session_id = session_id
        self.shutdown = asyncio.Event()
        self.transcript_done = asyncio.Event()
        self.started = False
        self.stop_written = False
        self.audio_done_sent = False
        self.ws = None

    def emit_start(self) -> None:
        self.jsonl.event("session_start", "session started")
        self.started = True
        print(f"ear: session_start {self.session_id}", file=sys.stderr)

    def emit_stop(self) -> None:
        if self.stop_written or not self.started:
            return
        self.stop_written = True
        self.jsonl.event("session_stop", "session stopped")
        print("ear: session_stop", file=sys.stderr)

    async def send_audio_done(self) -> None:
        if self.audio_done_sent or self.ws is None:
            return
        self.audio_done_sent = True
        try:
            await self.ws.send(json.dumps({"type": "audio.done"}))
            print("ear: sent audio.done", file=sys.stderr)
        except Exception as exc:
            print(f"ear: audio.done send failed: {exc}", file=sys.stderr)

    async def request_stop(self) -> None:
        self.shutdown.set()
        await self.send_audio_done()

    async def send_loop(self) -> None:
        loop = asyncio.get_running_loop()
        buf = bytearray()
        sent = 0
        last_log = 0
        try:
            while not self.shutdown.is_set() and not self.audio_done_sent:
                piece = await loop.run_in_executor(None, sys.stdin.buffer.read, CHUNK_BYTES - len(buf))
                if not piece:
                    if buf and not self.audio_done_sent:
                        await self.ws.send(bytes(buf))
                        buf.clear()
                    break
                buf.extend(piece)
                while len(buf) >= CHUNK_BYTES and not self.audio_done_sent:
                    await self.ws.send(bytes(buf[:CHUNK_BYTES]))
                    del buf[:CHUNK_BYTES]
                    sent += 1
                    if sent - last_log >= 50:
                        print(f"ear: sent {sent} chunks ({sent * CHUNK_BYTES} bytes)", file=sys.stderr)
                        last_log = sent
        except Exception as exc:
            if not self.shutdown.is_set():
                print(f"ear: send error: {exc}", file=sys.stderr)
        finally:
            await self.send_audio_done()
            self.shutdown.set()

    def on_partial(self, event: dict) -> None:
        is_final = bool(event.get("is_final"))
        speech_final = bool(event.get("speech_final"))
        text = (event.get("text") or "").strip()
        if not (is_final and speech_final):
            return
        if not text:
            return
        speaker = speaker_label(event)
        obj = self.jsonl.event("transcript", text, speaker=speaker)
        print(f"ear: utterance speaker={speaker or '-'} {text}", file=sys.stderr)
        if self.jsonl.webhook:
            asyncio.get_running_loop().run_in_executor(
                None, post_webhook, self.jsonl.webhook, obj
            )

    async def recv_loop(self) -> None:
        assert self.ws is not None
        try:
            async for raw in self.ws:
                if isinstance(raw, bytes):
                    try:
                        raw = raw.decode("utf-8")
                    except UnicodeDecodeError:
                        continue
                try:
                    event = json.loads(raw)
                except json.JSONDecodeError:
                    print(f"ear: non-json event: {raw[:200]!r}", file=sys.stderr)
                    continue
                typ = event.get("type")
                if typ == "transcript.partial":
                    self.on_partial(event)
                elif typ == "transcript.done":
                    print("ear: transcript.done", file=sys.stderr)
                    self.transcript_done.set()
                    self.shutdown.set()
                    break
                elif typ == "error":
                    print(f"ear: STT error: {event.get('message')}", file=sys.stderr)
                else:
                    print(f"ear: event {typ}", file=sys.stderr)
        except Exception as exc:
            if not self.shutdown.is_set():
                print(f"ear: recv error: {exc}", file=sys.stderr)
        finally:
            self.transcript_done.set()
            self.shutdown.set()

    async def run(self) -> int:
        try:
            import websockets
        except ImportError:
            print("ear: websockets is required. python3 -m pip install -r requirements.txt", file=sys.stderr)
            return 1

        headers = {"Authorization": f"Bearer {self.key}"}
        print(f"ear: connecting STT (listen-only) session={self.session_id}", file=sys.stderr)
        print(f"ear: jsonl {self.jsonl.path}", file=sys.stderr)

        try:
            async with websockets.connect(
                self.url,
                additional_headers=headers,
                max_size=None,
                ping_interval=20,
                ping_timeout=20,
            ) as ws:
                self.ws = ws
                first = await ws.recv()
                if isinstance(first, bytes):
                    first = first.decode("utf-8")
                created = json.loads(first)
                if created.get("type") == "error":
                    print(f"ear: STT error: {created.get('message')}", file=sys.stderr)
                    return 1
                if created.get("type") != "transcript.created":
                    print(f"ear: expected transcript.created, got {created!r}", file=sys.stderr)
                    return 1
                print("ear: transcript.created — streaming audio", file=sys.stderr)
                self.emit_start()

                loop = asyncio.get_running_loop()

                def _sig() -> None:
                    loop.create_task(self.request_stop())

                for sig in (signal.SIGINT, signal.SIGTERM):
                    loop.add_signal_handler(sig, _sig)

                send_t = asyncio.create_task(self.send_loop())
                recv_t = asyncio.create_task(self.recv_loop())
                await self.shutdown.wait()
                await self.send_audio_done()
                try:
                    await asyncio.wait_for(self.transcript_done.wait(), timeout=5)
                except TimeoutError:
                    print("ear: timeout waiting for transcript.done", file=sys.stderr)
                send_t.cancel()
                recv_t.cancel()
                await asyncio.gather(send_t, recv_t, return_exceptions=True)
        except Exception as exc:
            msg = str(exc)
            if "401" in msg or "Unauthorized" in msg:
                print(
                    "ear: STT auth failed. Check XAI_API_KEY "
                    "(mint at https://console.x.ai and export). Do not paste the key into chat.",
                    file=sys.stderr,
                )
                return 1
            print(f"ear: connection failed: {exc}", file=sys.stderr)
            return 1
        finally:
            self.emit_stop()
            self.jsonl.close()
        return 0


def parse_args(argv: list[str] | None = None) -> argparse.Namespace:
    p = argparse.ArgumentParser(description="EAR sidecar: stdin PCM16 → xAI STT → Wren jsonl")
    p.add_argument(
        "--out",
        default=str(DEFAULT_OUT),
        help="append-only jsonl path (default: ~/sand-knowledge/live-call.jsonl)",
    )
    p.add_argument("--keyterm", action="append", default=[], help="bias term (repeatable)")
    p.add_argument("--no-diarize", action="store_true", help="disable speaker diarization")
    p.add_argument(
        "--webhook",
        default=os.environ.get("EAR_WEBHOOK_URL") or None,
        help="POST each speech_final transcript JSON (default: $EAR_WEBHOOK_URL)",
    )
    p.add_argument("--session-id", default=None, help="session id (start.sh supplies this)")
    return p.parse_args(argv)


def main() -> int:
    args = parse_args()
    session_id = args.session_id or (
        "ear-" + datetime.now(timezone.utc).strftime("%Y%m%dT%H%M%S") + "-" + uuid.uuid4().hex[:8]
    )
    out = Path(os.path.expanduser(args.out)).expanduser()
    webhook = args.webhook or None
    ear = Ear(
        out=out,
        session_id=session_id,
        keyterms=list(args.keyterm or []),
        diarize=not args.no_diarize,
        webhook=webhook,
    )
    try:
        return asyncio.run(ear.run())
    except KeyboardInterrupt:
        return 0


if __name__ == "__main__":
    raise SystemExit(main())
