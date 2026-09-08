# FFmpeg Benchmark Suite

Modular shell-based benchmarking harness that measures how fast your machine
can process video and audio with FFmpeg. Runs on **Windows (MSYS2/Git Bash)**,
**macOS**, and **Ubuntu / Arch / Fedora**.

## Quick start

```bash
./install.sh                   # installs ffmpeg + generates test media
./run_benchmarks.sh            # runs every benchmark at medium difficulty
```

## Folder layout

```
ffmpeg-bench/
├── install.sh                      Install ffmpeg & generate test media
├── run_benchmarks.sh               Main entry: run all / any benchmark(s)
├── generate_test_media.sh          Create synthetic mp4/mp3 test inputs
├── benchmarks/
│   ├── _common.sh                  Shared helpers (timing, JSON, math)
│   ├── hardware_info.sh            CPU / RAM / disk / ffmpeg capabilities
│   ├── speed.sh                    Decode/encode/transcode raw speed
│   ├── conversion.sh               Single-file mp4→mp3 & mp4→mp4 time
│   ├── clip_split.sh               Split a clip by count & by timestamp
│   ├── parallel_vs_sequential.sh   Parallel vs sequential throughput
│   ├── parallel_mp3_vs_mp4.sh      Parallel mp3 conversion vs mp4 re-encode
│   ├── chunked_vs_whole.sh         Chunk-then-convert vs direct conversion
│   ├── mp3_vs_mp4.sh               Split/chunk/process: mp3 vs mp4 pipelines
│   └── resource_efficiency.sh      Peak memory, CPU%, parallel contention
├── inputs/                        Your media goes here (or auto-generated)
│   ├── mp4/   test_default_*.mp4, test_short_*.mp4
│   ├── mp3/   test_default_*.mp3, test_short_*.mp3
│   └── samples/  README with suggested CC/public-domain mp3+mp4 files
├── tools/
│   ├── _record.sh                 Appends a result file to history.jsonl
│   └── graph_report.sh            Renders results/report.html from history
└── outputs/
    ├── mp4/                         Benchmark artifacts (re-encoded files)
    └── mp3/                         Converted outputs

results/
├── history.jsonl                    One row per result entry, appended every run
└── report.html                      Trend charts (run tools/graph_report.sh)
```

All results land in `results/*.json`.

## Usage

```bash
./run_benchmarks.sh                        # all benchmarks, medium
./run_benchmarks.sh speed conversion       # only specific benchmarks
./run_benchmarks.sh -d high                # resolution/bitrate preset
./run_benchmarks.sh -j 8 parallel_vs_sequential
./run_benchmarks.sh -n 2,4,8 -t 30 chunked_vs_whole
./run_benchmarks.sh -g auto                # use first available HW encoder
tools/graph_report.sh                      # chart recorded runs -> results/report.html
```

### Options

| Option | Description | Default |
| ------ | ----------- | ------- |
| `-d, --difficulty` | `low` \| `medium` \| `high` \| `ultra` | `medium` |
| `-j, --jobs` | Parallel jobs for parallel benches | `4` |
| `-n, --chunk-counts` | Chunk counts for chunked bench | `2 4 8` |
| `-t, --chunk-time` | Chunk-by-timestamp interval (s) | `30` |
| `-c, --chunks` | Segment count for clip_split | `4` |
| `-g, --gpu` | Hardware encode mode: `none` \| `auto` \| `nvenc` \| `qsv` \| `amf` \| `vaapi` \| `videotoolbox`, or a raw encoder name (e.g. `h264_nvenc`, `h264_qsv`, `hevc_videotoolbox`) | `none` |
| `-R, --no-record` | Don't append this run to `results/history.jsonl` | record |

Each benchmark can also be run on its own, e.g. `./benchmarks/speed.sh`,
and honors environment variables (`DIFFICULTY`, `PARALLEL_JOBS`, `CHUNK_COUNTS`,
`CHUNK_TIME`, `SEGMENT_COUNT`, `GPU_MODE`, `MONITOR_INTERVAL_MS`, `SPLIT_METHOD`).

### GPU acceleration

`-g` selects the video encoder used by the re-encode sites in the H.264/H.265
benchmarks:

| Mode | Meaning |
| ---- | ------- |
| `none` | Software H.264 (`libx264`) / H.265 (`libx265`) — the default |
| `auto` | Detect the first available HW encoder (`nvenc` → `qsv` → `amf` → `vaapi` → `videotoolbox`), else fall back to software |
| `nvenc` / `qsv` / `amf` / `vaapi` / `videotoolbox` | Request that backend (falls back to software if unavailable) |
| `h264_nvenc` (etc.) | Force an exact encoder name |

