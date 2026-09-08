#!/usr/bin/env bash
# Shared utilities for all benchmarks
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"

INPUTS_DIR="$ROOT_DIR/inputs"
OUTPUTS_DIR="$ROOT_DIR/outputs"
RESULTS_DIR="$ROOT_DIR/results"

# --- Difficulty presets ---
# Override with: DIFFICULTY=low ./benchmarks/speed.sh
DIFFICULTY="${DIFFICULTY:-medium}"

declare -A RESOLUTIONS=([low]="320x240" [medium]="1280x720" [high]="1920x1080" [ultra]="3840x2160")
declare -A DURATIONS=([low]=10 [medium]=60 [high]=180 [ultra]=300)
declare -A BITRATES_LOW=([low]="500k" [medium]="2000k" [high]="5000k" [ultra]="15000k")
declare -A FRAMERATES=([low]=24 [medium]=30 [high]=60 [ultra]=60)

get_resolution() { echo "${RESOLUTIONS[$DIFFICULTY]:-1280x720}"; }
get_duration()   { echo "${DURATIONS[$DIFFICULTY]:-60}"; }
get_bitrate()    { echo "${BITRATES_LOW[$DIFFICULTY]:-2000k}"; }
get_framerate()  { echo "${FRAMERATES[$DIFFICULTY]:-30}"; }

# --- Directory helpers ---
ensure_dirs() {
    mkdir -p "$INPUTS_DIR/mp4" "$INPUTS_DIR/mp3"
    mkdir -p "$OUTPUTS_DIR/mp4" "$OUTPUTS_DIR/mp3"
    mkdir -p "$RESULTS_DIR"
}

# --- FFmpeg discovery ---
FFMPEG="${FFMPEG:-ffmpeg}"
FFPROBE="${FFPROBE:-ffprobe}"

find_ffmpeg() {
    if command -v "$FFMPEG" &>/dev/null; then
        return 0
    fi
    echo "ERROR: ffmpeg not found. Run ./install.sh first." >&2
    exit 1
}

# --- GPU acceleration toggle ------------------------------------
# GPU_MODE: none (default) | auto | nvenc | qsv | amf | vaapi | videotoolbox
#   none        = software encoders (libx264/libx265) — unchanged behaviour
#   auto        = pick the first available hardware backend
#   <backend>   = force that backend; falls back to software when unavailable
# Any value is also accepted as the literal encoder name you want to try
# (e.g. GPU_MODE=h264_nvenc) so exotic setups work too.
GPU_MODE="${GPU_MODE:-none}"
VENC_BEING="software"      # active backend: software|nvenc|qsv|amf|vaapi|videotoolbox|<custom>
VENC_USED="libx264"        # encoder name of the last resolve_backend call
GPU_ENCODERS_USED=""       # encoders actually used this run (for results/reporting)

sw_enc() {   # sw_enc <codec> -> software encoder name
    case "${1%-*}" in
        hevc|h265|265) echo libx265 ;;
        *) echo libx264 ;;
    esac
}

backend_enc() {   # backend_enc <codec> <backend> -> hardware encoder name ('' if unknown)
    local codec="$1" backend="$2"
    case "$backend" in
        nvenc)        echo "${codec}_nvenc" ;;
        qsv)          echo "${codec}_qsv" ;;
        amf)          echo "${codec}_amf" ;;
        vaapi)        echo "${codec}_vaapi" ;;
        videotoolbox) echo "${codec}_videotoolbox" ;;
        *) echo "" ;;
    esac
}

# encoder_available <name> -> "1" if the encoder exists in this ffmpeg build
encoder_available() {
    $FFMPEG -hide_banner -encoders 2>/dev/null | awk -v e="$1" '$2==e{print 1; exit}'
}

