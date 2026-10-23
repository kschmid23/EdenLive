#!/usr/bin/env bash
# EdenLive real-time service: weights, extra deps, four services, browser UI.
#
# Companion to setup_and_run_example.sh, which covers offline inference. This
# one brings up the Workbench UI on APP_PORT (8089 by default).
#
# Why this exists separately: the live path needs ~35 GB of weights the offline
# subset omits (flux-c2f for first-frame generation, decoder-5b for TAEHV
# streaming decode), plus playwright and npm, and it runs four services rather
# than one process.
#
# Note on GPUs: the offline adapter hard-rejects anything that is not SM90, so
# `infer` will not run on Blackwell. The realtime stack carries no such check,
# which is why it is worth trying there -- but that is the absence of a gate,
# not a verified configuration.
#
# Usage:
#   ./setup_and_run_live.sh              weights, deps, then start services
#   ./setup_and_run_live.sh --no-start   prepare only
#   ./setup_and_run_live.sh --stop       stop services on this host
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
RT="$ROOT/realtime"
VENV="$ROOT/.venv"
MODELS="$ROOT/models/EdenLive"
PY="$VENV/bin/python"
[ -x "$PY" ] || PY="$VENV/Scripts/python.exe"

if [ "${1:-}" = "--stop" ]; then
    cd "$RT" && bash stop.sh
    exit 0
fi
NO_START=0
[ "${1:-}" = "--no-start" ] && NO_START=1

[ -x "$PY" ] || { echo "ABORT: no venv. Run ./setup_and_run_example.sh --no-models first"; exit 1; }

# The launch scripts call a bare `python`; without the venv first on PATH they
# run /usr/bin/python and die on "No module named torch/eden".
export VIRTUAL_ENV="$VENV"
export PATH="$(dirname "$PY"):$PATH"

echo "=== checking free disk ==="
FREE_GB=$(df -BG --output=avail "$ROOT" 2>/dev/null | tail -1 | tr -dc '0-9' || echo 0)
if [ "${FREE_GB:-0}" -gt 0 ]; then
    echo "    ${FREE_GB} GB free, need 40 GB for flux-c2f plus room"
    [ "$FREE_GB" -lt 40 ] && { echo "ABORT: flux-c2f alone is 34.8 GB"; exit 1; }
else
    echo "    could not read free space, continuing"
fi

echo
echo "=== 1/5 realtime packages ==="
cd "$RT"
uv pip install --python "$PY" --no-deps -e ./flashdreams -e ./apps/cam2v -e ./integrations_v2/eden
uv pip install --python "$PY" -r requirements.txt

echo
echo "=== 2/5 chromium and three.js ==="
"$PY" -m playwright install chromium
command -v npm >/dev/null && npm install --prefix games || echo "    npm missing: game renders unavailable"

echo
echo "=== 3/5 live-only weights ==="
export MODELS
"$PY" - <<'PYDL'
from huggingface_hub import snapshot_download
import os
# Only what the offline 5B subset leaves out: FLUX for the workbench first
# frame, and the TAEHV decoder the streaming path uses instead of the VAE.
snapshot_download(
    repo_id="VAST-AI/EdenLive",
    local_dir=os.environ["MODELS"],
    allow_patterns=["flux-c2f/*", "decoder-5b/*"],
    max_workers=8,
)
print("live weights complete")
PYDL

echo
echo "=== 4/5 deploy.conf ==="
# TURN_HOST must be reachable from the browser; empty means WebRTC cannot relay.
if ! grep -qE '^TURN_HOST=.+' deploy.conf; then
    GUESS="$(hostname -I 2>/dev/null | awk '{print $1}')"
    if [ -n "$GUESS" ]; then
        sed -i "s/^TURN_HOST=.*/TURN_HOST=$GUESS/" deploy.conf
        echo "    TURN_HOST set to $GUESS"
    else
        echo "    WARNING: TURN_HOST is empty and could not be guessed; set it by hand"
    fi
fi
IFACE="$(ip route 2>/dev/null | awk '/^default/{print $5; exit}')"
if [ -n "$IFACE" ] && ! grep -qE "^TURN_IFACE=$IFACE$" deploy.conf; then
    sed -i "s/^TURN_IFACE=.*/TURN_IFACE=$IFACE/" deploy.conf
    echo "    TURN_IFACE set to $IFACE"
fi
# TURN_SECRET is your own password for the relay; the services refuse to start
# when TURN_HOST is set and it is empty. Generated once, never printed.
if ! grep -qE '^TURN_SECRET=.+' deploy.conf; then
    sed -i "s/^TURN_SECRET=.*/TURN_SECRET=$(openssl rand -hex 16)/" deploy.conf
    grep -qE '^TURN_SECRET=.+' deploy.conf || { echo "ABORT: no TURN_SECRET= line in deploy.conf to fill"; exit 1; }
    echo "    TURN_SECRET generated"
fi
grep -E '^(MODEL|NPROC|MODEL_ROOT|APP_HOST|APP_PORT|GAME|TURN_HOST|TURN_IFACE)=' deploy.conf | sed 's/^/    /'

if [ "$NO_START" -eq 1 ]; then
    echo
    echo "=== services not started: --no-start ==="
    exit 0
fi

command -v turnserver >/dev/null || { echo "ABORT: coturn missing. Run: sudo apt-get install -y coturn"; exit 1; }

echo
echo "=== 5/5 starting services ==="
bash turn_server.sh
bash workbench_bridge.sh
bash workbench_flux.sh
bash launch.sh

# The start scripts print a pid even when the process dies right after, so
# confirm each one is still running before announcing the UI.
sleep 20
for svc in turn bridge flux app; do
    PID_FILE=".run/$svc.pid"
    if [ -f "$PID_FILE" ] && kill -0 "$(cat "$PID_FILE")" 2>/dev/null; then
        echo "    $svc: running"
    else
        echo "ABORT: $svc is not running; see its log (.turnserver.log, .workbench/bridge.log, .workbench_flux.log, .eden_app.log)"
        exit 1
    fi
done

PORT="$(grep -E '^APP_PORT=' deploy.conf | cut -d= -f2)"
HOST="$(grep -E '^TURN_HOST=' deploy.conf | cut -d= -f2)"
echo
echo "UI: http://${HOST:-<host>}:${PORT}"
echo "stop with: $0 --stop"