Notes:

- Fallbacks are per-site: if the selected GPU mode is unavailable, that site
  logs a warning and uses the software encoder, so runs never fail on missing
  drivers.
- Result labels (e.g. `encode_libx264`) stay the same across GPU/CPU so charts
  are comparable; the actual backend is recorded in the top-level `gpu` field
  and per-run in `history.jsonl`.
- Video quality intent is mapped per backend (`-cq` for NVENC, `-global_quality`
  for QSV, `-rc cqp` for AMF, `-qp` for VA-API) — the `crf`/bitrate you pass is
  honored approximately where the driver supports it.
- Test-media generation always stays software (deterministic inputs).

### Recording and charts

Every run is appended to `results/history.jsonl` automatically (unless
`-R` is given) — one row per result entry, tagging `run`, timestamp,
`difficulty`, `gpu`, and `benchmark`. Chart them with:

```bash
tools/graph_report.sh            # results/report.html (SVG, no deps)
tools/graph_report.sh --top 20   # show last 20 runs per series
tools/graph_report.sh --line --metric ff_real_ms # trend lines instead of bars
tools/graph_report.sh --metric ff_fps            # chart ffmpeg-native fps
```

`history.jsonl` is plain line-delimited JSON, so you can diff runs or grep them.

Besides the harness's own wall-clock and resource fields, every measured ffmpeg
run also captures ffmpeg's native `-benchmark` output (added through
`bench_run`/`parse_ff_bench`/`agg_ff_bench` in `benchmarks/_common.sh`). These
are stored side-by-side with the harness metrics as `ff_*` fields:

| Harness field | Meaning |
| ------------- | ------- |
| `elapsed_ms` / `total_ms` | Wall clock measured by the harness (includes spawn) |
| `peak_rss_kb`, `avg_cpu_percent` | OS-level process monitoring (per-process / pool) |
| `ff_fps` | ffmpeg's reported encoding fps (video sites) |
| `ff_speed_x` | ffmpeg's reported speed vs realtime |
| `ff_user_ms` / `ff_sys_ms` | ffmpeg's utime / stime |
| `ff_real_ms` | ffmpeg's own wall clock (`rtime`) — close to `elapsed_ms` |
| `ff_maxrss_kb` | ffmpeg's reported peak RSS |
| `ff_procs` | (aggregated entries) number of ffmpeg processes summed |

`--metric KEY` picks the y-axis value for charts (default `elapsed_ms`, falling
back to `total_ms`; other metrics skip rows that lack the field), and `--line`
renders a trend polyline with delta between first and last run, colored per GPU
backend.

### Difficulty presets

| Level  | Resolution | Duration | Video bitrate | FPS |
| ------ | ---------- | -------- | ------------- | --- |
| low    | 320x240    | 10s      | 500k          | 24  |
| medium | 1280x720   | 60s      | 2000k         | 30  |
| high   | 1920x1080  | 180s     | 5000k         | 60  |
| ultra  | 3840x2160  | 300s     | 15000k        | 60  |

## What each benchmark measures

| Benchmark | Outputs |
| --------- | ------- |
| `hardware_info` | CPU model/cores, RAM, disk write speed, ffmpeg build/hw accel |
| `speed` | Wall time for decode-only, encode (h264/h265), transcode, audio decode |
| `conversion` | mp4→mp3 and mp4→mp4 wall time per file + preset sweep |
| `clip_split` | Time to split by count (segment muxer + manual `-ss`), by timestamp, with re-encode |
| `parallel_vs_sequential` | Total time + speedup + efficiency at j=1,2,4,... |
| `parallel_mp3_vs_mp4` | Parallel throughput for mp3 conversion vs mp4 re-encode + ratio |
| `chunked_vs_whole` | Whole-file vs chunked (count/timestamp) conversion, split vs convert timing, produced-chunk counts; `copy` and `exact` split strategies |
| `mp3_vs_mp4` | Side-by-side mp3 vs mp4 for: splitting (time/count), chunking (split→convert→concat), processing (mp3↔mp3, mp4↔mp4, mp4→mp3, mp3→mp4). Reports wall time, produced chunks, and resource stats (peak RSS, CPU%, concurrency) via per-process and pool monitors |
| `resource_efficiency` | Peak RSS + average CPU% for single/multi-thread, re-encode, parallel pairs, stream copy |

