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
│   └── resource_efficiency.sh      Peak memory, CPU%, parallel contention
├── inputs/                        Your media goes here (or auto-generated)
│   ├── mp4/   test_default_*.mp4, test_short_*.mp4
│   └── mp3/   test_default_*.mp3, test_short_*.mp3
└── outputs/
    ├── mp4/                         Benchmark artifacts (re-encoded files)
    └── mp3/                         Converted outputs
```

All results land in `results/*.json`.

## Usage

```bash
./run_benchmarks.sh                        # all benchmarks, medium
./run_benchmarks.sh speed conversion       # only specific benchmarks
./run_benchmarks.sh -d high                # resolution/bitrate preset
./run_benchmarks.sh -j 8 parallel_vs_sequential
./run_benchmarks.sh -n 2,4,8 -t 30 chunked_vs_whole
```

### Options

| Option | Description | Default |
| ------ | ----------- | ------- |
| `-d, --difficulty` | `low` \| `medium` \| `high` \| `ultra` | `medium` |
| `-j, --jobs` | Parallel jobs for parallel benches | `4` |
| `-n, --chunk-counts` | Chunk counts for chunked bench | `2 4 8` |
| `-t, --chunk-time` | Chunk-by-timestamp interval (s) | `30` |
| `-c, --chunks` | Segment count for clip_split | `4` |

Each benchmark can also be run on its own, e.g. `./benchmarks/speed.sh`,
and honors environment variables (`DIFFICULTY`, `PARALLEL_JOBS`, `CHUNK_COUNTS`,
`CHUNK_TIME`, `SEGMENT_COUNT`, `MONITOR_INTERVAL_MS`, `SPLIT_METHOD`).

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
  the harness picks any file found.
- Frame-splitting with `-c copy` only cuts at existing keyframes (reported in
  results as `produced_chunks`); use the `exact` split strategy for exact cuts.
- Tune sample resolution with `MONITOR_INTERVAL_MS` for resource benchmarks.