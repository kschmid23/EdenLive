#!/usr/bin/env bash
# Profile the real-time service on all registered games, one after another, and print one table. Wrapper around profile_games.py with
# the real-time Python environment.
#
# Usage:   bash profile_all_games.sh [--games "ember-den taxi-dash"] [--seconds 75] [--restart-every 25] [--csv FILE]
# Everything is passed on to profile_games.py (see its header). Needs realtime/setup_user_space.sh to have been run, and an idle GPU:
# it refuses to start while another real-time service is running, and stops only the service it starts.
set -euo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")"

if [[ "${1:-}" == "-h" || "${1:-}" == "--help" ]]; then
  sed -n '2,7p' "${BASH_SOURCE[0]}"
  exit 0
fi
[[ -x .venv-rt/bin/python ]] || { echo "ERROR: .venv-rt/bin/python not found; run: bash realtime/setup_user_space.sh" >&2; exit 1; }
exec .venv-rt/bin/python profile_games.py "$@"
