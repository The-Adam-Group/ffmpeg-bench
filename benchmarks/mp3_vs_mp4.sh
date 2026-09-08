#!/usr/bin/env bash
# Benchmark: MP3 vs MP4 — splitting, chunking, processing
#
# For every operation the mp3 pipeline and the mp4 pipeline run side by side
# on inputs of identical duration, reporting wall time, produced chunks, and
# resource usage (peak memory, CPU%, concurrency).
#
# Sections:
#   splitting  : cut by timestamp / by count   (copy, container-agnostic)
#   chunking   : split -> convert each chunk -> concatenate
#   processing : mp3->mp3, mp4->mp4, mp4->mp3, mp3->mp4 with resource monitor
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/_common.sh"

find_ffmpeg
ensure_dirs

VIDEO_IN=$(find_mp4_input)
AUDIO_IN=$(find_mp3_input)
DUR=$(get_duration)

CHUNK_COUNTS="${CHUNK_COUNTS:-2 4 8}"
CHUNK_TIME="${CHUNK_TIME:-30}"

WORK_DIR="$OUTPUTS_DIR/mp3/_av_bench"
mkdir -p "$WORK_DIR"

log_bench "=== MP3 vs MP4 Benchmark ==="
log_bench "Video/audio-duration: ${DUR}s | inputs: $(basename "$VIDEO_IN") / $(basename "$AUDIO_IN")"
log_bench "Chunk counts: $CHUNK_COUNTS | chunk time: ${CHUNK_TIME}s"

json_begin

file_size_kb() { stat -c%s "$1" 2>/dev/null || stat -f%z "$1" 2>/dev/null || echo 0; }

# --- pools: monitor all ffmpeg procs for a phase; output to a json file ---
# Note: wait must run in the parent shell, NOT inside $(), otherwise the
# background child isn't a child of the subshell.
start_pool_monitor() {   # arg: output file
    monitor_ffmpeg_pool 100 "$((DUR * 2 + 30))" > "$1" &
    __pool_pid=$!
}
stop_pool_monitor() {    # wait for the running pool monitor (parent scope!)
    wait "$__pool_pid" 2>/dev/null || true
}
read_pool_monitor() {    # arg: output file -> stats json (or empty)
    cat "$1" 2>/dev/null || echo '{"samples":0}'
}

# ============================================================
# HELPERS: split (echoes produced chunk count)
# ============================================================
split_mp4() {   # in seg_time prefix
    local in="$1" seg_time="$2" prefix="$3"
    rm -f "$prefix"_*.mp4
    $FFMPEG -i "$in" -c copy \
        -f segment -segment_time "$seg_time" -reset_timestamps 1 \
        "$prefix"_%03d.mp4 -y -loglevel error -stats 2>/dev/null
    shopt -s nullglob
    printf '%s\n' "$prefix"_*.mp4 | wc -l | tr -d ' '
    shopt -u nullglob
}

split_mp3() {   # mp3 splits sample-accurately (frame-aligned) with -c copy
    local in="$1" seg_time="$2" prefix="$3"
    rm -f "$prefix"_*.mp3
    $FFMPEG -i "$in" -c copy \
        -f segment -segment_time "$seg_time" -reset_timestamps 1 \
        "$prefix"_%03d.mp3 -y -loglevel error -stats 2>/dev/null
    shopt -s nullglob
    printf '%s\n' "$prefix"_*.mp3 | wc -l | tr -d ' '
    shopt -u nullglob
}

unique_words() {
    local seen="" w
    for w in "$@"; do
        [[ " $seen " == *" $w "* ]] && continue
        seen="$seen $w"
        echo "$w"
    done
}

