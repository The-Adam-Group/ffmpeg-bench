#!/usr/bin/env bash
# Main benchmark runner — executes all benchmarks or a subset
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BENCH_DIR="$SCRIPT_DIR/benchmarks"

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
NC='\033[0m'

log()  { echo -e "${CYAN}[bench]${NC} $*"; }
warn() { echo -e "${YELLOW}[bench]${NC} $*" >&2; }
err()  { echo -e "${RED}[bench]${NC} $*" >&2; }
ok()   { echo -e "${GREEN}[bench]${NC} $*"; }

ALL_BENCHMARKS=(
    "hardware_info"
    "speed"
    "conversion"
    "clip_split"
    "parallel_vs_sequential"
    "parallel_mp3_vs_mp4"
    "mp3_vs_mp4"
    "chunked_vs_whole"
    "resource_efficiency"
)

usage() {
    cat <<EOF
Usage: $0 [options] [benchmark...]

Benchmarks to run (default: all):
    hardware_info           System + ffmpeg capability dump
    speed                   Raw encode/decode speeds
    conversion              MP4->MP3 conversion time
    clip_split              Clip splitting speed
    parallel_vs_sequential  Parallel vs sequential throughput
    parallel_mp3_vs_mp4     Parallel mp3 conversion vs parallel mp4 re-encode
    mp3_vs_mp4              Split/chunk/process: mp3 pipeline vs mp4 pipeline
    chunked_vs_whole        Chunked vs whole-file conversion
    resource_efficiency     Peak memory + CPU utilization

Options:
    -d, --difficulty LEVEL   low|medium|high|ultra (default: medium)
    -j, --jobs N             Max parallel jobs for parallel benchmarks (default: 4)
    -n, --chunk-counts N     Comma-separated chunk counts for chunked bench (default: 2,4,8)
    -t, --chunk-time S       Chunk by timestamp interval in seconds (default: 30)
    -c, --chunks N           Segment count for clip_split (default: 4)
    -g, --gpu MODE           Hardware encode: none|auto|nvenc|qsv|amf|vaapi|videotoolbox
                             or a raw encoder name (default: none). See README.
    -R, --no-record          Don't append this run to results/history.jsonl

Examples:
    $0                          # Run all benchmarks (medium difficulty)
    $0 -d high speed            # High difficulty, speed only
    $0 -j 2 chunked_vs_whole    # Chunked bench, 2 parallel jobs
    $0 -n 2,6 -t 15 chunked_vs_whole
    $0 -g auto speed            # Speed with the first available HW encoder
    $0 -g nvenc                 # Force NVIDIA NVENC everywhere
    $0 speed conversion; tools/graph_report.sh   # chart recorded history
EOF
}

DIFFICULTY="${DIFFICULTY:-medium}"
GPU_MODE="${GPU_MODE:-none}"
RRECORD=1
PARALLEL_JOBS=4
CHUNK_COUNTS="2 4 8"
CHUNK_TIME=30
SEGMENT_COUNT=4

SELECTED=()
while (( $# > 0 )); do
    case "$1" in
        -d|--difficulty)
            DIFFICULTY="$2"; shift 2;;
        -j|--jobs)
            PARALLEL_JOBS="$2"; shift 2;;
        -n|--chunk-counts)
            CHUNK_COUNTS=$(echo "$2" | tr ',' ' '); shift 2;;
        -t|--chunk-time)
            CHUNK_TIME="$2"; shift 2;;
        -c|--chunks)
            SEGMENT_COUNT="$2"; shift 2;;
        -g|--gpu)
            GPU_MODE="$2"; shift 2;;
        -R|--no-record)
            RRECORD=0; shift;;
        -h|--help)
            usage; exit 0;;
        -*) 
            err "Unknown option: $1"; usage; exit 1;;
        *)
            SELECTED+=("$1"); shift;;
    esac
done

if (( ${#SELECTED[@]} == 0 )); then
    SELECTED=("${ALL_BENCHMARKS[@]}")
fi

validate_selection() {
    local b
    for b in "${SELECTED[@]}"; do
        local found=false
        for a in "${ALL_BENCHMARKS[@]}"; do
            [[ "$b" == "$a" ]] && found=true
        done
        if ! $found; then
            err "Unknown benchmark: '$b'"
            usage
            exit 1
        fi
        if [[ ! -f "$BENCH_DIR/$b.sh" ]]; then
            err "Benchmark file missing: $BENCH_DIR/$b.sh"
            exit 1
        fi
    done
}

# Check prerequisites
if ! command -v ffmpeg &>/dev/null; then
    err "ffmpeg not found. Run ./install.sh first."
    exit 1
fi
if ! command -v awk &>/dev/null; then
    err "'awk' not found — required for arithmetic. This is extremely rare."
    exit 1
fi
case "$GPU_MODE" in
    none|auto|nvenc|qsv|amf|vaapi|videotoolbox) ;;
    *) warn "GPU_MODE '$GPU_MODE' is not a known backend — it will be tried as a literal encoder name." ;;
esac

validate_selection

# Export shared config
export DIFFICULTY GPU_MODE PARALLEL_JOBS CHUNK_COUNTS CHUNK_TIME SEGMENT_COUNT

log "=== FFmpeg Benchmark Suite ==="
log "Difficulty: $DIFFICULTY | GPU: $GPU_MODE"
log "Parallel jobs: $PARALLEL_JOBS"
log "Benchmarks to run: ${SELECTED[*]}"
if (( RRECORD )); then
    log "Recording history: results/history.jsonl"
fi
echo ""

SUMMARY_START=$(date +%s)
FAILED=()

for b in "${SELECTED[@]}"; do
    echo ""
    log ">>> Starting: $b"
    t0=$(date +%s)
    if bash "$BENCH_DIR/$b.sh"; then
        t1=$(date +%s)
        ok ">>> Finished: $b ($((t1 - t0))s)"
        RESULT_FILE=$(ls -t results/${b}*.json 2>/dev/null | head -1 || true)
        ok "    Result: ${RESULT_FILE:-none}"
        if (( RRECORD )) && [[ -n "$RESULT_FILE" ]]; then
            if bash "$SCRIPT_DIR/tools/_record.sh" "$RESULT_FILE"; then
                ok "    Recorded -> results/history.jsonl"
            else
                warn "    History record failed for $b (results still saved)"
            fi
        fi
    else
        t1=$(date +%s)
        err ">>> Failed: $b"
        FAILED+=("$b")
    fi
    echo ""
done

SUMMARY_END=$(date +%s)
TOTAL_TIME=$((SUMMARY_END - SUMMARY_START))

echo ""
log "=== Benchmark Suite Complete ==="
log "Total time: ${TOTAL_TIME}s"
if (( ${#FAILED[@]} > 0 )); then
    err "Failed benchmarks: ${FAILED[*]}"
    exit 1
else
    ok "All benchmarks passed."
    ok "Charts: run 'tools/graph_report.sh' -> results/report.html"
fi
