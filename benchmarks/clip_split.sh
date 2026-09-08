#!/usr/bin/env bash
# Benchmark: clip splitting speed (segment by count and by timestamp)
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/_common.sh"

find_ffmpeg
ensure_dirs

INPUT=$(find_mp4_input)
DUR=$(get_duration)
SEGMENT_COUNT="${SEGMENT_COUNT:-4}"
SEGMENT_INTERVAL="${SEGMENT_INTERVAL:-30}"

log_bench "=== Clip Split Benchmark ==="
log_bench "Input: $(basename "$INPUT") | Duration: ${DUR}s"

SPLIT_DIR="$OUTPUTS_DIR/mp4/_split_bench"
mkdir -p "$SPLIT_DIR"

json_begin

# ============================================================
# PART 1: Split by count (N equal segments)
# ============================================================
log_bench "--- Split by count: $SEGMENT_COUNT segments ---"

# Method 1: Using -segment_time with total_duration / count
SEG_TIME=$(calc "$DUR / $SEGMENT_COUNT" 3)
log_bench "Segment time: ${SEG_TIME}s"

SPLIT_COUNT_JSON=$(bench_run "split_by_count_${SEGMENT_COUNT}" \
    $FFMPEG -i "$INPUT" \
        -c copy \
        -f segment -segment_time "$SEG_TIME" -reset_timestamps 1 \
        "$SPLIT_DIR/seg_count_%03d.mp4" \
        -y -loglevel error -stats)
json_add "$SPLIT_COUNT_JSON"

# Count produced segments
seg_count=$(find "$SPLIT_DIR" -name "seg_count_*.mp4" -type f | wc -l)
log_bench "Produced $seg_count segments"

# Method 2: Using -ss/-t for each segment (manual split)
log_bench "Split by count (manual -ss/-t method)..."
SEGS_MANUAL=()
MANUAL_TOTAL_START=$(now_ms)

for (( i=0; i<SEGMENT_COUNT; i++ )); do
    offset=$(calc "$i * $SEG_TIME" 3)
    outfile="$SPLIT_DIR/seg_manual_${i}.mp4"
    $FFMPEG -ss "$offset" -i "$INPUT" -t "$SEG_TIME" \
        -c copy "$outfile" -y -loglevel error 2>/dev/null
    SEGS_MANUAL+=("$outfile")
done

MANUAL_TOTAL_END=$(now_ms)
MANUAL_ELAPSED_MS=$(calc "($MANUAL_TOTAL_END - $MANUAL_TOTAL_START) / 1" 1)
MANUAL_JSON="{\"label\":\"split_by_count_manual_${SEGMENT_COUNT}\",\"elapsed_ms\":$MANUAL_ELAPSED_MS,\"segments\":$SEGMENT_COUNT}"
json_add "$MANUAL_JSON"

# ============================================================
# PART 2: Split by timestamp (every N seconds)
# ============================================================
log_bench "--- Split by timestamp: every ${SEGMENT_INTERVAL}s ---"

# Calculate how many segments we expect
EXPECTED_SEGS=$(calc "int(($DUR + $SEGMENT_INTERVAL - 1) / $SEGMENT_INTERVAL)" 0)
log_bench "Expected segments: ~$EXPECTED_SEGS"

SPLIT_TS_JSON=$(bench_run "split_by_timestamp_${SEGMENT_INTERVAL}s" \
    $FFMPEG -i "$INPUT" \
        -c copy \
        -f segment -segment_time "$SEGMENT_INTERVAL" -reset_timestamps 1 \
        "$SPLIT_DIR/seg_ts_%03d.mp4" \
        -y -loglevel error -stats)
json_add "$SPLIT_TS_JSON"

ts_seg_count=$(find "$SPLIT_DIR" -name "seg_ts_*.mp4" -type f | wc -l)
log_bench "Produced $ts_seg_count segments (timestamp-based)"

# ============================================================
# PART 3: Split with re-encode (forces keyframe alignment)
# ============================================================
log_bench "--- Split by timestamp with re-encode: every ${SEGMENT_INTERVAL}s ---"

SPLIT_REENC_JSON=$(bench_run "split_by_timestamp_reencode_${SEGMENT_INTERVAL}s" \
    $FFMPEG -i "$INPUT" \
        -c:v libx264 -preset fast -crf 23 \
        -c:a aac -b:a 128k \
        -f segment -segment_time "$SEGMENT_INTERVAL" -reset_timestamps 1 \
        "$SPLIT_DIR/seg_reenc_%03d.mp4" \
        -y -loglevel error -stats)
json_add "$SPLIT_REENC_JSON"

reenc_seg_count=$(find "$SPLIT_DIR" -name "seg_reenc_*.mp4" -type f | wc -l)
log_bench "Produced $reenc_seg_count segments (re-encoded)"

# Cleanup split files
rm -rf "$SPLIT_DIR"

RESULT=$(assemble_result "clip_split")

save_result "clip_split" "$RESULT"
echo "$RESULT"
log_bench "=== Clip Split Benchmark Complete ==="
