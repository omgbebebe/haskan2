#!/usr/bin/env bash
set -euo pipefail

MODEL="${1:-data/debug/models/uvCube.gltf}"
DURATION="${2:-5}"
OUTPUT="${3:-benchmark_lights.csv}"

echo "lights,avg_ms,min_ms,max_ms,fps" > "$OUTPUT"

for n in 1 2 3 4; do
  echo "=== Benchmarking with $n lights ==="
  LOG=$(mktemp)
  nix develop --command cabal run exe:haskan2 -- \
    -t "$DURATION" --lights "$n" "$MODEL" > "$LOG" 2>&1 || true
  
  STATS=$(grep "Frame stats \[last 60 frames\]" "$LOG" | tail -1 || true)
  if [ -n "$STATS" ]; then
    AVG=$(echo "$STATS" | grep -oP 'avg=\K[0-9.]+')
    MIN=$(echo "$STATS" | grep -oP 'min=\K[0-9.]+')
    MAX=$(echo "$STATS" | grep -oP 'max=\K[0-9.]+')
    FPS=$(echo "$STATS" | grep -oP 'fps=\K[0-9.]+')
    echo "$n,$AVG,$MIN,$MAX,$FPS" >> "$OUTPUT"
    echo "  avg=${AVG}ms min=${MIN}ms max=${MAX}ms fps=${FPS}"
  else
    echo "$n,NA,NA,NA,NA" >> "$OUTPUT"
    echo "  No stats captured"
  fi
  rm -f "$LOG"
done

echo "=== Results written to $OUTPUT ==="
cat "$OUTPUT"
