#!/usr/bin/env bash
# Run a model without the workbench: it renders GAME from the first step, with
# no home screen. Needs neither the bridge nor the FLUX worker.
#
# Usage: bash start.sh [14b|5b] [--no-compile] [--no-follow] [--no-menu]
#
# The model defaults to MODEL in deploy.conf. --no-compile skips transformer
# compilation, for when only time-to-first-chunk matters. --no-follow returns
# once the service is started instead of following its log. The page opens on
# the game gallery and waits for a game to be picked there; --no-menu starts GAME
# at once instead.
set -u
. "$(dirname "$(readlink -f "$0")")/_common.sh"
FOLLOW=1
MENU_ARGS=(--wait-for-start)
MODEL_ARG=""
for arg in "$@"; do
  case "$arg" in
    --no-follow) FOLLOW=0 ;;
    --no-menu) MENU_ARGS=() ;;
    --no-compile) ;;
    *) [ -n "$MODEL_ARG" ] || MODEL_ARG="$arg" ;;
  esac
done
APP=$(app_slug "${MODEL_ARG:-$MODEL}") || exit 1

serve app .eden_app.log \
  python -m torch.distributed.run --nproc_per_node="$NPROC" run.py "$APP" \
  --mode webrtc --host "$APP_HOST" --port "$APP_PORT" -- \
  --no-ui --no-compile --total-blocks 10000 \
  ${MENU_ARGS[@]+"${MENU_ARGS[@]}"} \
  --game "$GAME"
echo "$APP on $NPROC GPUs, http://$APP_HOST:$APP_PORT/"
[ "$FOLLOW" -eq 0 ] || tail -f .eden_app.log