## Interpreting the results

This section explains what every number means, how it was measured, and what a
"good" result looks like — so you can read `results/*.json`,
`results/history.jsonl`, and `results/report.html` without guessing.

### Data model and statistics

- **One entry = one measurement.** Every benchmark site spawns ffmpeg (usually
  once, or N-times for parallel sites) and its `elapsed_ms` (or `total_ms` for
  multi-phase sites) is recorded. Each entry is a JSON object; all entries for
  a run are written to `results/<benchmark>_<epoch>.json`.
- **One history row = one entry**, tagged with `run` (epoch), `ts` (UTC),
  `difficulty`, `gpu` (backend actually used), and `benchmark`. Rows are
  append-only, one per entry, so the same series appears once per run.
- **A "series" is `benchmark :: label`** (e.g. `conversion :: mp4_to_mp4_test_default_1280x720_60s`).
  Charts group by series and keep the *last `--top N` runs* (default 12),
  oldest → newest left to right.
- **Bar chart** (default): one bar per run, height ∝ value, colored by GPU
  backend, label showing the raw value.
- **Line chart** (`--line --metric KEY`): polyline through the per-run values,
  colored per backend, with a Δ% between the first and last run in the window.
  For time/CPU metrics **lower is better**; for `ff_fps` and `speed_x`
  **higher is better** (the chart meta text assumes time metrics).
- **"Latest run" comparisons** (used throughout this doc) take the most recent
  `ts` per series to avoid mixing old and new measurement instrumentation.

### Field reference

| Field | Meaning | Typical/notes |
| ----- | ------- | ----- |
| `elapsed_ms` | Harness wall clock from ffmpeg launch to exit, incl. process spawn | Long encodes ≈ `ff_real_ms` + ~10%; very short ops are spawn-dominated |
| `total_ms`, `split_ms`, `convert_ms` | Multi-phase sites: total and per-phase wall time | Appears on chunk/split sites |
| `speed_x` | Harness-computed realtime factor: input duration ÷ wall time | 1.0 = realtime; audio sites reach hundreds |
| `jobs`, `speedup`, `efficiency_percent` | `parallel_vs_sequential`: speedup = seq ÷ parallel time; efficiency = speedup ÷ jobs | 2 jobs ≈ 1.85×/92%, 4 jobs ≈ 2.8×/70% on the reference box |
| `produced_chunks` | Chunks actually emitted (may differ from requested for `-c copy`, which cuts at existing keyframes only) | Use `exact` split strategy for exact cuts |
| `concat_succeeded` | Whether the chunked pipeline's final `-c copy` concat produced output | 0 possible when no chunks were produced |
| `output_bytes` | Size of the produced file, for output-quality sanity checks |
| `peak_rss_kb` | OS-monitored peak memory of the ffmpeg process | `0` only when the process was too short to sample |
| `avg_cpu_percent` | OS-monitored average CPU%: ~100 = 1 core busy, ~400 = 4 cores | Decode+encode are ≥1 core; stream copy ~0 |
| `peak_pool_rss_kb`, `peak_concurrent_ffmpeg`, `avg_cpu_total_percent`, `samples` | Pool monitor across parallel ffmpeg processes; `samples` = number of monitor ticks | `peak_concurrent_ffmpeg = 0` + `samples = 0` means the phase finished faster than one monitor tick — not an error |
| `ff_fps` | ffmpeg's own reported encode fps (video sites only) | `0.0`/absent on audio-only sites by design |
| `ff_speed_x` | ffmpeg's reported speed vs realtime | Can be scientific notation (`1.39e+03x`); relates to the site's input duration |
| `ff_user_ms` / `ff_sys_ms` | ffmpeg `-benchmark` utime/stime (CPU time, all threads) | user+sys ÷ real ≈ cores actually busy |
| `ff_real_ms` | ffmpeg's own wall clock (`rtime`) | **Best cross-check**: compare to `elapsed_ms`; with capture active they should track each other |
| `ff_maxrss_kb` | ffmpeg's reported peak memory | Usually within a few % of harness `peak_rss_kb` |
| `ff_procs` | Aggregated entries only: number of ffmpeg processes summed | A chunk pipeline = split + N converts + concat (e.g. 10 for 8 chunks) |

### Gotchas / ambiguities

- **Labels are stable across GPU backends on purpose** — `encode_libx264` ran
  under `gpu: none` *and* `gpu: auto` (where the real encoder was h264_nvenc).
  Compare series **within** one `gpu` value, or use `gpu` as the distinguishing
  dimension. The actual backend is recorded in `gpu`, never in the label.