# encoder_usable <name> [extra_arg...] -> "1" if a 1-frame null encode succeeds
# at runtime (driver/device present), cached per (name + args). Probes use a
# 320x240 frame: large enough for NVENC's minimum dimension check.
declare -A GPU_PROBE_CACHE
encoder_usable() {
    local name="$1"; shift
    local key="$name ${*}"
    if [[ -n "${GPU_PROBE_CACHE[$key]+set}" ]]; then
        echo "${GPU_PROBE_CACHE[$key]}"
        return
    fi
    local r=0
    $FFMPEG -hide_banner -loglevel error -f lavfi -i testsrc2=duration=0.1:size=320x240:rate=25 \
        -frames:v 1 -an "$@" -c:v "$name" -f null - </dev/null >/dev/null 2>&1 && r=1
    GPU_PROBE_CACHE[$key]=$r
    echo "$r"
}

# register a used encoder name for result reporting
_gpu_note_enc() {
    local w="$1"
    case " $GPU_ENCODERS_USED " in
        *" $w "*) ;;  # already noted
        *) GPU_ENCODERS_USED="$GPU_ENCODERS_USED $w" ;;
    esac
}

# resolve_backend <codec> — pick the video encoder for this codec (h264|hevc)
# based on GPU_MODE. Sets VENC_BEING + VENC_USED. Never fails: falls back to
# software (and logs) when a requested backend is missing.
resolve_backend() {
    local codec="$1" soft
    soft=$(sw_enc "$codec")
    VENC_BEING="software"
    VENC_USED="$soft"
    _gpu_note_enc "$soft"
    [[ "$GPU_MODE" == none || -z "$GPU_MODE" ]] && return 0

    local blist backend enc
    case "$GPU_MODE" in
        auto) blist="nvenc qsv amf vaapi videotoolbox" ;;
        nvenc|qsv|amf|vaapi|videotoolbox) blist="$GPU_MODE" ;;
        *) blist="$GPU_MODE" ;;   # treat as an explicit encoder name
    esac

    for backend in $blist; do
        enc=$(backend_enc "$codec" "$backend")
        [[ -n "$enc" ]] || enc="$backend"   # e.g. GPU_MODE=h264_nvenc
        [[ -n "$enc" ]] || continue
        local extra=()
        [[ "$backend" == vaapi ]] && extra=(-vaapi_device /dev/dri/renderD128)
        if [[ "$(encoder_available "$enc")" == 1 ]] && [[ "$(encoder_usable "$enc" "${extra[@]}")" == 1 ]]; then
            VENC_BEING="$backend"
            VENC_USED="$enc"
            _gpu_note_enc "$enc"
            log_info "GPU: $GPU_MODE -> $enc (runtime ok)"
            return 0
        fi
    done
    log_info "GPU: $GPU_MODE has no usable encoder for '$codec' — using $soft"
    return 0
}

