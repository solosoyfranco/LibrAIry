#!/usr/bin/env bash
set -euo pipefail
REPORTS_DIR="${REPORTS_DIR:-/data/reports}"
JSON="$REPORTS_DIR/rmlint.json"
SUMMARY_FILE="$REPORTS_DIR/summary.txt"

[[ -f "$JSON" ]] || { echo "No rmlint.json at $JSON"; exit 0; }

# This matches the "flat" rmlint JSON schema:
# - Every entry has type == "duplicate_file"
# - is_original == true => keeper for that group
# - Entries in the same group share the same checksum
groups=$(jq '[ .[] | select(.type=="duplicate_file" and .is_original==true) ] | length' "$JSON")
dups=$(jq  '[ .[] | select(.type=="duplicate_file" and (.is_original==false)) ] | length' "$JSON")
total=$((groups + dups))

{
  echo "== rmlint summary (flat schema) =="
  echo "Groups (keepers): $groups"
  echo "Duplicate files:  $dups"
  echo "Total in groups:   $total"
  echo
  echo "Top duplicate extensions:"
  jq -r '.[] | select(.type=="duplicate_file" and (.is_original==false)) | .path' "$JSON" \
  | awk -F/ '
      { fn=$NF; ext=fn; sub(/^.*\./,"",ext); if (ext==fn) ext="(noext)"; c[tolower(ext)]++ }
      END {
        PROCINFO["sorted_in"]="@val_num_desc";
        i=0; for (e in c) { printf "  %-12s %7d\n", e, c[e]; if(++i==10) break }
      }'
  echo
  echo "Sample groups:"
  jq -r '
    . as $all
    | [ $all[] | select(.type=="duplicate_file") ]
    | group_by(.checksum)
    | map({
        checksum: (.[0].checksum),
        keeper:   (first(.[] | select(.is_original==true)) | .path),
        dups:     ([ .[] | select(.is_original==false) | .path ])
      })
    | .[:5] # first 5 groups only
    | .[] | "KEEPER: \(.keeper)\n  DUPS:\n" + ( .dups[]? | "    - " + . ) + "\n"
  ' "$JSON"
} | tee "$SUMMARY_FILE"
