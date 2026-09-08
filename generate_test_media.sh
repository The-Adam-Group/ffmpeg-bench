#!/usr/bin/env bash
# Generates synthetic test media files for benchmarking
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/benchmarks/_common.sh"

find_ffmpeg
ensure_dirs

log_info "Generating test media (difficulty: $DIFFICULTY)..."

RES=$(get_resolution)
DUR=$(get_duration)
BR=$(get_bitrate)
FPS=$(get_framerate)

# --- MP4 files ---
generate_mp4() {
    local label="$1" duration="$2" resolution="$3" bitrate="$4" fps="$5"
    local outfile="$INPUTS_DIR/mp4/test_${label}_${resolution}_${duration}s.mp4"

    if [[ -f "$outfile" ]]; then
        log_info "Already exists: $(basename "$outfile")"
        return
    fi

    log_info "Generating MP4: $(basename "$outfile")"
    $FFMPEG -y -f lavfi \
        -i "testsrc2=duration=${duration}:size=${resolution}:rate=${fps}" \
        -f lavfi \
        -i "sine=frequency=440:duration=${duration}" \
        -c:v libx264 -preset fast -b:v "$bitrate" \
        -c:a aac -b:a 128k \
        -pix_fmt yuv420p \
        "$outfile" \
        -loglevel warning
}

# --- MP3 files ---
generate_mp3() {
    local label="$1" duration="$2"
    local outfile="$INPUTS_DIR/mp3/test_${label}_${duration}s.mp3"

    if [[ -f "$outfile" ]]; then
        log_info "Already exists: $(basename "$outfile")"
        return
    fi

    log_info "Generating MP3: $(basename "$outfile")"
    $FFMPEG -y -f lavfi \
        -i "sine=frequency=440:duration=${duration}" \
        -c:a libmp3lame -b:a 192k \
        "$outfile" \
        -loglevel warning
}

# Generate at current difficulty
generate_mp4 "default" "$DUR" "$RES" "$BR" "$FPS"

# Also generate a short 10s clip for fast benchmarks
generate_mp4 "short" 10 "$RES" "$BR" "$FPS"

# Generate a longer clip for resource monitoring
if (( DUR < 60 )); then
    generate_mp4 "long" 60 "$RES" "$BR" "$FPS"
fi

# MP3 inputs
generate_mp3 "default" "$DUR"
generate_mp3 "short" 10

log_info "Test media generation complete."
ls -lh "$INPUTS_DIR/mp4/" "$INPUTS_DIR/mp3/"