# video_enc_opts <codec> <mode> <value> [preset]
#   codec : h264 | hevc (also accepts 264/265/h265 aliases)
#   mode  : b|bitrate (value like "2000k")  or  crf|q|qp (quality number)
#   preset: software preset (ignored for the fixed HW presets below)
# Prints the ffmpeg option words to splice into an encode command, e.g.
#   $(video_enc_opts h264 b 2000k fast)  ->  -c:v libx264 -preset fast -b:v 2000k
#   $(video_enc_opts h264 crf 23 fast)   ->  -c:v libx264 -preset fast -crf 23
# GPU backends map to their native quality controls (nvenc -cq, qsv
# -global_quality, amf cqp, vaapi -qp; videotoolbox only supports bitrate).
video_enc_opts() {
    local codec="$1" mode="$2" value="$3" preset="${4:-fast}"
    local soft
    soft=$(sw_enc "$codec")
    local isb=false
    [[ "$mode" == b || "$mode" == bitrate || "$mode" == br ]] && isb=true

    if [[ "$VENC_BEING" == software ]]; then
        if $isb; then echo "-c:v $soft -preset $preset -b:v $value"
        else         echo "-c:v $soft -preset $preset -crf $value"; fi
        return 0
    fi

    case "$VENC_BEING" in
        nvenc)
            if $isb; then echo "-c:v $VENC_USED -preset p4 -b:v $value"
            else         echo "-c:v $VENC_USED -preset p4 -rc vbr -cq $value"; fi ;;
        qsv)
            if $isb; then echo "-c:v $VENC_USED -preset veryfast -b:v $value"
            else         echo "-c:v $VENC_USED -preset veryfast -global_quality $value"; fi ;;
        amf)
            if $isb; then echo "-c:v $VENC_USED -quality speed -b:v $value"
            else         echo "-c:v $VENC_USED -quality speed -rc cqp -qp_i $value -qp_p $value -qp_b $value"; fi ;;
        vaapi)
            if $isb; then echo "-c:v $VENC_USED -vaapi_device /dev/dri/renderD128 -b:v $value"
            else         echo "-c:v $VENC_USED -vaapi_device /dev/dri/renderD128 -qp $value"; fi ;;
        videotoolbox)
            echo "-c:v $VENC_USED -realtime 1 -b:v $value" ;;
        *)
            if $isb; then echo "-c:v $VENC_USED -b:v $value"
            else         echo "-c:v $VENC_USED -crf $value"; fi ;;
    esac
    return 0
}

# --- Arithmetic helpers (portable: awk, no bc dependency) ---
# calc "EXPR" [scale]  -> prints result truncated to `scale` (default 3) decimals
# EXPR is embedded into awk's interpreter, so it IS evaluated (e.g. "1/3" -> 0.333)
calc() {
    local expr="$1" scale="${2:-3}"
    awk -v s="$scale" "BEGIN{ printf \"%.*f\", s, ($expr) }"
}
# calc_gt "A" "B" -> prints 1 if A > B else 0 (float-safe)
calc_gt() {
    awk -v a="$1" -v b="$2" 'BEGIN{ print (a > b) ? 1 : 0 }'
}

# --- Timing helpers ---
# CPU_CLOCK: subprocess spawn overhead is ignored; nanosecond timer with
# fallback for platforms whose `date` lacks %N (e.g. older macOS).
_ns_precision=1
if date +%s%N 2>/dev/null | grep -q '[0-9]\{16\}'; then
    _ns_precision=1
else
    _ns_precision=0
fi
now_ms() {
    if (( _ns_precision )); then
        date +%s%N | awk '{print int($1/1000000)}'
    else
        date +%s | awk '{print $1*1000}'
    fi
}

# Runs a command, capturing ffmpeg's native -benchmark / -stats output into a
# log file so the numbers can be parsed into result entries.
#   echo "$@" -loglevel info -benchmark >/dev/null 2>"$logfile"
ffbench_capture() {
    local logfile="$1"; shift
    "$@" -loglevel info -benchmark >/dev/null 2>"$logfile"
}

# parse_ff_bench <logfile> -> JSON fragment "ff_*" fields (no braces).
# Parses the final -stats line (fps / speed) and the -benchmark summary
# (utime/stime/rtime in ms, maxrss in kB). Tolerant of audio-only runs that
# have no frame= token and of scientific-notation speed= values.
parse_ff_bench() {
    awk '
    function grab(k,   s) {
        s = $0;
        if (match(s, k "=[[:space:]]*[^[:space:]]+")) {
            s = substr(s, RSTART, RLENGTH);
            sub(/^[A-Za-z_]+=[[:space:]]*/, "", s);
            sub(/x$/, "", s);
            sub(/s$/, "", s);
            sub(/KiB$/, "", s);
            return s;
        }
        return "";
    }
    { if ($0 ~ /bench: utime=/) { U=grab("utime"); S=grab("stime"); R=grab("rtime") }
      if ($0 ~ /bench: maxrss=/) { M=grab("maxrss") }
      if ($0 ~ /speed=/) { SP=grab("speed") }
      if ($0 ~ /fps=/)   { FR=grab("fps") }
    }
    END {
        out=""
        if (FR!="") out=out "\"ff_fps\":" FR ","
        if (SP!="") out=out "\"ff_speed_x\":" SP ","
        if (U!="")  out=out "\"ff_user_ms\":" U*1000 ","
        if (S!="")  out=out "\"ff_sys_ms\":" S*1000 ","
        if (R!="")  out=out "\"ff_real_ms\":" R*1000 ","
        if (M!="")  out=out "\"ff_maxrss_kb\":" M
        sub(/,$/, "", out)
        if (out!="") print out
    }' "$1"
}

