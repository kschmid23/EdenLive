"""Print the speed and memory table for a CSV written by measure_resolution.sh (one row per render).

    python summarize_measurements.py measurements/FILE.csv [more.csv ...]

Failed runs are counted and left out. Rows are grouped by clip, resolution and clip length. For each clip and resolution that has two
or more lengths, the steady rate is also shown: the extra frames of the longest clip divided by its extra time, which removes the
model-load tail, the first chunk and the video writing that every run pays once.
"""
import csv
import statistics
import sys


def load(paths):
    rows = []
    for path in paths:
        try:
            rows.extend(csv.DictReader(open(path)))
        except FileNotFoundError:
            sys.exit(f"no results file: {path}")
    return rows


def main():
    if len(sys.argv) < 2:
        sys.exit(__doc__)
    all_rows = load(sys.argv[1:])
    rows = [row for row in all_rows if row["status"] == "0" and row["gen_s"]]
    failed = sum(1 for row in all_rows if row["status"] != "0")
    if not rows:
        sys.exit(f"no successful runs ({failed} failed); see the .measure.log files under inference/")
    groups = {}
    for row in rows:
        key = (row.get("clip") or "?", int(row["width"]), int(row["height"]))
        groups.setdefault(key, {}).setdefault(int(row["frames"]), []).append(row)

    print(f"{'clip':<18} {'resolution':>10} {'frames':>6} {'runs':>4} {'without load s':>15} {'fps (median)':>12} {'fps range':>13} {'GPU added MiB':>14}")
    for (clip, width, height), by_frames in sorted(groups.items()):
        medians = {}
        for frames, runs in sorted(by_frames.items()):
            seconds = [float(r["gen_s"]) for r in runs]
            fps = [frames / s for s in seconds]
            medians[frames] = statistics.median(seconds)
            print(f"{clip:<18} {width}x{height:<5} {frames:>6} {len(runs):>4} {medians[frames]:>15.1f} {statistics.median(fps):>12.2f} "
                  f"{min(fps):>6.2f}-{max(fps):<6.2f} {max(int(r['added_mib']) for r in runs):>14}")
        if len(medians) >= 2:
            short, long = min(medians), max(medians)
            extra_s = medians[long] - medians[short]
            if extra_s > 0:
                print(f"{clip:<18} {width}x{height:<5} steady rate: ({long} - {short}) frames in {extra_s:.1f} extra seconds = {(long - short) / extra_s:.2f} fps")
    if failed:
        print(f"{failed} run(s) failed and are left out; see the .measure.log files under inference/")


if __name__ == "__main__":
    main()