run_split_bench() {
    local format="$1" seg_time="$2" method="$3" prefix="$4"
    local label="${method}_${format}_${seg_time}s"
    local produced count start_ms end_ms mon_json stats elapsed_ms

    start_ms=$(now_ms)
    mon_json="$WORK_DIR/mon_${label}.json"
    start_pool_monitor "$mon_json"

    if [[ "$format" == mp3 ]]; then
        produced=$(split_mp3 "$AUDIO_IN" "$seg_time" "$prefix")
    else
        produced=$(split_mp4 "$VIDEO_IN" "$seg_time" "$prefix")
    fi
    count=${produced:-0}

    end_ms=$(now_ms)
    stop_pool_monitor
    stats=$(read_pool_monitor "$mon_json")
    elapsed_ms=$(calc "($end_ms - $start_ms) / 1" 1)

    json_add "{\"label\":\"$label\",\"format\":\"$format\",\"chunk_seconds\":$seg_time,\"elapsed_ms\":$elapsed_ms,\"produced_chunks\":$count,$(echo "$stats" | sed 's/^{//;s/}$//')}"
    log_bench "$label: ${elapsed_ms}ms, ${count} chunks"
}

# ============================================================
# SPLITTING: mp3 vs mp4
# ============================================================
SPLIT_TIMES=$(unique_words "${CHUNK_TIME}" "$(calc "$DUR / 2" 0)")
log_bench "--- Splitting by timestamp ---"
for t in $SPLIT_TIMES; do
    run_split_bench mp3 "$t" split_time "$WORK_DIR/mp3_time_$t"
    run_split_bench mp4 "$t" split_time "$WORK_DIR/mp4_time_$t"
done

log_bench "--- Splitting by count ---"
for n in $CHUNK_COUNTS; do
    t=$(calc "$DUR / $n" 3)
    run_split_bench mp3 "$t" split_count "$WORK_DIR/mp3_count_${n}"
    run_split_bench mp4 "$t" split_count "$WORK_DIR/mp4_count_${n}"
done

# ============================================================
# CHUNKING: split -> convert -> concat (same final format: mp3)
# ============================================================
convert_mp4_chunks() {   # prefix listfile concatfile
    local prefix="$1" listfile="$2" concatfile="$3" files=()
    shopt -s nullglob
    files=("$prefix"_*.mp4)
    shopt -u nullglob
    : > "$listfile"
    for cfi in "${files[@]}"; do
        local out="${cfi%.mp4}.mp3"
        $FFMPEG -i "$cfi" -vn -c:a libmp3lame -b:a 192k "$out" -y -loglevel error 2>/dev/null || true
        echo "file '$out'" >> "$listfile"
    done
    [[ -s "$listfile" ]] && $FFMPEG -f concat -safe 0 -i "$listfile" -c copy "$concatfile" -y -loglevel error 2>/dev/null || true
}

convert_mp3_chunks() {   # prefix listfile concatfile (re-encode each chunk)
    local prefix="$1" listfile="$2" concatfile="$3" files=()
    shopt -s nullglob
    files=("$prefix"_*.mp3)
    shopt -u nullglob
    : > "$listfile"
    for cfi in "${files[@]}"; do
        local out="${cfi%.mp3}_reenc.mp3"
        $FFMPEG -i "$cfi" -c:a libmp3lame -b:a 192k "$out" -y -loglevel error 2>/dev/null || true
        echo "file '$out'" >> "$listfile"
    done
    [[ -s "$listfile" ]] && $FFMPEG -f concat -safe 0 -i "$listfile" -c copy "$concatfile" -y -loglevel error 2>/dev/null || true
}

run_chunk_bench() {
    local format="$1" seg_time="$2" prefix="$3" method="$4"
    local label="chunk_${method}_${format}_${seg_time}s"
    local listfile="$WORK_DIR/list_${label}.txt"
    local concatfile="$WORK_DIR/${label}.mp3"
    local mon_json="$WORK_DIR/mon_${label}.json"
    local start_ms mid_ms end_ms produced stats
    local split_ms convert_ms total_ms out_size=0

    start_pool_monitor "$mon_json"
    start_ms=$(now_ms)

    if [[ "$format" == mp3 ]]; then
        produced=$(split_mp3 "$AUDIO_IN" "$seg_time" "$prefix")
        convert_mp3_chunks "$prefix" "$listfile" "$concatfile"
    else
        produced=$(split_mp4 "$VIDEO_IN" "$seg_time" "$prefix")
        convert_mp4_chunks "$prefix" "$listfile" "$concatfile"
    fi
    mid_ms=$(now_ms)
    end_ms=$(now_ms)

    stop_pool_monitor
    stats=$(read_pool_monitor "$mon_json")
    split_ms=$(calc "($mid_ms - $start_ms) / 1" 1)
    # convert phase = everything not split (mid sampled right after split returns)
    convert_ms=$(calc "($end_ms - $mid_ms) / 1" 1)
    total_ms=$(calc "($end_ms - $start_ms) / 1" 1)

    [[ -f "$concatfile" ]] && out_size=$(file_size_kb "$concatfile")

    json_add "{\"label\":\"$label\",\"format\":\"$format\",\"chunk_seconds\":$seg_time,\"produced_chunks\":${produced:-0},\"split_ms\":$split_ms,\"convert_ms\":$convert_ms,\"total_ms\":$total_ms,\"output_bytes\":$out_size,$(echo "$stats" | sed 's/^{//;s/}$//')}"
    log_bench "$label: total=${total_ms}ms (split=${split_ms}ms convert=${convert_ms}ms), ${produced:-0} chunks"
}

