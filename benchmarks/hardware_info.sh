#!/usr/bin/env bash
# Dumps hardware and ffmpeg capability information as JSON
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/_common.sh"

find_ffmpeg

OUTPUT="$RESULTS_DIR/hardware_info.json"
mkdir -p "$RESULTS_DIR"

log_bench "Collecting hardware info..."

# CPU info
CPU_MODEL=$(awk -F': ' '/model name/{print $2; exit}' /proc/cpuinfo 2>/dev/null || sysctl -n machdep.cpu.brand_string 2>/dev/null || echo "unknown")
CPU_CORES=$(nproc 2>/dev/null || sysctl -n hw.ncpu 2>/dev/null || echo "unknown")
CPU_THREADS=$(getconf _NPROCESSORS_ONLN 2>/dev/null || echo "$CPU_CORES")

# Memory
TOTAL_MEM_KB=$(awk '/MemTotal/{print $2}' /proc/meminfo 2>/dev/null || sysctl -n hw.memsize 2>/dev/null | awk '{print $1/1024}' || echo "0")
TOTAL_MEM_GB=$(calc "$TOTAL_MEM_KB / 1048576" 1 2>/dev/null || echo "unknown")

# OS
OS_NAME=$(uname -s)
OS_RELEASE=$(uname -r)
OS_DISTRO=""
if [[ -f /etc/os-release ]]; then
    OS_DISTRO=$(awk -F= '/^PRETTY_NAME/{gsub(/"/, "", $2); print $2}' /etc/os-release)
fi

# FFmpeg build info
FFMPEG_VERSION=$($FFMPEG -version 2>&1 | head -1)
FFMPEG_CONFIG=$($FFMPEG -buildconf 2>&1 | grep -- '--enable-' | sed 's/.*--/\--/; s/^ *//' | sort | tr '\n' ',' | sed 's/,$//')
FFMPEG_ENCODERS=$($FFMPEG -encoders 2>&1 | grep -c '^[[:space:]]*[A-Z]' || echo "0")
FFMPEG_DECODERS=$($FFMPEG -decoders 2>&1 | grep -c '^[[:space:]]*[A-Z]' || echo "0")

# GPU / HW accel
HW_ACCEL=$($FFMPEG -hwaccels 2>&1 | tail -n +2 | tr '\n' ',' | sed 's/,$//')

# Disk speed (quick write test)
DISK_TEST_FILE="$RESULTS_DIR/.disk_speed_test"
_DD_RESULT=$(dd if=/dev/zero of="$DISK_TEST_FILE" bs=1M count=100 oflag=direct 2>&1 | tail -1 || echo "unknown")
rm -f "$DISK_TEST_FILE"

cat > "$OUTPUT" <<EOF
{
  "system": {
    "os": "$OS_NAME",
    "release": "$OS_RELEASE",
    "distro": "$OS_DISTRO"
  },
  "cpu": {
    "model": "$CPU_MODEL",
    "cores": "$CPU_CORES",
    "threads": "$CPU_THREADS"
  },
  "memory": {
    "total_gb": $TOTAL_MEM_GB
  },
  "disk": {
    "write_test": "$_DD_RESULT"
  },
  "ffmpeg": {
    "version": "$FFMPEG_VERSION",
    "encoders_count": $FFMPEG_ENCODERS,
    "decoders_count": $FFMPEG_DECODERS,
    "hw_accel": "$HW_ACCEL",
    "key_features": "$FFMPEG_CONFIG"
  }
}
EOF

log_bench "Hardware info saved to $OUTPUT"
cat "$OUTPUT"
