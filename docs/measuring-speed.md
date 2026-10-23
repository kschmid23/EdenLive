# Measuring EdenLive speed on the DGX

Scripts and results for the 5B few-step autoregressive model (`dit-5b`, 4 steps, chunks of 3 latent frames = 12 frames) on the GB300
DGX (`pmgb300ws-0304`), idle GPU, 1280x704 at 24 fps. State as of 2026-10-23. All numbers are single sessions of runs on the dates
shown; nothing here was measured on an H100.

## Scripts

| Script | Measures | Run |
| --- | --- | --- |
| `measure_resolution.sh` | One offline render: speed without model load (timed to 0.1 s from the last "components loaded" line to the end), whole-run speed, GPU memory before, peak and added. Optional `--csv`. | `bash measure_resolution.sh --width 1280 --height 704 --frames 117` |
| `measure_ar_sweep.sh` | Resolutions x clip lengths x repeats (default 10, plus one warm-up per resolution), summary table with mean, standard deviation, median, range and the steady rate. | `bash measure_ar_sweep.sh` |
| `measure_all_clips.sh` | The sweep over several recorded clips into one CSV and one table. | `bash measure_all_clips.sh` |
| `summarize_measurements.py` | The table, from any CSV the scripts wrote. | `python summarize_measurements.py measurements/FILE.csv` |
| `profile_games.py`, `profile_all_games.sh` | The real-time service on every registered game, played by its autopilot (`realtime/games/<slug>/demo.json`), with a headless browser as the client; warm-up chunks left out. | `bash profile_all_games.sh` |
| `realtime/chunk_stats.py` | Generation fps, per-chunk and gap percentiles, RTF and GPU memory from a service log. | `python3 realtime/chunk_stats.py` |

- The offline log has no per-chunk timing. The steady rate is the extra frames of the long clip divided by its extra time, which removes
  the model-load tail, the first chunk and the video writing.
- GPU memory in the offline scripts is the GPU's total used memory minus the memory in use before the run. In the service log it is the
  service process (`torch.cuda` allocated, peak allocated and reserved).
- `profile_games.py` refuses to start while another real-time service runs, and stops only the service it starts. Per game it plays
  `--seconds` (default 150) and restarts the round every `--restart-every` seconds (default 25), so 6 rounds per game. The service marks
  the first 5 chunks of each round as warmup.

## Offline clips (`examples/*`, 117 frames, 10 runs each, 2026-10-22)

| Clip | fps mean | fps std | fps median | fps min-max | GPU added (MiB) |
| --- | --- | --- | --- | --- | --- |
| `city_racer` | 9.08 | 0.08 | 9.14 | 8.93-9.14 | 46,192 |
| `city_racer_lanes` | 9.06 | 0.08 | 9.07 | 8.93-9.14 | 46,192 |
| `sony_taxi` | 8.55 | 0.06 | 8.54 | 8.42-8.67 | 46,190 |

Speed is from the last "components loaded" line to the end, so it includes the first chunk and writing the video. An earlier 832x480
run on `city_racer` ran at 11.7 fps (10 s for 117 frames, whole seconds) and added about 33.8 GiB.

## Real-time service, all registered games (2026-10-22, 75 s per game, 3 rounds)

Two full runs agreed within 0.2 %. Second run:

| Game | Steady chunks | Generation fps | Chunk fps, mean | Chunk fps, std | Generate ms P95 | Gap ms P95 | RTF | GPU (GiB) |
| --- | --- | --- | --- | --- | --- | --- | --- | --- |
| ember-den | 35 | 25.31 | 25.39 | 1.56 | 494 | 6480 | 0.948 | 28.5 |
| iron-colossus | 117 | 23.77 | 23.84 | 1.15 | 510 | 662 | 1.009 | 30.2 |
| jade-duel | 54 | 24.71 | 24.78 | 1.42 | 501 | 539 | 0.971 | 31.9 |
| warehouse-sokoban | 93 | 24.72 | 24.78 | 1.24 | 498 | 551 | 0.971 | 31.9 |
| taxi-dash | 119 | 24.83 | 24.86 | 0.85 | 491 | 526 | 0.967 | 31.9 |

- Pooled over all 418 chunks the generation rate is about 24.5 fps (RTF 0.98). A 12-frame chunk takes about 486 ms at the median.
- Generation fps is the model step only (no condition processing); RTF is generate time divided by playback time at 24 fps.
- GPU memory rises along the run because one process serves all games and PyTorch keeps its cache; it is not per game.
- The chunk counts and the 6.5 s gap on `ember-den` repeated exactly in both runs, so they depend on the game. The cause was not
  investigated.
- Not verified: that the autopilot moves every game. The service log has no game events. `realtime/games/_shared/record_demo.py`
  records a game played by its autopilot and can show it.

## Against the EdenLive report (section 5.4, one H100, 1280x704)

| | GB300 (this page) | H100 (report) |
| --- | --- | --- |
| Generation throughput (fps) | about 24.5 | 31.04 |
| Inter-chunk gap P95 (ms) | 524 to 662 | 391.54 |
| First-chunk latency (ms) | about 1,440 (one earlier session) | 1,161.81 |
| RTF | 0.98 | 0.5359 |

The report times each request from model-side condition processing to the decoded frames in CPU memory, after warm-up, over about
30 s proxy clips, and uses `torch.compile` and CUDA graphs. The service here starts with `--no-compile`, which is the likely reason for
part of the gap but was not tested.

## Not measured

- Speed with `torch.compile` or with other jobs stopped on a different day; input-to-display delay (about two chunk durations plus
  transmission by design); other resolutions in the live service, which is fixed at 1280x704 in `eden/game5b_config.py`.