# agg_ff_bench <glob...> -> aggregate "ff_*" fragment across many capture logs
# (parallel jobs or sequential chunk encodes). Sums usertime/systime/rtime and
# fps/speed; keeps the max maxrss; counts the processes.
agg_ff_bench() {
    awk '
    function grab(k,   s) {
        s = $0;
        if (match(s, k "=[[:space:]]*[^[:space:]]+")) {
            s = substr(s, RSTART, RLENGTH);
            sub(/^[A-Za-z_]+=[[:space:]]*/, "", s);
            sub(/x$/, "", s);
            sub(/s$/, "", s);
            sub(/KiB$/, "", s);
            return s;
        }
        return "";
    }
    { if (FNR==1) procs++
      if ($0 ~ /bench: utime=/) { U+=grab("utime"); S+=grab("stime"); R+=grab("rtime") }
      if ($0 ~ /bench: maxrss=/) { m=grab("maxrss"); if (m+0 > M+0) M=m }
      if ($0 ~ /speed=/) { SP+=grab("speed") }
      if ($0 ~ /fps=/)   { FR+=grab("fps") }
    }
    END {
        out=""
        if (FR!=0) out=out "\"ff_fps\":" FR ","
        if (SP!=0) out=out "\"ff_speed_x\":" SP ","
        if (U!=0)  out=out "\"ff_user_ms\":" U*1000 ","
        if (S!=0)  out=out "\"ff_sys_ms\":" S*1000 ","
        if (R!=0)  out=out "\"ff_real_ms\":" R*1000 ","
        out=out "\"ff_maxrss_kb\":" M ","
        out=out "\"ff_procs\":" procs
        print out
    }' "$@"
}

# Runs a command and prints JSON timing object (plus native ffmpeg stats when
# the command is ffmpeg and -benchmark output is produced)
bench_run() {
    local label="$1"; shift
    local start end elapsed_ms
    local logfile
    logfile=$(mktemp "${RESULTS_DIR}/.ffbench_XXXXXX" 2>/dev/null || mktemp "${TMPDIR:-/tmp}/ffbench_XXXXXX")
    start=$(now_ms)
    local exit_code=0
    "$@" -loglevel info -benchmark >/dev/null 2>"$logfile" || exit_code=$?
    end=$(now_ms)
    elapsed_ms=$(calc "($end - $start) / 1" 1)

    local ff
    ff=$(parse_ff_bench "$logfile")
    rm -f "$logfile"

    if [[ -n "$ff" ]]; then
        cat <<EOF
{"label":"$label","elapsed_ms":$elapsed_ms,"exit_code":$exit_code,$ff}
EOF
    else
        cat <<EOF
{"label":"$label","elapsed_ms":$elapsed_ms,"exit_code":$exit_code}
EOF
    fi
}

# --- JSON helpers ---
# Assemble a full result JSON document from accumulated entries.
# Benchmarks use: json_begin; json_add {...}; ...; assemble_result "name"

JSON_ENTRIES=()
json_begin() { JSON_ENTRIES=(); }
json_add()   { JSON_ENTRIES+=("$1"); }

