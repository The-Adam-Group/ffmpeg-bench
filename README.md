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
```

`history.jsonl` is plain line-delimited JSON, so you can diff runs or grep them.

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