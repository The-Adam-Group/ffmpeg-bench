#!/usr/bin/env bash
# Benchmark: raw encode/decode speed (fps, bitrate)
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/_common.sh"

find_ffmpeg
ensure_dirs

INPUT=$(find_mp4_input)
DUR=$(get_duration)
RES=$(get_resolution)
FPS=$(get_framerate)

log_bench "=== Speed Benchmark ==="
log_bench "Input: $(basename "$INPUT") | Resolution: $RES | Duration: ${DUR}s"

json_begin

# --- Decode-only speed (raw decode, no output) ---
log_bench "Running decode-only pass..."
DECODE_JSON=$(bench_run "decode_only" \
    $FFMPEG -i "$INPUT" -f null - -loglevel error -stats)
json_add "$DECODE_JSON"

# --- Encode-only speed (raw input, encode to h264) ---
log_bench "Running encode-only pass (h264)..."
resolve_backend h264
ENCODE_JSON=$(bench_run "encode_libx264" \
    $FFMPEG -f rawvideo -pix_fmt yuv420p -s "$RES" -r "$FPS" \
        -i /dev/zero -t "$DUR" \
        $(video_enc_opts h264 b "$(get_bitrate)" fast) \
        -f null - -loglevel error -stats)
json_add "$ENCODE_JSON"

# --- Encode-only speed (libx265) ---
log_bench "Running encode-only pass (h265)..."
resolve_backend h265
ENCODE_H265_JSON=$(bench_run "encode_libx265" \
    $FFMPEG -f rawvideo -pix_fmt yuv420p -s "$RES" -r "$FPS" \
        -i /dev/zero -t "$DUR" \
        $(video_enc_opts h265 b "$(get_bitrate)" fast) \
        -f null - -loglevel error -stats)
json_add "$ENCODE_H265_JSON"

# --- Transcode speed (h264 decode + h264 re-encode) ---
log_bench "Running transcode pass (h264 -> h264)..."
resolve_backend h264
TRANSCODE_JSON=$(bench_run "transcode_h264_to_h264" \
    $FFMPEG -i "$INPUT" \
        $(video_enc_opts h264 b "$(get_bitrate)" fast) \
        -c:a aac -b:a 128k \
        -f null - -loglevel error -stats)
json_add "$TRANSCODE_JSON"

# --- Audio-only decode speed ---
log_bench "Running audio decode pass..."
MP3_IN=$(find_mp3_input)
AUDIO_DECODE_JSON=$(bench_run "audio_decode_mp3" \
    $FFMPEG -i "$MP3_IN" -f null - -loglevel error -stats)
json_add "$AUDIO_DECODE_JSON"

# Build result
RESULT=$(assemble_result "speed")

save_result "speed" "$RESULT"
echo "$RESULT"
log_bench "=== Speed Benchmark Complete ==="
