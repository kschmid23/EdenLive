#!/usr/bin/env bash
# Speed and GPU memory of the 5B few-step autoregressive model over several recorded clips, each run several times, with one combined
# table at the end. Runs measure_ar_sweep.sh once per clip folder into one shared CSV.
#
# Usage:   bash measure_all_clips.sh [--clips "examples/city_racer examples/city_racer_lanes examples/sony_taxi"]
#                                    [--resolutions "1280x704"] [--frames "117"] [--repeats 3] [--csv FILE] [--dry-run]
#   --clips         space separated sample folders (each has manifest.csv; its first row is the clip rendered)
#   --resolutions   WIDTHxHEIGHT list, each a multiple of 16                                [1280x704]
#   --frames        clip lengths, each 12n-3 and within every recording                     [117]
#   --repeats       measured runs per clip, resolution and length                           [3]
#   --csv           results file                                                            [measurements/clips_<host>_<time>.csv]
#   --dry-run       print the plan and the GPU state, run nothing
# Per clip and resolution there is also one warm-up render that is left out of the table. A recording shorter than the longest
# --frames makes that clip fail; its failure is counted in the table note and the loop goes on with the next clip.
# Environment: MIN_FREE_MIB  free GPU memory required per run, in MiB [40000]
set -euo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")"

clips="examples/city_racer examples/city_racer_lanes examples/sony_taxi"
resolutions="1280x704"
frames="117"
repeats=3
csv=""
dry=()
while [ "$#" -gt 0 ]; do
  case "$1" in
    --clips) clips="${2:?--clips needs a list}"; shift 2 ;;
    --resolutions) resolutions="${2:?--resolutions needs a list}"; shift 2 ;;
    --frames) frames="${2:?--frames needs a list}"; shift 2 ;;
    --repeats) repeats="${2:?--repeats needs a number}"; shift 2 ;;
    --csv) csv="${2:?--csv needs a file}"; shift 2 ;;
    --dry-run) dry=(--dry-run); shift ;;
    -h|--help) sed -n '2,16p' "${BASH_SOURCE[0]}"; exit 0 ;;
    *) echo "ERROR: unknown option $1" >&2; exit 2 ;;
  esac
done

for clip in ${clips}; do
  [[ -f "${clip}/manifest.csv" ]] || { echo "ERROR: ${clip}/manifest.csv not found" >&2; exit 2; }
done
[[ -n "${csv}" ]] || csv="measurements/clips_$(hostname)_$(date +%Y%m%d_%H%M%S).csv"

echo "clips [${clips}], resolutions [${resolutions}], frames [${frames}], ${repeats} runs each -> ${csv}"
for clip in ${clips}; do
  echo "######## ${clip}"
  bash measure_ar_sweep.sh --samples "${clip}" --resolutions "${resolutions}" --frames "${frames}" --repeats "${repeats}" --csv "${csv}" --no-summary "${dry[@]}" || echo "clip ${clip} did not finish; going on"
done

if [[ "${#dry[@]}" -eq 0 ]]; then
  echo
  echo "== all clips (${csv})"
  .venv/bin/python summarize_measurements.py "${csv}"
fi
