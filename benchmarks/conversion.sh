#!/usr/bin/env bash
# Benchmark: mp4 -> mp3 conversion speed
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/_common.sh"

find_ffmpeg
ensure_dirs

log_bench "=== Conversion Benchmark (MP4 -> MP3) ==="

json_begin

# --- Single file conversion: mp4 -> mp3 ---
for input in $(find_all_mp4_inputs); do
    label=$(basename "$input" .mp4)
    outfile="$OUTPUTS_DIR/mp3/conv_${label}.mp3"

    log_bench "Converting: $(basename "$input") -> mp3"
    CONV_JSON=$(bench_run "mp4_to_mp3_${label}" \
        $FFMPEG -i "$input" -vn -c:a libmp3lame -b:a 192k \
            "$outfile" -y -loglevel error -stats)
    json_add "$CONV_JSON"

    # Get output file size
    if [[ -f "$outfile" ]]; then
        out_size=$(stat -c%s "$outfile" 2>/dev/null || stat -f%z "$outfile" 2>/dev/null || echo 0)
        log_bench "  Output size: $(calc "$out_size / 1048576" 1)MB"
    fi
done

# --- Single file conversion: mp4 -> mp4 (re-encode) ---
for input in $(find_all_mp4_inputs); do
    label=$(basename "$input" .mp4)
    outfile="$OUTPUTS_DIR/mp4/reenc_${label}.mp4"

    log_bench "Re-encoding: $(basename "$input") -> mp4"
    REENC_JSON=$(bench_run "mp4_to_mp4_${label}" \
        $FFMPEG -i "$input" \
            -c:v libx264 -preset fast -crf 23 \
            -c:a aac -b:a 128k \
            "$outfile" -y -loglevel error -stats)
    json_add "$REENC_JSON"
done

# --- Conversion with different quality presets ---
INPUT=$(find_mp4_input)
for preset in ultrafast fast medium slow; do
    outfile="$OUTPUTS_DIR/mp3/conv_preset_${preset}.mp3"

    log_bench "Converting with preset: $preset"
    PRESET_JSON=$(bench_run "mp4_to_mp3_preset_${preset}" \
        $FFMPEG -i "$INPUT" -vn -c:a libmp3lame -b:a 192k \
            -preset "$preset" \
            "$outfile" -y -loglevel error -stats)
    json_add "$PRESET_JSON"
done

RESULT=$(assemble_result "conversion")

save_result "conversion" "$RESULT"
echo "$RESULT"
log_bench "=== Conversion Benchmark Complete ==="
