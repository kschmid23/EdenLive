# Shared setup for the launch scripts. Sourced, not run.
#
# Reads deploy.conf and exports the settings used by the Python services.
# Tracks the processes started by this deployment.

# bash 3.2 only exits the function when `exit` runs inside one, so step back
# out of it and then out of the sourced file.
die() {
  echo "$1" >&2
  shopt -s extdebug
  trap 'exit 1' RETURN
  trap 'exit 1' DEBUG
  return 1
}

# Run from realtime/, where run.py and games/ live.
cd "$(dirname "$(readlink -f "${BASH_SOURCE[1]}")")" || exit 1

. ./deploy.conf

# Use the real-time Python environment and Node that setup_user_space.sh wrote, when present; without it the
# services start under the system python, which has no torch.
if [ -f ./.rt_env.sh ]; then
  . ./.rt_env.sh
fi

# A relative MODEL_ROOT is read from the Eden repository root.
if [ -z "$MODEL_ROOT" ]; then
  die "set MODEL_ROOT in deploy.conf"
fi
if [ "${MODEL_ROOT:0:1}" != "/" ]; then
  MODEL_ROOT="$(cd .. && pwd)/$MODEL_ROOT"
fi
export EDEN_MODEL_ROOT="$MODEL_ROOT"

# An empty BRIDGE_HOST means this host: the first address `hostname -I` reports.
# workbench_bridge.sh binds it and launch.sh connects to it, so both agree.
BRIDGE_HOST="${BRIDGE_HOST:-$(hostname -I | awk '{print $1}')}"
export HF_HUB_OFFLINE=1 PYTHONUNBUFFERED=1

# An empty TURN_HOST means the page connects directly, with no relay.
if [ -n "$TURN_HOST" ]; then
  if [ -z "$TURN_SECRET" ]; then
    die "TURN_HOST is set but TURN_SECRET is empty"
  fi
  export FLASHDREAMS_TURN_HOST="$TURN_HOST"
  export FLASHDREAMS_TURN_PORT="$TURN_PORT"
  export FLASHDREAMS_TURN_USERNAME="$TURN_USERNAME"
  export FLASHDREAMS_TURN_CREDENTIAL="$TURN_SECRET"
fi

# The application slug for a MODEL value of 14b or 5b.
app_slug() {
  case "$1" in
    14b) echo game2v-eden-world-v2-14b-taehv ;;
    5b)  echo game2v-eden-world-v2-5b-taehv ;;
    *)   die "unknown model '$1' (use 14b or 5b)" ;;
  esac
}

# --- Services this deployment started ---------------------------------------
# Pids live in .run/<name>.pid. Stopping by command line is not safe: another
# deployment on the same host runs the same commands.

pid_file() { echo ".run/$1.pid"; }

# Start a named service in the background and remember its pid.
#   serve <name> <log> <command...>
serve() {
  local name="$1" log="$2"
  shift 2
  stop_service "$name"
  mkdir -p .run
  nohup setsid "$@" > "$log" 2>&1 < /dev/null &
  echo "$!" > "$(pid_file "$name")"
  echo "$name pid $! (log $log)"
}

service_pid() {
  local file
  file="$(pid_file "$1")"
  [ -s "$file" ] && cat "$file"
}

running() {
  local pid
  pid="$(service_pid "$1")"
  [ -n "$pid" ] && kill -0 "$pid" 2>/dev/null
}

# Every process below a pid, children first-found (torchrun -> ranks -> Chromium).
descendants() {
  local child
  for child in $(pgrep -P "$1" 2>/dev/null); do
    echo "$child"
    descendants "$child"
  done
}

# Stop a service and everything it spawned. serve() starts each one under
# setsid, so it leads its own process group; the group kill catches the bulk,
# and the walk catches anything that moved to a group of its own (Chromium).
# A stale pid is removed quietly.
stop_service() {
  local pid tree
  pid="$(service_pid "$1")"
  [ -n "$pid" ] || return 1
  if kill -0 "$pid" 2>/dev/null; then
    tree="$(descendants "$pid")"
    kill -9 -- "-$pid" 2>/dev/null || true
    kill -9 "$pid" $tree 2>/dev/null || true
    echo "stopped $1 (pid $pid)"
  fi
  rm -f "$(pid_file "$1")"
}