- **Difficulty confound in historical data.** Before GPU capture was added, all
  software (`none`) runs were recorded at `medium` difficulty and all `auto`
  runs at `low`. So `medium/none` vs `low/auto` contrasts mix *both* input size
  and backend. Cross-difficulty comparisons must use the **same** difficulty.
  Exception: the `conversion` benchmark pins its inputs regardless of difficulty
  (`test_short_1280x720_10s`, `test_default_1280x720_60s`), so its rows are
  comparable across `none`/`auto` — those are the right pairs for GPU analysis.
- **Missing `ff_*` fields.** Rows recorded before native `-benchmark` capture was
  wired (older runs) have harness metrics only. `--metric` skips rows that lack
  the requested field, so old rows don't pollute a trend.
- **`samples = 0` / `peak_pool_rss_kb = 0`** on very fast phases is expected
  (sub-tick), see table.
- **`produced_chunks` can exceed the requested count** with `-c copy` because
  keyframe intervals don't align with requested boundaries.

### Numbers measured so far (reference machine: RTX 2060, ffmpeg n9.0.1)

Annotated snapshot from the recorded history — good expectations for *this*
class of hardware, not a guarantee on any other machine:

| Workload | Software (x264/lame) | NVENC (`-g auto`) |
| -------- | ------------------- | ----------------- |
| mp4→mp4 re-encode, 60s 1280x720 | ~8.4 s, ~4 cores, ~348 MB | ~2.2 s, ~2 cores, ~284 MB (**~3.9×**) |
| mp4→mp4 re-encode, 10s 1280x720 | ~1.5 s | ~0.6 s (**~2.4×**) |
| mp4→mp3 audio extraction, 60s | ~0.45 s, ~1 core, ~56 MB (identical under `-g auto`: audio is never a GPU job) |
| stream copy (`-c copy`) | ~20–90 ms, ~0% CPU, ~10 MB |
| keyframe split (`-c copy`) | ~55–90 ms regardless of chunk count |
| frame-exact split (forced-keyframe re-encode) | ~5.3 s / 60s | ~2.2 s / 60s |

Observed rules of thumb:

- **GPU advantage grows with duration**: 2.4× at 10 s → 3.9× at 60 s. Time
  scales ~linearly with length; the ~200–500 ms ffmpeg startup/probe cost is a
  fixed add-on that matters most for short clips.
- **lame mp3 is single-threaded and preset-invariant**: `-threads 1` vs `auto`
  = 312 vs 313 ms; ultrafast→slow presets all ≈ 365 ms. Don't tune those.
- **Split once, copy cut often**: a keyframe-aligned re-encode costs ~2.2 s
  (GPU) once, then every timestamp cut is a ~85 ms stream copy.
- **Batch parallelism**: 2 jobs ≈ 92% efficient, 4 jobs ≈ 70%. More NVENC
  sessions contend on the shared encoder; more audio jobs contend on CPU decode.

### Reproducing and verifying

- Inputs are synthetic (`testsrc2` + sine) and generated with software encoders
  only, so media is identical across runs/backends. Drop real files into
  `inputs/` to benchmark those.
- To re-verify the GPU claims above on your box:
  `./run_benchmarks.sh -d medium -g none conversion`
  then `./run_benchmarks.sh -d medium -g auto conversion` and compare the
  `test_default_1280x720_60s` rows.
- Cross-check capture health: `ff_real_ms` should sit within ~10% of
  `elapsed_ms` on long encodes, and `ff_maxrss_kb` within a few % of
  `peak_rss_kb`.

## Installing just ffmpeg

```bash
./install.sh            # installs via apt / dnf / pacman / brew / MSYS2 pacman / choco / winget
```

## Notes

- Requires `bash`, `ffmpeg`, `ffprobe`, `awk`, `bc` is not required (all math
  is portable awk). `nproc`/`sysctl` are used where available.
- On Windows, run inside Git Bash / MSYS2.
- Test media is synthetic (testsrc2 + sine), so results are reproducible
  regardless of licensing. Drop your own files into `inputs/` to test those —
  the harness picks any file found. See `inputs/samples/README.md` for
  suggested freely-licensed mp3/mp4 files.
- Frame-splitting with `-c copy` only cuts at existing keyframes (reported in
  results as `produced_chunks`); use the `exact` split strategy for exact cuts.
- Tune sample resolution with `MONITOR_INTERVAL_MS` for resource benchmarks.