log_bench "--- Chunking by timestamp ---"
for t in $SPLIT_TIMES; do
    run_chunk_bench mp3 "$t" "$WORK_DIR/mp3_ck_${t}" chunk_time
    run_chunk_bench mp4 "$t" "$WORK_DIR/mp4_ck_${t}" chunk_time
done

log_bench "--- Chunking by count ---"
for n in $CHUNK_COUNTS; do
    t=$(calc "$DUR / $n" 3)
    run_chunk_bench mp3 "$t" "$WORK_DIR/mp3_ckc_${n}" chunk_count
    run_chunk_bench mp4 "$t" "$WORK_DIR/mp4_ckc_${n}" chunk_count
done

# ============================================================
# PROCESSING: full-transcode workloads with per-process monitoring
# ============================================================
run_processing_bench() {
    local label="$1" input="$2" output="$3"
    shift 3
    local start_ms end_ms
    local stats
    local mon_json="$WORK_DIR/mon_${label}.json"

    log_bench "Processing: $label"
    start_ms=$(now_ms)

    $FFMPEG -i "$input" "$@" "$output" -y -loglevel error &
    FF_PID=$!
    monitor_process "$FF_PID" 100 "$DUR" > "$mon_json" &
    MON_PID=$!
    wait "$MON_PID"
    wait "$FF_PID" 2>/dev/null || true

    end_ms=$(now_ms)
    elapsed_ms=$(calc "($end_ms - $start_ms) / 1" 1)

    stats=$(cat "$mon_json" 2>/dev/null)
    local speed_x wall_s
    wall_s=$(calc "$elapsed_ms / 1000" 3)
    speed_x=$(calc "$DUR / $wall_s" 2)

    if [[ -z "${stats:-}" ]]; then
        stats='{"peak_rss_kb":0,"avg_cpu_percent":0,"samples":0}'
    fi

    json_add "{\"label\":\"$label\",\"input_format\":\"${label%%_*}\",\"elapsed_ms\":$elapsed_ms,\"speed_x\":$speed_x,$(echo "$stats" | sed 's/^{//;s/}$//')}"
    log_bench "  $label: ${elapsed_ms}ms (${speed_x}x) | $stats"
}

run_processing_bench "mp3_to_mp3" "$AUDIO_IN" "$WORK_DIR/p_mp3.mp3" \
    -c:a libmp3lame -b:a 192k

run_processing_bench "mp4_to_mp4" "$VIDEO_IN" "$WORK_DIR/p_mp4.mp4" \
    -c:v libx264 -preset fast -crf 23 -c:a aac -b:a 128k

run_processing_bench "mp4_to_mp3" "$VIDEO_IN" "$WORK_DIR/p_mp3b.mp3" \
    -vn -c:a libmp3lame -b:a 192k

run_processing_bench "mp3_to_mp4" "$AUDIO_IN" "$WORK_DIR/p_mp4b.mp4" \
    -c:a aac -b:a 128k

# Cleanup
rm -rf "$WORK_DIR"

RESULT=$(assemble_result "mp3_vs_mp4")

save_result "mp3_vs_mp4" "$RESULT"
echo "$RESULT"
log_bench "=== MP3 vs MP4 Benchmark Complete ==="