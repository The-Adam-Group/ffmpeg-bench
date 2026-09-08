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
    chunked_vs_whole        Chunked vs whole-file conversion
    resource_efficiency     Peak memory + CPU utilization

Options:
    -d, --difficulty LEVEL   low|medium|high|ultra (default: medium)
    -j, --jobs N             Max parallel jobs for parallel benchmarks (default: 4)
    -n, --chunk-counts N     Comma-separated chunk counts for chunked bench (default: 2,4,8)
    -t, --chunk-time S       Chunk by timestamp interval in seconds (default: 30)
    -c, --chunks N           Segment count for clip_split (default: 4)
    -h, --help               Show this help

Examples:
    $0                          # Run all benchmarks (medium difficulty)
    $0 -d high speed            # High difficulty, speed only
    $0 -j 2 chunked_vs_whole    # Chunked bench, 2 parallel jobs
    $0 -n 2,6 -t 15 chunked_vs_whole
EOF
}

DIFFICULTY="${DIFFICULTY:-medium}"
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

validate_selection

# Export shared config
export DIFFICULTY PARALLEL_JOBS CHUNK_COUNTS CHUNK_TIME SEGMENT_COUNT

log "=== FFmpeg Benchmark Suite ==="
log "Difficulty: $DIFFICULTY"
log "Parallel jobs: $PARALLEL_JOBS"
log "Benchmarks to run: ${SELECTED[*]}"
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
        ok "    Result: $(ls -t results/${b}_*.json 2>/dev/null | head -1)"
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
fi