assemble_result() {
    local name="$1" timestamp
    timestamp=$(date -u +"%Y-%m-%dT%H:%M:%SZ")
    local gpu_encs
    gpu_encs=$(echo "$GPU_ENCODERS_USED" | sed 's/^ *//;s/ *$//')

    echo "{"
    echo "  \"benchmark\": \"$name\","
    echo "  \"difficulty\": \"$DIFFICULTY\","
    echo "  \"gpu\": \"$GPU_MODE\","
    echo "  \"encoders\": \"$gpu_encs\","
    echo "  \"timestamp\": \"$timestamp\","
    echo "  \"ffmpeg_version\": \"$($FFMPEG -version 2>&1 | head -1)\","
    echo "  \"results\": ["
    local i
    for (( i=0; i<${#JSON_ENTRIES[@]}; i++ )); do
        if (( i < ${#JSON_ENTRIES[@]} - 1 )); then
            echo "    ${JSON_ENTRIES[$i]},"
        else
            echo "    ${JSON_ENTRIES[$i]}"
        fi
    done
    echo "  ]"
    echo "}"
}

# --- Result file ---
save_result() {
    local name="$1"
    local content="$2"
    local outfile="$RESULTS_DIR/${name}_$(date +%s).json"
    echo "$content" > "$outfile"
    echo "Results saved to: $outfile" >&2
}

# --- Input file finders ---
find_mp4_input() {
    local f
    f=$(find "$INPUTS_DIR/mp4" -name "*.mp4" -type f | head -1)
    if [[ -z "$f" ]]; then
        echo "ERROR: No .mp4 files in $INPUTS_DIR/mp4 — run generate_test_media.sh" >&2
        exit 1
    fi
    echo "$f"
}

find_mp3_input() {
    local f
    f=$(find "$INPUTS_DIR/mp3" -name "*.mp3" -type f | head -1)
    if [[ -z "$f" ]]; then
        echo "ERROR: No .mp3 files in $INPUTS_DIR/mp3 — run generate_test_media.sh" >&2
        exit 1
    fi
    echo "$f"
}

find_all_mp4_inputs() {
    find "$INPUTS_DIR/mp4" -name "*.mp4" -type f | sort
}

# --- Resource monitoring ---
# Samples a process every $2 ms for $3 seconds, outputs peak_rss_kb and avg_cpu
monitor_process() {
    local pid="$1"
    local interval_ms="${2:-100}"
    local max_seconds="${3:-300}"
    local interval_s
    interval_s=$(calc "$interval_ms / 1000" 3)

    local peak_rss=0 total_cpu=0 samples=0
    local elapsed=0

    while kill -0 "$pid" 2>/dev/null && (( ! $(calc_gt "$elapsed" "$max_seconds") )); do
        local rss cpu
        if [[ -f "/proc/$pid/status" ]]; then
            rss=$(awk '/VmRSS/{print $2}' "/proc/$pid/status" 2>/dev/null || echo 0)
        else
            rss=$(ps -o rss= -p "$pid" 2>/dev/null || echo 0)
            rss=$(echo "${rss:-0} / 1" | awk '{print int($1)}' 2>/dev/null || echo 0)
        fi
        cpu=$(ps -o %cpu= -p "$pid" 2>/dev/null | tr -d ' ' || echo 0)

        if (( rss > peak_rss )); then peak_rss=$rss; fi
        total_cpu=$(calc "$total_cpu + ${cpu:-0}" 2)
        samples=$((samples + 1))

        sleep "$interval_s"
        elapsed=$(calc "$elapsed + $interval_s" 3)
    done

    local avg_cpu=0
    if (( samples > 0 )); then
        avg_cpu=$(calc "$total_cpu / $samples" 2)
    fi

    echo "{\"peak_rss_kb\":$peak_rss,\"avg_cpu_percent\":$avg_cpu,\"samples\":$samples}"
}

# ps snapshot of a single column for one pid, pipefail-safe (never fails,
# returns '' when the process is gone or a zombie). Matching a just-exited
# ffmpeg makes `ps -p` exit non-zero, which under `set -o pipefail` would
# otherwise kill the monitoring subshell.
pso() {   # pso COLUMN PID
    local out
    out=$(ps -o "$1"= -p "$2" 2>/dev/null | tr -d ' ') || out=""
    printf '%s' "$out"
}

# Lists pids of live ffmpeg processes that belong to OUR process subtree
# (descendants of this shell). Matches on executable name, never on cmdline,
# so no unrelated process can ever be counted or self-matched.
ffmpeg_pids() {
    local ffproc
    ffproc=$(basename "${FFMPEG:-ffmpeg}")
    local -a stack out
    stack=("$$")
    out=()

    while ((${#stack[@]})); do
        local p="${stack[0]}"
        stack=("${stack[@]:1}")
        local kids
        kids=$(ps -e -o pid=,ppid= 2>/dev/null | awk -v p="$p" '$2==p{print $1}') || kids=""
        for k in $kids; do
            stack+=("$k")
            out+=("$k")
        done
    done

    local pid comm
    for pid in "${out[@]}"; do
        comm=$(pso comm "$pid")
        if [[ "$comm" == "$ffproc" ]]; then
            echo "$pid"
        fi
    done
    return 0
}

# Samples ALL ffmpeg processes in a window (multi-process phases: splitting,
# chunking). Stops shortly after every ffmpeg process has exited.
# Usage:
#   monitor_ffmpeg_pool 100 300 > mon.json &   # start before the phase
#   ... run phase ...
#   wait; # collect stats
monitor_ffmpeg_pool() {
    local interval_ms="${1:-100}"
    local max_seconds="${2:-300}"
    local interval_s
    interval_s=$(calc "$interval_ms / 1000" 3)

    local peak_rss=0 peak_count=0 total_cpu=0 samples=0 idle_ticks=0
    local grace_ticks=10   # ~1s of idle after last ffmpeg before stopping
    local elapsed=0

    while true; do
        local rows
        rows=$(ffmpeg_pids)
        local count=0
        if [[ -n "$rows" ]]; then
            count=$(echo "$rows" | sed '/^$/d' | wc -l | tr -d ' ')
        fi

        if (( count > 0 )); then
            idle_ticks=0
            local rss=0 cpu=0 pid
            for pid in $rows; do
                local r c
                r=$(pso rss "$pid")
                c=$(pso %cpu "$pid")
                rss=$((rss + ${r:-0}))
                cpu=$(calc "$cpu + ${c:-0}" 0)
            done
            if (( rss > peak_rss )); then peak_rss=$rss; fi
            if (( count > peak_count )); then peak_count=$count; fi
            total_cpu=$(calc "$total_cpu + $cpu" 0)
            samples=$((samples + 1))
        else
            idle_ticks=$((idle_ticks + 1))
        fi

        elapsed=$(calc "$elapsed + $interval_s" 3)
        if (( idle_ticks >= grace_ticks )) || (( $(calc_gt "$elapsed" "$max_seconds") )); then
            break
        fi
        sleep "$interval_s"
    done

    local avg_cpu=0
    if (( samples > 0 )); then
        avg_cpu=$(calc "$total_cpu / $samples" 2)
    fi

    echo "{\"peak_pool_rss_kb\":$peak_rss,\"peak_concurrent_ffmpeg\":$peak_count,\"avg_cpu_total_percent\":$avg_cpu,\"samples\":$samples}"
}

# --- Cleanup trap ---
cleanup() {
    # Kill any background ffmpeg processes we started
    jobs -p | xargs -r kill 2>/dev/null || true
}
trap cleanup EXIT

# --- Logging ---
log_bench() {
    echo -e "\033[0;36m[bench]\033[0m $*" >&2
}

log_info() {
    echo -e "\033[0;32m[info]\033[0m $*" >&2
}
