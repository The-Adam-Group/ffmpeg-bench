#!/usr/bin/env bash
# Renders results/report.html from results/history.jsonl — a dependency-free
# summary with inline SVG charts comparing runs over time (per benchmark /
# per label / colored by GPU backend). Pure bash + awk, no python/jq/gnuplot.
#
#   tools/graph_report.sh [--top N] [--out FILE] [--metric KEY] [--line]
#
#   --top N      keep at most N most-recent runs per series (default 12)
#   --out F      output file (default results/report.html)
#   --metric K   y-axis value: default elapsed_ms; also e.g. ff_real_ms,
#                ff_fps, ff_maxrss_kb (rows missing the field are skipped)
#   --line       render line/trend charts instead of bars
#
# Rows are produced by tools/_record.sh (called from run_benchmarks.sh).
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
HIST="$ROOT/results/history.jsonl"
OUT="$ROOT/results/report.html"
TOP=12
METRIC="elapsed_ms"
LINE=0

while (( $# > 0 )); do
    case "$1" in
        --top) TOP="$2"; shift 2 ;;
        --out) OUT="$2"; shift 2 ;;
        --metric) METRIC="$2"; shift 2 ;;
        --line) LINE=1; shift ;;
        -h|--help) sed -n '2,14p' "$0"; exit 0 ;;
        *) echo "graph_report: unknown option $1" >&2; exit 1 ;;
    esac
done

TSV="$ROOT/results/.history.tsv"
mkdir -p "$ROOT/results"

if [[ ! -s "$HIST" ]]; then
    cat > "$OUT" <<EOF
<html><head><meta charset="utf-8"><title>Benchmark report</title></head><body>
<h1>No recorded runs yet</h1>
<p>Run the suite first: <code>./run_benchmarks.sh</code> — each benchmark is
appended to <code>results/history.jsonl</code>. Then re-run
<code>tools/graph_report.sh</code> to chart the trend.</p>
</body></html>
EOF
    echo "graph_report: no history at $HIST (wrote placeholder report)" >&2
    exit 0
fi

# history.jsonl -> tsv: run ts gpu benchmark label value peak_rss_kb
# value column is the requested metric; elapsed_ms falls back to total_ms.
awk -v mk="$METRIC" '
function f(k, s) {
    if (match($0, "\"" k "\":\"[^\"]*\"")) {
        s = substr($0, RSTART + length(k) + 4, RLENGTH - length(k) - 5);
        return s;
    }
    if (match($0, "\"" k "\":[-+0-9.eE]+")) {
        s = substr($0, RSTART + length(k) + 3, RLENGTH - length(k) - 3);
        return s;
    }
    return "";
}
{ run=f("run"); ts=f("ts"); gpu=f("gpu"); b=f("benchmark"); l=f("label");
  v=f(mk); if (v=="") v=(mk=="elapsed_ms") ? f("total_ms") : "";
  rss=f("peak_rss_kb");
  if (run!="" && b!="" && l!="")
      print run"\t"ts"\t"gpu"\t"b"\t"l"\t"v"\t"rss;
}' "$HIST" > "$TSV"

if [[ ! -s "$TSV" ]]; then
    echo "graph_report: no parseable entries in $HIST" >&2
    exit 1
fi

# ---- helpers -------------------------------------------------------------
div()  { awk -v a="$1" -v b="$2" -v s="${3:-1}" 'BEGIN{ if (b==0) b=1; printf "%." s "f", a/b }'; }
# cycle color from a small palette for a gpu tag
gpu_color() {
    case "$1" in
        none|"") echo "#4c8bf5" ;;
        *nvenc*|*cuda*) echo "#e8582a" ;;
        *qsv*) echo "#2aa876" ;;
        *amf*) echo "#c93a8b" ;;
        *vaapi*|*vulkan*) echo "#9a6df0" ;;
        *videotoolbox*) echo "#3aa8c9" ;;
        *) echo "#e0b820" ;;
    esac
}

BODY=""
RUNS_TABLE=""
# Collect unique run set for the summary table (chronological)
RUNS=$(awk '{print $1"\t"$2"\t"$3"\t"$4}' "$TSV" | sort -u -n | head -$((TOP * 40)))

case "$METRIC" in
    ff_fps|speed_x|ff_speed_x) UNIT="" ;;
    ff_maxrss_kb|peak_rss_kb) UNIT=" KiB" ;;
    avg_cpu_percent) UNIT="%" ;;
    *) UNIT=" ms" ;;
esac

