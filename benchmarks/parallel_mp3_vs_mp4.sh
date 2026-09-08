#!/usr/bin/env bash
# Benchmark: parallel mp3 conversion vs parallel mp4 re-encoding
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/_common.sh"

find_ffmpeg
ensure_dirs

PARALLEL_JOBS="${PARALLEL_JOBS:-4}"
INPUT_DIR="$INPUTS_DIR/mp4"
WORK_DIR_MP3="$OUTPUTS_DIR/mp3/_parmp3_bench"
WORK_DIR_MP4="$OUTPUTS_DIR/mp4/_parmp4_bench"
mkdir -p "$WORK_DIR_MP3" "$WORK_DIR_MP4"

INPUTS=($(find_all_mp4_inputs))
TOTAL_FILES=${#INPUTS[@]}

# Ensure we have enough files
if (( TOTAL_FILES < 4 )); then
    log_bench "Generating extra test files..."
    RES=$(get_resolution)
    BR=$(get_bitrate)
    FPS=$(get_framerate)
    for i in $(seq $TOTAL_FILES 3); do
        outf="$INPUT_DIR/mp3v4_extra_${i}.mp4"
        if [[ ! -f "$outf" ]]; then
            $FFMPEG -y -f lavfi \
                -i "testsrc2=duration=$(get_duration):size=${RES}:rate=${FPS}" \
                -f lavfi -i "sine=frequency=$((440+i*50)):duration=$(get_duration)" \
                -c:v libx264 -preset fast -b:v "$BR" \
                -c:a aac -b:a 128k -pix_fmt yuv420p \
                "$outf" -loglevel warning
        fi
        INPUTS+=("$outf")
    done
    TOTAL_FILES=${#INPUTS[@]}
fi

log_bench "=== Parallel MP3 vs Parallel MP4 Benchmark ==="
log_bench "Files: $TOTAL_FILES | Parallel jobs: $PARALLEL_JOBS"

json_begin

# --- Parallel MP4 -> MP3 ---
log_bench "Running parallel MP4 -> MP3 ($PARALLEL_JOBS jobs)..."
MP3_START=$(now_ms)
pids=(); active=0
for (( i=0; i<TOTAL_FILES; i++ )); do
    $FFMPEG -i "${INPUTS[$i]}" -vn -c:a libmp3lame -b:a 192k \
        "$WORK_DIR_MP3/out_${i}.mp3" -y -loglevel error 2>/dev/null &
    pids+=($!); active=$((active + 1))
    if (( active >= PARALLEL_JOBS )); then
        wait "${pids[0]}" 2>/dev/null || true
        pids=("${pids[@]:1}"); active=$((active - 1))
    fi
done
wait
MP3_END=$(now_ms)
MP3_MS=$(calc "($MP3_END - $MP3_START) / 1" 1)

mp3_total_size=$(find "$WORK_DIR_MP3" -name "*.mp3" -type f -exec stat -c%s {} + 2>/dev/null \
    | awk '{s+=$1}END{print s}' || echo 0)

MP3_JSON="{\"label\":\"parallel_mp4_to_mp3\",\"jobs\":$PARALLEL_JOBS,\"total_ms\":$MP3_MS,\"files\":$TOTAL_FILES,\"output_total_bytes\":$mp3_total_size}"
json_add "$MP3_JSON"
log_bench "Parallel MP3: ${MP3_MS}ms | output: $(calc "${mp3_total_size:-0}/1048576" 1)MB"

# --- Parallel MP4 -> MP4 (re-encode) ---
log_bench "Running parallel MP4 -> MP4 re-encode ($PARALLEL_JOBS jobs)..."
MP4_START=$(now_ms)
pids=(); active=0
for (( i=0; i<TOTAL_FILES; i++ )); do
    $FFMPEG -i "${INPUTS[$i]}" \
        -c:v libx264 -preset fast -crf 23 \
        -c:a aac -b:a 128k \
        "$WORK_DIR_MP4/out_${i}.mp4" -y -loglevel error 2>/dev/null &
    pids+=($!); active=$((active + 1))
    if (( active >= PARALLEL_JOBS )); then
        wait "${pids[0]}" 2>/dev/null || true
        pids=("${pids[@]:1}"); active=$((active - 1))
    fi
done
wait
MP4_END=$(now_ms)
MP4_MS=$(calc "($MP4_END - $MP4_START) / 1" 1)

mp4_total_size=$(find "$WORK_DIR_MP4" -name "*.mp4" -type f -exec stat -c%s {} + 2>/dev/null \
    | awk '{s+=$1}END{print s}' || echo 0)

MP4_JSON="{\"label\":\"parallel_mp4_to_mp4\",\"jobs\":$PARALLEL_JOBS,\"total_ms\":$MP4_MS,\"files\":$TOTAL_FILES,\"output_total_bytes\":$mp4_total_size}"
json_add "$MP4_JSON"
log_bench "Parallel MP4: ${MP4_MS}ms | output: $(calc "${mp4_total_size:-0}/1048576" 1)MB"

# Comparison
RATIO=$(calc "$MP4_MS / $MP3_MS" 2 2>/dev/null || echo "0")
log_bench "MP4 re-encode is ${RATIO}x slower than MP3 conversion"

rm -rf "$WORK_DIR_MP3" "$WORK_DIR_MP4"

RESULT=$(assemble_result "parallel_mp3_vs_mp4")

save_result "parallel_mp3_vs_mp4" "$RESULT"
echo "$RESULT"
log_bench "=== Parallel MP3 vs MP4 Benchmark Complete ==="
