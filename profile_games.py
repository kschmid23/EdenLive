"""Profile the real-time EdenLive service on every registered game, playing each with its autopilot, and print one table.

Starts the service itself (realtime/start.sh, game menu mode) with the benchmark autopilot switched on, connects one headless
Chromium so the service has a client, then for each game switches to it, lets it play for --seconds (restarting the round every
--restart-every seconds so a finished round does not leave the game idle) and reads the chunk lines the service logs. The chunks the
service marks as warmup are left out. At the end it stops the service it started.

    .venv-rt/bin/python profile_games.py                          all games in realtime/games/registry.json, 75 s each
    .venv-rt/bin/python profile_games.py --games "ember-den taxi-dash" --seconds 30

Needs the real-time environment (realtime/setup_user_space.sh), an idle GPU (it refuses to start while another service is running)
and realtime/games/<slug>/demo.json for every game (the autopilot's rules). Results are also appended to measurements/games_*.csv.
Memory is the GPU memory of the service process from nvidia-smi, the largest value seen while the game played.
"""
import argparse
import csv
import json
import os
import socket
import statistics
import subprocess
import sys
import tempfile
import time
import urllib.error
import urllib.request
from pathlib import Path

from playwright.sync_api import sync_playwright

ROOT = Path(__file__).resolve().parent
REALTIME = ROOT / "realtime"
LOG = REALTIME / ".eden_app.log"
sys.path.insert(0, str(REALTIME))
import chunk_stats  # noqa: E402

CHROMIUM_ARGS = ["--disable-features=WebRtcHideLocalIpsWithMdns", "--autoplay-policy=no-user-gesture-required"]


def registry_slugs():
    return [game["slug"] for game in json.loads((REALTIME / "games" / "registry.json").read_text())["games"]]


def service_pids():
    result = subprocess.run(["pgrep", "-f", "[r]un.py game2v"], capture_output=True, text=True, check=False)
    return [int(pid) for pid in result.stdout.split()]


def service_gpu_mib(pids):
    result = subprocess.run(
        ["nvidia-smi", "--query-compute-apps=pid,used_memory", "--format=csv,noheader,nounits"], capture_output=True, text=True, check=False
    )
    total = 0
    for line in result.stdout.splitlines():
        pid, used = [part.strip() for part in line.split(",")]
        if int(pid) in pids:
            total += int(used)
    return total


def gpu_free_mib():
    result = subprocess.run(["nvidia-smi", "--query-gpu=memory.free", "--format=csv,noheader,nounits"], capture_output=True, text=True, check=True)
    return int(result.stdout.split()[0])


def post_switch(port, slug, deadline_s=90):
    body = json.dumps({"slug": slug, "restart": True}).encode()
    request = urllib.request.Request(
        f"http://127.0.0.1:{port}/ext/game2v/switch", data=body, headers={"content-type": "application/json"}, method="POST"
    )
    deadline = time.monotonic() + deadline_s
    while True:
        try:
            with urllib.request.urlopen(request, timeout=30):
                return
        except urllib.error.HTTPError as error:
            if error.code != 409 or time.monotonic() > deadline:
                raise RuntimeError(f"switch to {slug} failed: HTTP {error.code} {error.reason}") from error
            time.sleep(1)


def wait_ready(timeout_s):
    deadline = time.monotonic() + timeout_s
    while time.monotonic() < deadline:
        if LOG.exists() and "WebRTC server ready" in LOG.read_text(errors="replace"):
            return
        if not service_pids():
            raise RuntimeError(f"the service stopped before it was ready; see {LOG}")
        time.sleep(2)
    raise TimeoutError(f"the service was not ready after {timeout_s} s; see {LOG}")


def wait_peer_connected(mark, timeout_s):
    deadline = time.monotonic() + timeout_s
    while time.monotonic() < deadline:
        if "-> connected" in LOG.read_bytes()[mark:].decode(errors="replace"):
            return
        time.sleep(1)
    raise TimeoutError(f"no browser connected to the service within {timeout_s} s; see {LOG}")


def percentile(values, share):
    return chunk_stats.percentile(values, share)


def summarize(slug, chunks, peak_mib, fps):
    steady = [chunk for chunk in chunks if chunk["phase"] != "warmup"]
    if len(steady) < 2:
        return {"game": slug, "chunks": len(steady)}
    frames = sum(chunk["frames"] for chunk in steady)
    seconds = sum(chunk["generate_ms"] for chunk in steady) / 1000
    per_chunk = [chunk["frames"] * 1000 / chunk["generate_ms"] for chunk in steady]
    gaps = [(b["time"] - a["time"]) * 1000 for a, b in zip(steady, steady[1:]) if b["index"] == a["index"] + 1]
    return {
        "game": slug,
        "chunks": len(steady),
        "gen_fps": frames / seconds,
        "chunk_fps_mean": statistics.mean(per_chunk),
        "chunk_fps_std": statistics.stdev(per_chunk),
        "chunk_fps_median": statistics.median(per_chunk),
        "generate_ms_p95": percentile([chunk["generate_ms"] for chunk in steady], 0.95),
        "gap_ms_p95": percentile(gaps, 0.95) if gaps else float("nan"),
        "rtf": seconds / (frames / fps),
        "peak_gib": peak_mib / 1024,
    }


