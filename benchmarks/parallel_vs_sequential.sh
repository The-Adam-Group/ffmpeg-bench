#!/usr/bin/env bash
# Benchmark: parallel vs sequential conversion throughput
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/_common.sh"

find_ffmpeg
ensure_dirs

PARALLEL_COUNTS="${PARALLEL_COUNTS:-1 2 4}"
INPUT_DIR="$INPUTS_DIR/mp4"
WORK_DIR="$OUTPUTS_DIR/mp4/_parallel_bench"
mkdir -p "$WORK_DIR"

# Collect all input mp4 files (generate extras if needed)
INPUTS=($(find_all_mp4_inputs))
if (( ${#INPUTS[@]} < 4 )); then
    log_bench "Generating extra test files for parallel benchmark..."
    RES=$(get_resolution)
    BR=$(get_bitrate)
    FPS=$(get_framerate)
    for i in $(seq ${#INPUTS[@]} 4); do
        outf="$INPUT_DIR/parallel_extra_${i}.mp4"
        if [[ ! -f "$outf" ]]; then
            $FFMPEG -y -f lavfi \
                -i "testsrc2=duration=$(get_duration):size=${RES}:rate=${FPS}" \
                -f lavfi -i "sine=frequency=$((440 + i*100)):duration=$(get_duration)" \
                -c:v libx264 -preset fast -b:v "$BR" \
                -c:a aac -b:a 128k -pix_fmt yuv420p \
                "$outf" -loglevel warning
        fi
        INPUTS+=("$outf")
    done
fi

TOTAL_FILES=${#INPUTS[@]}
log_bench "=== Parallel vs Sequential Benchmark ==="
log_bench "Files: $TOTAL_FILES | Parallel counts: $PARALLEL_COUNTS"

json_begin

convert_one() {
    local src="$1" dst="$2"
    $FFMPEG -i "$src" -vn -c:a libmp3lame -b:a 192k \
        "$dst" -y -loglevel error 2>/dev/null
}

# --- Sequential (jobs=1) ---
log_bench "Running SEQUENTIAL conversion ($TOTAL_FILES files)..."
SEQ_START=$(now_ms)
for (( i=0; i<TOTAL_FILES; i++ )); do
    convert_one "${INPUTS[$i]}" "$WORK_DIR/seq_${i}.mp3"
done
SEQ_END=$(now_ms)
SEQ_MS=$(calc "($SEQ_END - $SEQ_START) / 1" 1)
SEQ_JSON="{\"label\":\"sequential_j1\",\"jobs\":1,\"total_ms\":$SEQ_MS,\"files\":$TOTAL_FILES}"
json_add "$SEQ_JSON"
log_bench "Sequential: ${SEQ_MS}ms"

# --- Parallel at various job counts ---
for jobs in $PARALLEL_COUNTS; do
    if (( jobs <= 1 )); then continue; fi

    log_bench "Running PARALLEL conversion ($TOTAL_FILES files, $jobs jobs)..."
    rm -f "$WORK_DIR"/par_*.mp3

    PAR_START=$(now_ms)
    pids=()
    active=0
    idx=0

    for (( i=0; i<TOTAL_FILES; i++ )); do
        convert_one "${INPUTS[$i]}" "$WORK_DIR/par_${jobs}_${i}.mp3" &
        pids+=($!)
        active=$((active + 1))

        if (( active >= jobs )); then
            wait "${pids[0]}" 2>/dev/null || true
            pids=("${pids[@]:1}")
            active=$((active - 1))
        fi
    done
    wait

    PAR_END=$(now_ms)
    PAR_MS=$(calc "($PAR_END - $PAR_START) / 1" 1)
    SPEEDUP=$(calc "$SEQ_MS / $PAR_MS" 2 2>/dev/null || echo "0")
    EFF=$(calc "$SPEEDUP / $jobs * 100" 2 2>/dev/null || echo "0")

    PAR_JSON="{\"label\":\"parallel_j${jobs}\",\"jobs\":$jobs,\"total_ms\":$PAR_MS,\"files\":$TOTAL_FILES,\"speedup\":$SPEEDUP,\"efficiency_percent\":$EFF}"
    json_add "$PAR_JSON"
    log_bench "Parallel(j=$jobs): ${PAR_MS}ms | speedup: ${SPEEDUP}x | efficiency: ${EFF}%"
done

rm -rf "$WORK_DIR"

RESULT=$(assemble_result "parallel_vs_sequential")

save_result "parallel_vs_sequential" "$RESULT"
echo "$RESULT"
log_bench "=== Parallel vs Sequential Benchmark Complete ==="
