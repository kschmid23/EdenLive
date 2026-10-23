#!/usr/bin/env bash
# Render one clip with the 5B few-step autoregressive model at a chosen resolution and report the speed and the GPU memory the run
# used. Wraps render_sample_ar.sh: it passes the resolution as config overrides, samples the GPU's used memory once a second while
# the render runs, and prints a summary even when the run fails (an out-of-memory run still shows how far memory got).
#
# Usage:   bash measure_resolution.sh [--width W] [--height H] [--frames N] [--samples DIR] [--cover IMAGE] [--out DIR] [--download]
#   --width, --height   output size, both multiples of 16                                   [832 x 480]
#   --frames            must be 12n-3 (117, 129, ..., 237)                                  [117]
#   --samples, --cover, --download, --out   passed to render_sample_ar.sh (see its header)
# Environment: MIN_FREE_MIB   free GPU memory render_sample_ar.sh requires, in MiB [40000]; lower it for a 32 GB card
#              EXTRA_OVERRIDES  more key=value overrides, appended after the resolution
# Memory is the GPU's total used memory (nvidia-smi), not this process alone: on a shared GPU the peak includes other jobs, so the
# summary also shows the memory used before the run and the difference.
set -euo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")"

width=832
height=480
frames=117
out=""
samples="examples/city_racer"
pass=()
while [ "$#" -gt 0 ]; do
  case "$1" in
    --width) width="${2:?--width needs a number}"; shift 2 ;;
    --height) height="${2:?--height needs a number}"; shift 2 ;;
    --frames) frames="${2:?--frames needs a number}"; shift 2 ;;
    --samples) samples="${2:?--samples needs a folder}"; pass+=(--samples "$2"); shift 2 ;;
    --out) out="${2:?--out needs a folder}"; shift 2 ;;
    --cover) pass+=(--cover "${2:?--cover needs an image}"); shift 2 ;;
    --download) pass+=(--download); shift ;;
    -h|--help) sed -n '2,13p' "${BASH_SOURCE[0]}"; exit 0 ;;
    *) echo "ERROR: unknown option $1" >&2; exit 2 ;;
  esac
done

if (( width % 16 != 0 || height % 16 != 0 )); then
  echo "ERROR: width and height must be multiples of 16, got ${width}x${height}" >&2
  exit 2
fi
command -v nvidia-smi >/dev/null 2>&1 || { echo "ERROR: nvidia-smi not found" >&2; exit 1; }
[[ -n "${out}" ]] || out="inference/$(basename "${samples}")_ar_${width}x${height}"

used_mib() { nvidia-smi --query-gpu=memory.used --format=csv,noheader,nounits | head -n 1 | tr -d ' '; }
total_mib="$(nvidia-smi --query-gpu=memory.total --format=csv,noheader,nounits | head -n 1 | tr -d ' ')"
baseline="$(used_mib)"
echo "GPU $(nvidia-smi --query-gpu=name --format=csv,noheader | head -n 1): ${baseline} of ${total_mib} MiB in use before the run"
echo "rendering ${frames} frames at ${width}x${height} into ${out}"

export EXTRA_OVERRIDES="data.dataset.params.width=${width} data.dataset.params.height=${height} inference.width=${width} inference.height=${height} ${EXTRA_OVERRIDES:-}"
mkdir -p "$(dirname "${out}")"
render_output="${out}.measure.log"

bash render_sample_ar.sh "${pass[@]}" --frames "${frames}" --out "${out}" > "${render_output}" 2>&1 &
render_pid=$!
peak="${baseline}"
while kill -0 "${render_pid}" 2>/dev/null; do
  now="$(used_mib)"
  if [[ "${now}" =~ ^[0-9]+$ ]] && (( now > peak )); then
    peak="${now}"
  fi
  sleep 1
done
status=0
wait "${render_pid}" || status=$?

echo "---- render output (${render_output})"
grep -E "^Done in|^speed without model load|^ERROR|Error|OutOfMemoryError" "${render_output}" | tail -n 6 || true
echo "---- summary"
echo "resolution       ${width}x${height}, ${frames} frames"
if [[ "${status}" -eq 0 ]]; then
  echo "result           ok"
else
  echo "result           FAILED with exit code ${status}; read ${render_output}"
fi
echo "GPU memory       before ${baseline} MiB, peak ${peak} MiB, run added ${peak} - ${baseline} = $(( peak - baseline )) MiB, card total ${total_mib} MiB"
exit "${status}"
