# Real-time service on the GB300, and adding the taxi game

How the EdenLive real-time service (`realtime/start.sh`) was brought up on the DGX (NVIDIA GB300, aarch64, Ubuntu 24.04, driver 610.43, no root)
and how a standalone EdenGolem game is registered with it. State as of 2026-10-21. For the offline renders see `docs/taxi-render-findings.md`;
for running outside SM90 see `docs/running-on-blackwell.md`.

## What the service needs

| Need | Where it comes from | Status on the DGX |
| --- | --- | --- |
| `dit-5b`, `vae-5b`, `umt5`, `vision-encoder` | `models/EdenLive/` | Present |
| `decoder-5b/lighttaew2_2.pth` (TAEHV decoder, 45.7 MB) | Hugging Face `VAST-AI/EdenLive` | Installed by the setup script |
| Python 3.11 environment with torch 2.13.0+cu130 and the `flashdreams` packages | `.venv-rt` in the repository root | Installed; CUDA available |
| Node.js 22.11.0 (arm64) | `~/.local/node` | Installed |
| Games' npm packages | `realtime/games/node_modules` | Installed |
| Headless Chromium (Playwright, chromium-headless-shell 1243) | `~/.cache/ms-playwright` | Installed |
| `coturn` (TURN relay) | needs root (`apt-get install coturn`) | Not installed |
| Workbench: FLUX weights (`flux-c2f`), Claude CLI, bridge | | Not set up; not needed for `start.sh` |

The separate `.venv-rt` keeps the offline renders' `.venv` unchanged. Both hold torch 2.13.0+cu130.

## Setup script

`realtime/setup_user_space.sh` installs everything above except `coturn`, in six steps (decoder weights, `.venv-rt`, torch and the real-time
packages, Node, npm packages, Chromium). It needs `uv`, network access and about 12 GB of disk; finished steps are skipped on a rerun. It writes
`realtime/.rt_env.sh`, which puts `.venv-rt` and Node on `PATH`. It ran in about 25 seconds on the DGX.

## Starting the service

```bash
cd /localhome/kschmid/EdenLive/realtime
bash start.sh 5b                       # plays GAME from deploy.conf (default taxi-dash)
GAME=<slug> bash start.sh 5b           # plays another registered game
```

- It prints `WebRTC server ready; model loaded. Open http://<host>:8089/` after about 15 seconds (pipeline components 13.9 s, condition encoder
  0.4 s). The port is `APP_PORT` in `realtime/deploy.conf`.
- `start.sh` plays one registered game from the first step with no menu. The workbench with a game library needs the other services.
- `TURN_HOST` is empty, so the page connects to the model directly with no relay. The page and the WebRTC handshake were loaded from a PC on the
  network (HTTP 200); whether video streams through without a relay has not been confirmed.
- Stop with `bash stop.sh` in `realtime/`.
- Speed on this GPU: about 24.5 fps generation at 1280x704 over the five registered games, 2026-10-22 (the paper reports 31.04 fps on one H100). See `docs/measuring-speed.md`.

## Adding a standalone game

An EdenGolem project (output of the `edengolem` skill) is registered with the importer:

```bash
python -m eden.apps.game2v.import_game <project> --slug <slug> --cover <image> --prompt "<static prompt>" --event-prompts <events.json>
```

| Requirement | Detail |
| --- | --- |
| Project | Holds `.state.json` with the acceptance stage `passed`, `brief.json`, `package.json` and `runs/step3/acceptance`. `--allow-incomplete` imports an unaccepted run. |
| Three.js | `package.json` must pin `three` 0.161.0; only `three` and rapier are served. |
| Slug | Lowercase words joined by `-`; not `host`, `assets`, `vendor`, `bench`, `shared` or `node_modules`. `--replace` overwrites an earlier import. |
| Page contract | The standalone host (`games/host/standalone.js`) replaces `requestAnimationFrame` and `performance.now` with a virtual clock, dispatches key events, reads state from `window.__gameTest.read()` and streams only the scene canvas. The game's own HTML HUD never reaches the model. |
| Imports | `/assets/...` imports are mapped per slug to the game's own `games/<slug>/assets/`. |
| Restart key | Taken from `restart_actions` in `strategy.json`. |
| Cover | The first frame of every rollout. Without `--cover` the importer captures the game's own greybox frame. |
| Event prompts | Sentences for the game's event types, used as timed text. Without `--event-prompts` the importer builds one from the event names it finds in the source. |

The importer copies the run (without `evidence/` and the skill's metadata files) and the project's `assets/` into `realtime/games/<slug>/`, writes a
small overlay with a title chip and a result card, and appends an entry to `realtime/games/registry.json`.

## The taxi game (`taxi-dash`)

| Item | Value |
| --- | --- |
| Slug and title | `taxi-dash`, "Downtown Taxi Dash" |
| Source | EdenGolem project `city_racer`, run `runs/step3/acceptance`, copied to `/localhome/kschmid/taxi_game_project` on the DGX |
| Cover | The sunset taxi image, cropped to 1.818:1 and resized to 1280x704 |
| Static prompt | The golden-hour high-rise prompt (874 characters, 206 tokens) |
| Events | `round.started`, `checkpoint.passed`, `car.hit`, `finish.crossed`, `round.won`, `round.lost` |
| Controls | W/S drive and brake, A/D or arrows steer, Space handbrake, R or Enter restart |
| Check | The standalone host booted the page and captured an 832x480 first frame: the yellow taxi on the avenue, no HUD |

`taxi-dash` is the default game (`GAME` in `realtime/deploy.conf`). A service started earlier keeps the game it was started with; restart it (`bash stop.sh`, then `bash start.sh 5b`) to change it.

## Repository state on the DGX

Uncommitted there: `realtime/games/registry.json` (modified), `realtime/games/taxi-dash/` (new) and `realtime/setup_user_space.sh`, plus
earlier changes to `dynamic_prompt.py`, `adapter.py` and `render_sample.sh`. Commit them from the PC and clear the DGX tree before pulling.

## Not done

- Restarting the service with the taxi game and playing it from a browser.
- A TURN relay, if the direct connection is blocked.
- Input-to-display latency on this GPU (frame rate and chunk latency are in `docs/measuring-speed.md`).
- The workbench (game library, FLUX first frames, the Claude CLI bridge).