side=0
while IFS= read -r series; do
    bench=${series%%::*}; label=${series#*::}
    # rows for this series, most recent TOP runs, oldest first inside a series window
    ROWS=$(awk -v b="$bench" -v l="$label" -F'\t' '$4==b && $5==l {print $0}' "$TSV" | sort -k1,1 -n | tail -"$TOP")
    # keep only rows that have the requested metric
    ROWS=$(printf '%s\n' "$ROWS" | awk -F'\t' '$6!=""')
    [[ -z "$ROWS" ]] && continue

    n=$(printf '%s\n' "$ROWS" | sed '/^$/d' | wc -l | tr -d ' ')
    [[ "$n" == 0 ]] && continue
    side=$((side + 1))

    maxv=$(printf '%s\n' "$ROWS" | awk -F'\t' '{if ($6>m) m=$6} END{print m+0}')
    minv=$(printf '%s\n' "$ROWS" | awk -F'\t' '{if (v==""||$6<v) v=$6} END{print v+0}')
    [[ -z "$maxv" || "$maxv" == 0 ]] && maxv=1
    [[ -z "$minv" ]] && minv=0

    W=$((n * 40 + 70))
    H=210
    BASELINE=$((H - 32))
    PLOT_H=120

    if [[ "$LINE" == 0 ]]; then
        BARS=""
        xlab=""
        row_i=0
        while IFS=$'\t' read -r run ts gpu b l val rss; do
            [[ -z "$val" ]] && continue
            row_i=$((row_i + 1))
            x=$((row_i * 40))
            bh=$(div "$val" "$maxv" 1)
            bh_b=$(awk -v b="$bh" -v ph="$PLOT_H" 'BEGIN{ v=b*ph; if (v<2) v=2; printf "%d", v}')
            bx=$((x - 30))
            by=$((BASELINE - bh_b))
            col=$(gpu_color "$gpu")
            lval=$(awk -v v="$val" 'BEGIN{printf "%.0f", v}')
            BARS+="<rect x=\"$bx\" y=\"$by\" width=\"24\" height=\"$bh_b\" fill=\"$col\"><title>$gpu · run $run · ${val}${UNIT}</title></rect>"
            BARS+="<text x=\"$((bx + 12))\" y=\"$((by - 4))\" font-size=\"9\" text-anchor=\"middle\">$lval</text>"
            xlab+="<text x=\"$((bx + 12))\" y=\"$((BASELINE + 14))\" font-size=\"8\" text-anchor=\"middle\">#$run</text>"
            xlab+="<text x=\"$((bx + 12))\" y=\"$((BASELINE + 26))\" font-size=\"8\" text-anchor=\"middle\" fill=\"#888\">${gpu:-sw}</text>"
        done < <(printf '%s\n' "$ROWS")

        maxlab=$(awk -v m="$maxv" 'BEGIN{printf "%.0f", m}')
        BARS="<text x=\"10\" y=\"30\" font-size=\"9\" fill=\"#666\">${maxlab}${UNIT}</text>$BARS"

        BODY+="
<div class=\"card\">
  <h3>$bench :: $label</h3>
  <p class=\"meta\">$n run(s) · $METRIC (lower is faster) · colored by GPU backend</p>
  <svg viewBox=\"0 0 $W $H\" width=\"100%\" height=\"$H\">
    <line x1=\"10\" y1=\"$BASELINE\" x2=\"$W\" y2=\"$BASELINE\" stroke=\"#444\" stroke-width=\"1\"/>
    $BARS
    $xlab
  </svg>
</div>"
    else
        # ---- line / trend mode ----
        range=$(awk -v mx="$maxv" -v mn="$minv" 'BEGIN{ r=mx-mn; if (r<=0) r=(mx==0?1:mx); printf "%.6f", r }')
        vmax_t=$(awk -v mx="$maxv" -v r="$range" 'BEGIN{ printf "%.6f", mx + r*0.12 }')
        vmin_t=$(awk -v mn="$minv" -v r="$range" 'BEGIN{ printf "%.6f", mn - r*0.08 }')
        trange=$(awk -v a="$vmax_t" -v b="$vmin_t" 'BEGIN{ d=a-b; if (d<=0) d=1; printf "%.6f", d }')

        ypos() { awk -v v="$1" -v mn="$vmin_t" -v tr="$trange" -v bh="$PLOT_H" -v base="$BASELINE" \
            'BEGIN{ printf "%d", base - 6 - (v-mn)/tr*(bh-12) }'; }

        GRID=""
        for gi in 0 1 2 3 4; do
            gv=$(awk -v g="$gi" -v mn="$vmin_t" -v tr="$trange" 'BEGIN{ printf "%.6f", mn + tr*g/4 }')
            gy=$(ypos "$gv")
            gvlab=$(awk -v v="$gv" 'BEGIN{if (v>=100) printf "%.0f", v; else if (v>=10) printf "%.1f", v; else printf "%.2f", v}')
            GRID+="<line x1=\"10\" y1=\"$gy\" x2=\"$W\" y2=\"$gy\" stroke=\"#ddd\" stroke-width=\"1\"/>"
            GRID+="<text x=\"10\" y=\"$((gy - 3))\" font-size=\"8\" fill=\"#999\">${gvlab}${UNIT}</text>"
        done

        SEGS=""
        PTS=""
        xlab=""
        row_i=0
        px=""; py=""; pg=""
        firstv=""; lastv=""
        while IFS=$'\t' read -r run ts gpu b l val rss; do
            [[ -z "$val" ]] && continue
            row_i=$((row_i + 1))
            x=$((row_i * 40 - 18))
            y=$(ypos "$val")
            col=$(gpu_color "$gpu")
            [[ -z "$py" ]] || SEGS+="<line x1=\"$px\" y1=\"$py\" x2=\"$x\" y2=\"$y\" stroke=\"$col\" stroke-width=\"2.5\" stroke-linecap=\"round\"/>"
            PTS+="<circle cx=\"$x\" cy=\"$y\" r=\"4\" fill=\"$col\" stroke=\"#fff\" stroke-width=\"1.5\"><title>$gpu · run $run · ${val}${UNIT}</title></circle>"
            xlab+="<text x=\"$x\" y=\"$((BASELINE + 14))\" font-size=\"8\" text-anchor=\"middle\">#$run</text>"
            hh=${ts:+${ts:11:5}}
            [[ -n "$hh" ]] && xlab+="<text x=\"$x\" y=\"$((BASELINE + 26))\" font-size=\"8\" text-anchor=\"middle\" fill=\"#888\">$hh</text>"
            xlab+="<text x=\"$x\" y=\"$((BASELINE + 38))\" font-size=\"8\" text-anchor=\"middle\" fill=\"#bbb\">${gpu:-sw}</text>"
            px=$x; py=$y; pg=$gpu
            [[ -z "$firstv" ]] && firstv=$val
            lastv=$val
        done < <(printf '%s\n' "$ROWS")

        delta=""
        if [[ -n "$firstv" && -n "$lastv" ]]; then
            delta=$(awk -v a="$firstv" -v b="$lastv" 'BEGIN{ if (a==0) a=1; printf "%+.1f", (b-a)/a*100 }')
        fi

        BODY+="
<div class=\"card\">
  <h3>$bench :: $label</h3>
  <p class=\"meta\">$n run(s) · trend of $METRIC · Δ ${delta}% (first ${firstv}${UNIT} → last ${lastv}${UNIT})</p>
  <svg viewBox=\"0 0 $W $H\" width=\"100%\" height=\"$H\">
    $GRID
    <line x1=\"10\" y1=\"$BASELINE\" x2=\"$W\" y2=\"$BASELINE\" stroke=\"#444\" stroke-width=\"1\"/>
    $SEGS
    $PTS
    $xlab
  </svg>
</div>"
    fi
done < <(awk -F'\t' '$4!="" && $5!="" {print $4"::"$5}' "$TSV" | sort -u)

# ---- summary table over runs (last up to top*40 rows) ----
if [[ -n "$RUNS" ]]; then
    # aggregate: run -> rows+median approx
    last_date=$(echo "$RUNS" | tail -1 | cut -f2)
    RUNS_TABLE="<div class=\"card\"><h3>Recent runs</h3><table><thead><tr><th>run</th><th>time (utc)</th><th>difficulty</th><th>gpu</th><th>benchmark</th><th>entries</th></tr></thead><tbody>"
    prev_row=""
    idx=0
    while IFS=$'\t' read -r run ts diffu gpu bench; do
        cnt=$(awk -F'\t' -v r="$run" -v bb="$bench" '$1==r && $4==bb {n++} END{print n+0}' "$TSV")
        RUNS_TABLE+="<tr><td>#$run</td><td>${ts:+$ts}</td><td>$diffu</td><td>${gpu:-none}</td><td>$bench</td><td>$cnt</td></tr>"
        idx=$((idx + 1))
    done < <(echo "$RUNS")
    RUNS_TABLE+="</tbody></table></div>"
fi

cat > "$OUT" <<EOF
<!DOCTYPE html>
<html><head><meta charset="utf-8"><title>FFmpeg benchmark report</title>
<style>
  body{font-family: system-ui, -apple-system, Segoe UI, Roboto, sans-serif; margin: 24px; background:#fafafa; color:#222;}
  h1{font-size:22px; border-bottom:2px solid #4c8bf5; padding-bottom:6px;}
  h3{margin:8px 0 4px; font-size:15px;}
  .card{background:#fff; border:1px solid #e2e2e2; border-radius:8px; padding:14px 18px; margin:14px 0;}
  .meta{color:#777; font-size:12px; margin:2px 0 10px;}
  table{border-collapse:collapse; font-size:12px; width:100%;}
  th,td{border:1px solid #e2e2e2; padding:4px 8px; text-align:left;}
  th{background:#f0f4ff;}
  code{background:#eee; padding:1px 4px; border-radius:3px;}
  .grid{display:flex; flex-wrap:wrap; gap:16px;}
  .grid .card{flex:1 1 46%; min-width:420px;}
</style></head>
<body>
<h1>FFmpeg benchmark report</h1>
<p>Generated $(date -u +"%Y-%m-%d %H:%M:%SZ") from <code>results/history.jsonl</code> ·
last recorded run: <code>$last_date</code></p>
<div class="grid">
$BODY
</div>
$RUNS_TABLE
</body></html>
EOF

echo "graph_report: wrote $OUT ($(wc -l < "$TSV" | tr -d ' ') recorded rows)" >&2