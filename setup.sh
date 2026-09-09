#!/usr/bin/env bash
# One-time install. Does not start capture. Does not write a real API key.
set -euo pipefail
cd "$(dirname "$0")"
ROOT="$(pwd)"

if [[ -z "${PYTHON:-}" ]]; then
  if [[ -x "$ROOT/.venv/bin/python3" ]]; then
    PYTHON="$ROOT/.venv/bin/python3"
  else
    PYTHON="python3"
  fi
fi

"$PYTHON" -m pip install -r "$ROOT/requirements.txt"

CFG="${HOME}/.config/ear-sidecar"
mkdir -p "$CFG"
chmod 700 "$CFG"
ENV_FILE="$CFG/env"
if [[ ! -f "$ENV_FILE" ]]; then
  cp "$ROOT/env.example" "$ENV_FILE"
  chmod 600 "$ENV_FILE"
  echo "Created $ENV_FILE — add XAI_API_KEY, chmod 600. Do not paste the key into chat."
else
  echo "env file already exists: $ENV_FILE (left untouched)"
fi

if ! command -v swiftc >/dev/null 2>&1; then
  echo "swiftc not found. User needs Xcode Command Line Tools: xcode-select --install" >&2
fi

echo "setup ok. Next: put XAI_API_KEY in $ENV_FILE, then $ROOT/start.sh"
