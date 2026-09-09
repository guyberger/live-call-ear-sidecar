#!/usr/bin/env bash
# EAR sidecar launcher: system-audio loopback (default) | --mic | --device NAME
# Listen-only. Does not use the xAI realtime talking-agent API.
set -euo pipefail

cd "$(dirname "$0")"
ROOT="$(pwd)"
PID_FILE="/tmp/ear-sidecar.pid"
ENV_FILE="${HOME}/.config/ear-sidecar/env"
OUT="${EAR_JSONL:-${HOME}/sand-knowledge/live-call.jsonl}"
if [[ -z "${PYTHON:-}" ]]; then
  if [[ -x "$ROOT/.venv/bin/python3" ]]; then
    PYTHON="$ROOT/.venv/bin/python3"
  else
    PYTHON="python3"
  fi
fi
FFMPEG="${FFMPEG:-}"
if [[ -z "$FFMPEG" ]]; then
  if [[ -x /opt/homebrew/bin/ffmpeg ]]; then
    FFMPEG=/opt/homebrew/bin/ffmpeg
  else
    FFMPEG=ffmpeg
  fi
fi

load_env_file() {
  local f="$1"
  local line key val
  while IFS= read -r line || [[ -n "$line" ]]; do
    [[ -z "$line" || "$line" == \#* ]] && continue
    line="${line#export }"
    if [[ "$line" =~ ^([A-Za-z_][A-Za-z0-9_]*)=(.*)$ ]]; then
      key="${BASH_REMATCH[1]}"
      val="${BASH_REMATCH[2]}"
      if [[ "$val" == \"*\" && "$val" == *\" ]]; then
        val="${val:1:${#val}-2}"
      elif [[ "$val" == \'*\' && "$val" == *\' ]]; then
        val="${val:1:${#val}-2}"
      fi
      export "${key}=${val}"
    fi
  done < "$f"
}

if [[ -f "$ENV_FILE" ]]; then
  mode="$(stat -f '%Lp' "$ENV_FILE" 2>/dev/null || true)"
  if [[ -n "$mode" && "$mode" != "600" ]]; then
    echo "warning: $ENV_FILE should be chmod 600 (got $mode)" >&2
  fi
  load_env_file "$ENV_FILE"
fi

if [[ -z "${XAI_API_KEY:-}" ]]; then
  echo "XAI_API_KEY is not set. Mint a key at https://console.x.ai and export it," >&2
  echo "or put KEY=value in ~/.config/ear-sidecar/env (chmod 600)." >&2
  echo "Do not paste the key into chat." >&2
  exit 2
fi

MODE="sck"
DEVICE=""
PASSTHRU=()
while [[ $# -gt 0 ]]; do
  case "$1" in
    --mic)
      MODE="mic"
      shift
      ;;
    --device)
      MODE="device"
      DEVICE="${2:-}"
      if [[ -z "$DEVICE" ]]; then
        echo "usage: $0 --device <avfoundation-audio-name>" >&2
        exit 2
      fi
      shift 2
      ;;
    *)
      PASSTHRU+=("$1")
      shift
      ;;
  esac
done

if [[ -f "$PID_FILE" ]]; then
  alive=0
  while read -r pid; do
    if [[ -n "${pid:-}" ]] && kill -0 "$pid" 2>/dev/null; then
      alive=1
    fi
  done < "$PID_FILE"
  if [[ "$alive" -eq 1 ]]; then
    echo "Already running (see $PID_FILE). Stop with: $ROOT/stop.sh" >&2
    exit 1
  fi
  rm -f "$PID_FILE"
fi

mkdir -p bin sessions

need_compile=0
if [[ ! -x bin/ear-capture ]]; then
  need_compile=1
elif [[ capture.swift -nt bin/ear-capture ]]; then
  need_compile=1
fi

if [[ "$need_compile" -eq 1 ]]; then
  if ! command -v swiftc >/dev/null 2>&1; then
    echo "swiftc not found. Install Xcode Command Line Tools, then re-run." >&2
    exit 1
  fi
  echo "compiling capture.swift → bin/ear-capture" >&2
  swiftc -parse-as-library -O -o bin/ear-capture capture.swift \
    -framework ScreenCaptureKit \
    -framework AVFoundation \
    -framework CoreMedia \
    -framework CoreAudio \
    -framework CoreGraphics \
    -framework Foundation
fi

if ! "$PYTHON" -c "import websockets" 2>/dev/null; then
  echo "python package 'websockets' is missing. Install with:" >&2
  echo "  $PYTHON -m pip install -r $ROOT/requirements.txt" >&2
  exit 1
fi

SESSION_ID="ear-$(date -u +%Y%m%dT%H%M%S)-$("$PYTHON" -c 'import uuid; print(uuid.uuid4().hex[:8])')"
LOG="sessions/${SESSION_ID}.log"
: > "$PID_FILE"
: > "$LOG"

echo "EAR sidecar (listen-only, not a talking voice agent)"
echo "  session:  $SESSION_ID"
echo "  output:   $OUT"
echo "  log:      $ROOT/$LOG"
echo "  stop:     $ROOT/stop.sh"
case "$MODE" in
  sck)
    echo "  capture:  ScreenCaptureKit system/loopback audio"
    echo "  note:     first run needs Screen Recording permission"
    echo "            System Settings → Privacy & Security → Screen Recording"
    echo "            (grant to ear-capture, or Terminal/iTerm/Cursor if launched from there)"
    CAP_CMD=( "$ROOT/bin/ear-capture" )
    ;;
  mic)
    echo "  capture:  ffmpeg avfoundation — MacBook Pro Microphone (STT smoke test only)"
    CAP_CMD=( "$FFMPEG" -nostdin -hide_banner -loglevel error \
      -f avfoundation -i ":MacBook Pro Microphone" \
      -vn -ac 1 -ar 16000 -f s16le -acodec pcm_s16le pipe:1 )
    ;;
  device)
    echo "  capture:  ffmpeg avfoundation — $DEVICE"
    CAP_CMD=( "$FFMPEG" -nostdin -hide_banner -loglevel error \
      -f avfoundation -i ":${DEVICE}" \
      -vn -ac 1 -ar 16000 -f s16le -acodec pcm_s16le pipe:1 )
    ;;
esac

# Double-fork so ExternalShell abort / SIGHUP cannot kill the pipe.
export EAR_CAP_CMD="$("$PYTHON" -c 'import json,sys; print(json.dumps(sys.argv[1:]))' "${CAP_CMD[@]}")"
export EAR_PYTHON="$PYTHON"
export EAR_PY="$ROOT/ear.py"
export EAR_OUT="$OUT"
export EAR_SESSION="$SESSION_ID"
export EAR_LOG="$ROOT/$LOG"
export EAR_PID_FILE="$PID_FILE"
if [[ ${#PASSTHRU[@]} -gt 0 ]]; then
  export EAR_EXTRA="$("$PYTHON" -c 'import json,sys; print(json.dumps(sys.argv[1:]))' "${PASSTHRU[@]}")"
else
  export EAR_EXTRA='[]'
fi
"$PYTHON" "$ROOT/daemon_pipe.py"

echo "started. PIDs in $PID_FILE"
if [[ -s "$LOG" ]]; then
  echo "--- early log ---"
  sed -n '1,40p' "$LOG"
fi
