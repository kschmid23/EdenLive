#!/usr/bin/env bash
# Speed and GPU memory of the 5B few-step autoregressive model over a set of resolutions and clip lengths, with repeats, and one
# summary table at the end. Runs measure_resolution.sh for every combination and appends each run to a CSV.
#
# Usage:   bash measure_ar_sweep.sh [--resolutions "832x480 1280x704"] [--frames "117 237"] [--repeats 3] [--csv FILE]
#                                   [--samples DIR] [--dry-run]
#   --resolutions   space separated WIDTHxHEIGHT list, each a multiple of 16                [832x480 1280x704]
#   --frames        space separated clip lengths, each 12n-3 and within the recording       [117 237]
#   --repeats       measured runs per combination                                           [3]
#   --csv           results file, appended to                                               [measurements/ar_<host>_<time>.csv]
#   --samples       sample folder (see render_sample_ar.sh)                                 [examples/city_racer]
#   --dry-run       print the plan and the free GPU memory, run nothing
# Environment: MIN_FREE_MIB  free GPU memory required per run, in MiB [40000]
# For each resolution one extra warm-up run is made first and left out of the table: the first run at a new size compiles and
# caches kernels and is slower. Two clip lengths are used so that the table can also show the steady rate, the extra frames of
# the long clip divided by its extra time, which removes the model-load tail, the first chunk and the video writing that every
# run pays once. The offline log has no per-chunk timing; the real-time service does (python3 realtime/chunk_stats.py).
# Memory is the GPU's total used memory: on a shared GPU other jobs add to it, so the table shows the memory the run added.
set -euo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")"

resolutions="832x480 1280x704"
frame_list="117 237"
repeats=3
csv=""
samples="examples/city_racer"
dry=0
while [ "$#" -gt 0 ]; do
  case "$1" in
    --resolutions) resolutions="${2:?--resolutions needs a list}"; shift 2 ;;
    --frames) frame_list="${2:?--frames needs a list}"; shift 2 ;;
    --repeats) repeats="${2:?--repeats needs a number}"; shift 2 ;;
    --csv) csv="${2:?--csv needs a file}"; shift 2 ;;
    --samples) samples="${2:?--samples needs a folder}"; shift 2 ;;
    --dry-run) dry=1; shift ;;
    -h|--help) sed -n '2,20p' "${BASH_SOURCE[0]}"; exit 0 ;;
    *) echo "ERROR: unknown option $1" >&2; exit 2 ;;
  esac
done

for resolution in ${resolutions}; do
  [[ "${resolution}" =~ ^[0-9]+x[0-9]+$ ]] || { echo "ERROR: '${resolution}' is not WIDTHxHEIGHT" >&2; exit 2; }
  (( ${resolution%x*} % 16 == 0 && ${resolution#*x} % 16 == 0 )) || { echo "ERROR: ${resolution}: width and height must be multiples of 16" >&2; exit 2; }
done
for frames in ${frame_list}; do
  (( (frames + 3) % 12 == 0 )) || { echo "ERROR: ${frames} frames is not 12n-3 (117, 129, ..., 237)" >&2; exit 2; }
done
(( repeats >= 1 )) || { echo "ERROR: --repeats must be at least 1" >&2; exit 2; }
command -v nvidia-smi >/dev/null 2>&1 || { echo "ERROR: nvidia-smi not found" >&2; exit 1; }
[[ -x .venv/bin/python ]] || { echo "ERROR: .venv/bin/python not found; run setup_and_run_example.sh first" >&2; exit 1; }
[[ -n "${csv}" ]] || csv="measurements/ar_$(hostname)_$(date +%Y%m%d_%H%M%S).csv"

runs=$(( $(wc -w <<< "${resolutions}") * ( $(wc -w <<< "${frame_list}") * repeats + 1 ) ))
echo "plan: resolutions [${resolutions}], clip lengths [${frame_list}] frames, ${repeats} measured runs each, plus 1 warm-up per resolution"
echo "      ${runs} renders in total, about 1 minute each, results in ${csv}"
nvidia-smi --query-gpu=name,memory.used,memory.total,utilization.gpu --format=csv,noheader | sed 's/^/GPU: /'
nvidia-smi --query-compute-apps=pid,used_memory --format=csv,noheader | sed 's/^/  other process: /' | head -n 8
if (( dry )); then
  echo "dry run: nothing started"
  exit 0
fi

mkdir -p "$(dirname "${csv}")"
smallest="${frame_list%% *}"
for resolution in ${resolutions}; do
  width="${resolution%x*}"
  height="${resolution#*x}"
  echo "== ${resolution}: warm-up run (not in the table)"
  bash measure_resolution.sh --width "${width}" --height "${height}" --frames "${smallest}" --samples "${samples}" > /dev/null || true
  for frames in ${frame_list}; do
    for run in $(seq 1 "${repeats}"); do
      echo "== ${resolution}, ${frames} frames, run ${run} of ${repeats}"
      bash measure_resolution.sh --width "${width}" --height "${height}" --frames "${frames}" --samples "${samples}" --csv "${csv}" | grep -E "^result|^without load|^GPU memory" || true
    done
  done
done

echo
echo "== summary (${csv})"
.venv/bin/python - "${csv}" <<'PY'
import csv
import statistics
import sys

try:
    all_rows = list(csv.DictReader(open(sys.argv[1])))
except FileNotFoundError:
    sys.exit("no results file: no run was started")
rows = [row for row in all_rows if row["status"] == "0" and row["gen_s"]]
failed = sum(1 for row in all_rows if row["status"] != "0")
if not rows:
    sys.exit(f"no successful runs in {sys.argv[1]} ({failed} failed); see the .measure.log files under inference/")
groups = {}
for row in rows:
    groups.setdefault((int(row["width"]), int(row["height"])), {}).setdefault(int(row["frames"]), []).append(row)

print(f"{'resolution':>10} {'frames':>6} {'runs':>4} {'without load s':>15} {'fps (median)':>12} {'fps range':>13} {'GPU added MiB':>14}")
for (width, height), by_frames in sorted(groups.items()):
    medians = {}
    for frames, runs in sorted(by_frames.items()):
        seconds = [float(r["gen_s"]) for r in runs]
        fps = [frames / s for s in seconds]
        added = max(int(r["added_mib"]) for r in runs)
        medians[frames] = statistics.median(seconds)
        print(f"{width}x{height:<5} {frames:>6} {len(runs):>4} {medians[frames]:>15.1f} {statistics.median(fps):>12.2f} "
              f"{min(fps):>6.2f}-{max(fps):<6.2f} {added:>14}")
    if len(medians) >= 2:
        short, long = min(medians), max(medians)
        extra_s = medians[long] - medians[short]
        if extra_s > 0:
            print(f"{width}x{height:<5} steady rate: ({long} - {short}) frames in {extra_s:.1f} extra seconds = {(long - short) / extra_s:.2f} fps")
if failed:
    print(f"{failed} run(s) failed and are left out; see the .measure.log files under inference/")
PY
