#!/usr/bin/env bash
# Benchmark: chunked mp4->mp3 conversion vs whole-file conversion
#
# Two chunking modes (combinable):
#   by-count  : split into N equal chunks
#   by-time   : split every N seconds
#
# Two splitting strategies per mode:
#   copy  (fast, keyframe-limited — may yield fewer chunks than asked)
#   exact (re-encodes video to force keyframes at every cut point)
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/_common.sh"

find_ffmpeg
ensure_dirs

INPUT=$(find_mp4_input)
DUR=$(get_duration)

CHUNK_COUNTS="${CHUNK_COUNTS:-2 4 8}"          # "1 2 4 8"
CHUNK_TIME="${CHUNK_TIME:-30}"
SPLIT_METHOD="${SPLIT_METHOD:-copy exact}"      # "copy" "exact" or both

CHUNK_DIR="$OUTPUTS_DIR/mp3/_chunk_bench"
TMP_VIDEO_DIR="$OUTPUTS_DIR/mp4/_chunk_tmp"
mkdir -p "$CHUNK_DIR" "$TMP_VIDEO_DIR"

log_bench "=== Chunked vs Whole-File Conversion Benchmark ==="
log_bench "Input: $(basename "$INPUT") | Duration: ${DUR}s | Methods: $SPLIT_METHOD"

json_begin

file_size_kb() { stat -c%s "$1" 2>/dev/null || stat -f%z "$1" 2>/dev/null || echo 0; }

# ============================================================
# BASELINE: Whole-file conversion
# ============================================================
log_bench "--- Baseline: Whole-file MP4 -> MP3 ---"
WHOLE_JSON=$(bench_run "whole_file_mp4_to_mp3" \
    $FFMPEG -i "$INPUT" -vn -c:a libmp3lame -b:a 192k \
        "$CHUNK_DIR/whole.mp3" -y -loglevel error -stats)
json_add "$WHOLE_JSON"
WHOLE_SIZE=$(file_size_kb "$CHUNK_DIR/whole.mp3")
log_bench "Whole-file: $WHOLE_JSON | size: ${WHOLE_SIZE}B"

# ============================================================
# Splitting helpers
# ============================================================
# split_<strategy> prints the number of chunks actually produced.
split_copy() {  # keyframe-limited, minimal cost
    local in_file="$1" seg_time="$2" out_prefix="$3"
    rm -f "$out_prefix"_*.mp4
    $FFMPEG -i "$in_file" -c copy \
        -f segment -segment_time "$seg_time" -reset_timestamps 1 \
        "$out_prefix"_%03d.mp4 -y -loglevel error -stats 2>/dev/null
    shopt -s nullglob
    printf '%s\n' "$out_prefix"_*.mp4 | wc -l | tr -d ' '
    shopt -u nullglob
}

split_exact() {  # re-encode with forced keyframes at every cut point
    local in_file="$1" seg_time="$2" out_prefix="$3"
    rm -f "$out_prefix"_*.mp4
    $FFMPEG -i "$in_file" $(video_enc_opts h264 crf 23 veryfast) \
        -c:a copy \
        -force_key_frames "expr:gte(t,n_forced*$seg_time)" \
        -f segment -segment_time "$seg_time" -reset_timestamps 1 \
        "$out_prefix"_%03d.mp4 -y -loglevel error -stats 2>/dev/null
    shopt -s nullglob
    printf '%s\n' "$out_prefix"_*.mp4 | wc -l | tr -d ' '
    shopt -u nullglob
}

convert_chunks_to_mp3() {
    local prefix="$1" listfile="$2" concatfile="$3"
    local chunk_files=()
    shopt -s nullglob
    chunk_files=("$prefix"_*.mp4)
    shopt -u nullglob

    : > "$listfile"
    for cfi in "${chunk_files[@]}"; do
        local mp3out="${cfi%.mp4}.mp3"
        $FFMPEG -i "$cfi" -vn -c:a libmp3lame -b:a 192k \
            "$mp3out" -y -loglevel error 2>/dev/null || true
        echo "file '$mp3out'" >> "$listfile"
    done

    local produced=0
    if [[ -s "$listfile" ]]; then
        if $FFMPEG -f concat -safe 0 -i "$listfile" -c copy \
            "$concatfile" -y -loglevel error 2>/dev/null; then
            produced=1
        fi
    fi
    echo "$produced"
}

run_chunked_pipeline() {
    local label="$1" seg_time="$2" split_fn="$3" prefix="$4" listfile="$5" concatfile="$6"
    local start_ms end_ms split_time convert_time total_ms
    local produced_chunks produced_concat

    start_ms=$(now_ms)

    produced_chunks=$("$split_fn" "$INPUT" "$seg_time" "$prefix")
    split_time=$(calc "($(now_ms) - $start_ms) / 1" 1)

    convert_start=$(now_ms)
    produced_concat=$(convert_chunks_to_mp3 "$prefix" "$listfile" "$concatfile")
    convert_time=$(calc "($(now_ms) - $convert_start) / 1" 1)

    end_ms=$(now_ms)
    total_ms=$(calc "($end_ms - $start_ms) / 1" 1)

    local out_size=0
    [[ -f "$concatfile" ]] && out_size=$(file_size_kb "$concatfile")

    local json
    json="{\"label\":\"$label\",\"chunk_seconds\":$seg_time,"
    json+="\"produced_chunks\":${produced_chunks:-0},"
    json+="\"split_ms\":${split_time:-0},"
    json+="\"convert_ms\":${convert_time:-0},"
    json+="\"total_ms\":$total_ms,"
    json+="\"concat_succeeded\":$produced_concat,"
    json+="\"output_bytes\":${out_size:-0}}"
    json_add "$json"
    log_bench "$label: total=${total_ms}ms (split=${split_time}ms + convert=${convert_time}ms), chunks=${produced_chunks:-0}"

    # Integer comparison for %chunks differs -> note (bounded estimate only)
}

# ============================================================
# METHOD 1: Chunk by COUNT
# ============================================================
resolve_backend h264
for n in $CHUNK_COUNTS; do
    seg_time=$(calc "$DUR / $n" 3)
    for method in $SPLIT_METHOD; do
        prefix="$TMP_VIDEO_DIR/chunk_${method}_count${n}"
        run_chunked_pipeline "chunk_by_count_${method}_${n}" \
            "$seg_time" "split_${method}" "$prefix" \
            "$CHUNK_DIR/list_count_${method}_${n}.txt" \
            "$CHUNK_DIR/chunked_count_${method}_${n}.mp3"
    done
done

# ============================================================
# METHOD 2: Chunk by TIME (every N seconds)
# ============================================================
for method in $SPLIT_METHOD; do
    prefix="$TMP_VIDEO_DIR/chunk_${method}_time${CHUNK_TIME}"
    run_chunked_pipeline "chunk_by_time_${method}_${CHUNK_TIME}s" \
        "$CHUNK_TIME" "split_${method}" "$prefix" \
        "$CHUNK_DIR/list_time_${method}_${CHUNK_TIME}.txt" \
        "$CHUNK_DIR/chunked_time_${method}_${CHUNK_TIME}.mp3"
done

# Cleanup
rm -rf "$CHUNK_DIR" "$TMP_VIDEO_DIR"

RESULT=$(assemble_result "chunked_vs_whole")

save_result "chunked_vs_whole" "$RESULT"
echo "$RESULT"
log_bench "=== Chunked vs Whole Benchmark Complete ==="