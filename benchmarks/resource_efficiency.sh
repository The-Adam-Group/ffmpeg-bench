#!/usr/bin/env bash
# Benchmark: resource efficiency (peak memory, CPU utilization)
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/_common.sh"

find_ffmpeg
ensure_dirs

INPUT=$(find_mp4_input)
DUR=$(get_duration)
MONITOR_INTERVAL_MS="${MONITOR_INTERVAL_MS:-100}"
RESOURCES_DIR="$OUTPUTS_DIR/mp3/_resource_bench"
mkdir -p "$RESOURCES_DIR"

log_bench "=== Resource Efficiency Benchmark ==="
log_bench "Input: $(basename "$INPUT") | Monitor interval: ${MONITOR_INTERVAL_MS}ms"

json_begin

# ============================================================
# 1. Single-threaded conversion (limited threads)
# ============================================================
log_bench "--- MP4 -> MP3 with 1 thread ---"
$FFMPEG -i "$INPUT" -vn -c:a libmp3lame -b:a 192k -threads 1 \
    "$RESOURCES_DIR/single_thread.mp3" -y -loglevel error &
FF_PID=$!

RES1=$(monitor_process "$FF_PID" "$MONITOR_INTERVAL_MS" "$DUR")
wait "$FF_PID"
json_add "{\"label\":\"mp4_to_mp3_singlethread\",\"threads\":1,$(echo "$RES1" | sed 's/^{//;s/}$//')}"
log_bench "Single-thread stats: $RES1"

# ============================================================
# 2. Multi-threaded conversion (default threads)
# ============================================================
log_bench "--- MP4 -> MP3 with default threads ---"
$FFMPEG -i "$INPUT" -vn -c:a libmp3lame -b:a 192k \
    "$RESOURCES_DIR/multi_thread.mp3" -y -loglevel error &
FF_PID=$!

RES2=$(monitor_process "$FF_PID" "$MONITOR_INTERVAL_MS" "$DUR")
wait "$FF_PID"
json_add "{\"label\":\"mp4_to_mp3_multithread\",\"threads\":\"auto\",$(echo "$RES2" | sed 's/^{//;s/}$//')}"
log_bench "Multi-thread stats: $RES2"

# ============================================================
# 3. MP4 re-encode (heavier: video + audio)
# ============================================================
log_bench "--- MP4 -> MP4 re-encode ---"
$FFMPEG -i "$INPUT" -c:v libx264 -preset fast -crf 23 \
    -c:a aac -b:a 128k \
    "$RESOURCES_DIR/reencode.mp4" -y -loglevel error &
FF_PID=$!

RES3=$(monitor_process "$FF_PID" "$MONITOR_INTERVAL_MS" "$DUR")
wait "$FF_PID"
json_add "{\"label\":\"mp4_to_mp4_reencode\",\"threads\":\"auto\",$(echo "$RES3" | sed 's/^{//;s/}$//')}"
log_bench "Re-encode stats: $RES3"

# ============================================================
# 4. Parallel conversions (resource contention)
# ============================================================
log_bench "--- 2 parallel MP4 -> MP3 conversions ---"
NPROC_JOBS=2
$FFMPEG -i "$INPUT" -vn -c:a libmp3lame -b:a 192k \
    "$RESOURCES_DIR/par1.mp3" -y -loglevel error &
P1=$!
$FFMPEG -i "$INPUT" -vn -c:a libmp3lame -b:a 192k \
    "$RESOURCES_DIR/par2.mp3" -y -loglevel error &
P2=$!

# Track combined resource usage — monitor BOTH processes concurrently
monitor_process "$P1" "$MONITOR_INTERVAL_MS" "$DUR" > "$RESOURCES_DIR/mon1.json" &
M1=$!
monitor_process "$P2" "$MONITOR_INTERVAL_MS" "$DUR" > "$RESOURCES_DIR/mon2.json" &
M2=$!
wait "$M1" "$M2"
PRES1=$(cat "$RESOURCES_DIR/mon1.json")
PRES2=$(cat "$RESOURCES_DIR/mon2.json")
wait $P1 $P2

json_add "{\"label\":\"mp4_to_mp3_parallel2_proc1\",\"threads\":\"auto\",$(echo "$PRES1" | sed 's/^{//;s/}$//')}"
json_add "{\"label\":\"mp4_to_mp3_parallel2_proc2\",\"threads\":\"auto\",$(echo "$PRES2" | sed 's/^{//;s/}$//')}"
log_bench "Parallel proc1: $PRES1"
log_bench "Parallel proc2: $PRES2"

# ============================================================
# 5. Video decode pipelining (stream copy vs re-encode)
# ============================================================
log_bench "--- MP4 stream copy (no re-encode) ---"
$FFMPEG -i "$INPUT" -c copy "$RESOURCES_DIR/copy.mp4" -y -loglevel error &
FF_PID=$!

RES4=$(monitor_process "$FF_PID" "$MONITOR_INTERVAL_MS" "$DUR")
wait "$FF_PID"
json_add "{\"label\":\"mp4_stream_copy\",\"threads\":\"auto\",$(echo "$RES4" | sed 's/^{//;s/}$//')}"
log_bench "Stream copy stats: $RES4"

rm -rf "$RESOURCES_DIR"

RESULT=$(assemble_result "resource_efficiency")

save_result "resource_efficiency" "$RESULT"
echo "$RESULT"
log_bench "=== Resource Efficiency Benchmark Complete ==="
