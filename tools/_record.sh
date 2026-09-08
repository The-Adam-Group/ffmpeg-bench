#!/usr/bin/env bash
# Append one row per result entry of a benchmark result JSON to
# results/history.jsonl so runs can be compared / charted over time.
#
#   tools/_record.sh results/speed_1700000000.json
#
# Rows are line-delimited JSON:
#   {"run":<epoch>,"ts":"<iso>","difficulty":"<d>","gpu":"<mode/path>",
#    "benchmark":"<b>", ...original entry fields...}
set -euo pipefail

FILE="$1"
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
HIST="$ROOT/results/history.jsonl"
mkdir -p "$ROOT/results"

[[ -f "$FILE" ]] || { echo "record: no such file: $FILE" >&2; exit 1; }

# extract <field> <file> -> first "key": value (raw JSON token, quotes kept for strings)
extract() {
    sed -n 's/.*"'"$1"'"[[:space:]]*:[[:space:]]*\([^,}]*\)[,}].*/\1/p' "$2" | head -1
}
unquote() { sed 's/^[[:space:]]*"//; s/"$//'; }

BENCH=$(extract benchmark "$FILE" | unquote);  BENCH="${BENCH:-unknown}"
DIFF=$(extract difficulty "$FILE"  | unquote); DIFF="${DIFF:-unknown}"
GPU=$(extract gpu "$FILE"           | unquote); GPU="${GPU:-none}"
ENCS=$(extract encoders "$FILE"     | unquote)

RUN=$(date +%s)
TS=$(date -u +"%Y-%m-%dT%H:%M:%SZ")

# --- one row per entry line (`    {...}` on its own line) ---
added=0
while IFS= read -r line; do
    line=$(echo "$line" | sed 's/^[[:space:]]*//; s/,$//')
    [[ "$line" == \{*\} ]] || continue   # only entry lines

    # drop outer braces; entries may end with `}` or `},`
    inner=$(printf '%s' "$line" | sed 's/^[[:space:]]*{//; s/}[[:space:]]*,*$//')

    fields=""
    while IFS= read -r pair; do
        key=${pair%%:*}
        val=${pair#*:}
        key=$(echo "$key"   | sed 's/^[[:space:]]*//;s/[[:space:]]*$//;s/"//g')
        val=$(echo "$val"   | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')
        [[ -z "$key" ]] && continue
        case "$val" in
            \"*\") ;;                                          # already a quoted string
            true|false|null) ;;                                # JSON literals
            *[!-+0-9.eE]*) val="\"$val\"" ;;                   # anything else gets quoted
            *) ;;                                              # numeric stays bare
        esac
        fields="$fields\"$key\":$val,"
    done < <(echo "$inner" | tr ',' '\n')

    row="{\"run\":$RUN,\"ts\":\"$TS\",\"difficulty\":\"$DIFF\",\"gpu\":\"$GPU\",\"encoders\":\"$ENCS\",\"benchmark\":\"$BENCH\",$fields"
    row="${row%,}}"
    printf '%s\n' "$row" >> "$HIST"
    added=$((added + 1))
done < "$FILE"

echo "record: $added entries from $(basename "$FILE") -> history.jsonl" >&2
exit 0