def play(port, slug, seconds, restart_every, pids, fps):
    mark = LOG.stat().st_size
    post_switch(port, slug)
    started = time.monotonic()
    next_restart = started + restart_every
    peak = 0
    while time.monotonic() - started < seconds:
        time.sleep(1)
        peak = max(peak, service_gpu_mib(pids))
        if time.monotonic() >= next_restart:
            post_switch(port, slug)
            next_restart += restart_every
    text = LOG.read_bytes()[mark:].decode(errors="replace")
    with tempfile.NamedTemporaryFile("w", suffix=".log", delete=False) as handle:
        handle.write(text)
    try:
        chunks = chunk_stats.parse(handle.name)
    finally:
        os.unlink(handle.name)
    return summarize(slug, chunks, peak, fps)


def print_table(results):
    print(f"{'game':<20} {'steady chunks':>13} {'gen fps':>8} {'chunk fps mean':>15} {'std':>6} {'median':>7} {'gen ms P95':>11} {'gap ms P95':>11} {'RTF':>6} {'GPU GiB':>8}")
    for row in results:
        if "gen_fps" not in row:
            print(f"{row['game']:<20} {row['chunks']:>13}   too few steady chunks to report (is the game running?)")
            continue
        print(f"{row['game']:<20} {row['chunks']:>13} {row['gen_fps']:>8.2f} {row['chunk_fps_mean']:>15.2f} {row['chunk_fps_std']:>6.2f} "
              f"{row['chunk_fps_median']:>7.2f} {row['generate_ms_p95']:>11.0f} {row['gap_ms_p95']:>11.0f} {row['rtf']:>6.3f} {row['peak_gib']:>8.1f}")


def main():
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--games", help="space separated slugs [all registered games]")
    parser.add_argument("--seconds", type=int, default=75, help="play time per game [75]")
    parser.add_argument("--restart-every", type=int, default=25, help="restart the round this often, in seconds [25]")
    parser.add_argument("--port", type=int, default=8089)
    parser.add_argument("--fps", type=float, default=24.0, help="playback rate for the real-time factor [24]")
    parser.add_argument("--csv", help="results file [measurements/games_<host>_<time>.csv]")
    args = parser.parse_args()

    sys.stdout.reconfigure(line_buffering=True)
    games = args.games.split() if args.games else registry_slugs()
    for slug in games:
        if not (REALTIME / "games" / slug / "demo.json").is_file():
            sys.exit(f"realtime/games/{slug}/demo.json is missing: the autopilot has no rules for {slug}")
    if service_pids():
        sys.exit("a real-time service is already running; stop it first (bash realtime/stop.sh). Not stopping it for you.")
    if gpu_free_mib() < 30000:
        sys.exit(f"only {gpu_free_mib()} MiB of GPU memory is free; the service needs about 25000 and the GPU is shared")
    csv_path = Path(args.csv) if args.csv else ROOT / "measurements" / f"games_{socket.gethostname()}_{time.strftime('%Y%m%d_%H%M%S')}.csv"
    csv_path.parent.mkdir(parents=True, exist_ok=True)

    env = dict(os.environ, EDEN_GAME_AUTOPILOT=str(REALTIME / "games" / "_shared" / "autopilot.js"))
    print(f"starting the service with the autopilot; games: {' '.join(games)}; {args.seconds} s each")
    subprocess.run(["bash", str(REALTIME / "start.sh"), "5b", "--no-follow"], cwd=ROOT, env=env, check=True)
    results = []
    try:
        wait_ready(300)
        pids = service_pids()
        with sync_playwright() as playwright:
            browser = playwright.chromium.launch(headless=True, args=CHROMIUM_ARGS)
            page = browser.new_page()
            connect_mark = LOG.stat().st_size
            page.goto(f"http://127.0.0.1:{args.port}/", wait_until="domcontentloaded")
            wait_peer_connected(connect_mark, 90)
            print("browser connected", flush=True)
            for slug in games:
                print(f"== {slug}", flush=True)
                results.append(play(args.port, slug, args.seconds, args.restart_every, pids, args.fps))
            browser.close()
    finally:
        subprocess.run(["bash", str(REALTIME / "stop.sh")], cwd=ROOT, check=False)

    print()
    print_table(results)
    reported = [row for row in results if "gen_fps" in row]
    if reported:
        with open(csv_path, "w", newline="") as handle:
            writer = csv.DictWriter(handle, fieldnames=list(reported[0]))
            writer.writeheader()
            writer.writerows(reported)
        print(f"\nresults: {csv_path}")


if __name__ == "__main__":
    main()
