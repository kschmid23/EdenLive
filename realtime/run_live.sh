#!/usr/bin/env bash
# Restart the real-time service and wait until it serves. One command for: stop the running services, start the model app, watch the log
# for "ready", and print the address. Plays GAME from deploy.conf (default taxi-dash).
#
# Usage:  bash run_live.sh [14b|5b] [--keep] [--no-menu]
#         GAME=<slug> bash run_live.sh        play another registered game
#
#   --keep     do not stop running services first (the app still replaces itself on start)
#   --no-menu  start GAME at once instead of opening the game gallery in the page
#
# Needs the environment from setup_user_space.sh (_common.sh loads .rt_env.sh). Uses start.sh, so it runs only the model app, with no
# workbench, FLUX worker or TURN relay. The GPU is shared: it prints the free memory before starting.
set -u
. "$(dirname "$(readlink -f "$0")")/_common.sh"

KEEP=0
START_ARGS=()
MODEL_ARG=""
for arg in "$@"; do
  case "$arg" in
    --keep) KEEP=1 ;;
    --no-menu) START_ARGS+=(--no-menu) ;;
    -h|--help) sed -n '2,13p' "$0"; exit 0 ;;
    *) [ -n "$MODEL_ARG" ] || MODEL_ARG="$arg" ;;
  esac
done

if [ -f games/registry.json ] && ! grep -q "\"slug\": *\"$GAME\"" games/registry.json; then
  echo "game '$GAME' is not in games/registry.json" >&2
  exit 1
fi

if command -v nvidia-smi >/dev/null 2>&1; then
  nvidia-smi --query-gpu=index,name,memory.total,memory.used --format=csv,noheader | sed 's/^/GPU /'
fi

[ "$KEEP" -eq 1 ] || bash stop.sh
bash start.sh ${MODEL_ARG:+"$MODEL_ARG"} --no-follow ${START_ARGS[@]+"${START_ARGS[@]}"} || exit 1

PID="$(service_pid app)"
echo "waiting for the model (up to 300 s)..."
for _ in $(seq 1 150); do
  if grep -q "WebRTC server ready" .eden_app.log 2>/dev/null; then
    CODE="$(curl -s -o /dev/null -m 10 -w '%{http_code}' "http://127.0.0.1:$APP_PORT/" || true)"
    echo "ready; page answers HTTP $CODE"
    echo "game: $GAME"
    echo "open: http://$(hostname -I | awk '{print $1}'):$APP_PORT/"
    echo "stop: bash stop.sh   log: $(pwd)/.eden_app.log"
    exit 0
  fi
  if [ -z "$PID" ] || ! kill -0 "$PID" 2>/dev/null; then
    echo "the app stopped before it was ready. Last log lines:" >&2
    tail -n 12 .eden_app.log >&2
    exit 1
  fi
  sleep 2
done
echo "not ready after 300 s; still starting. Follow it with: tail -f $(pwd)/.eden_app.log" >&2
exit 1
