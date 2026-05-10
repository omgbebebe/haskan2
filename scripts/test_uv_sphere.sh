#!/usr/bin/env zsh
setopt no_nomatch

rm -f data/debug/screenshots/*

echo "Starting engine with UV check sphere..."
nix develop --command cabal run exe:haskan2 -- \
  -t 20 \
  --uv-check-sphere \
  --debug-socket /tmp/haskan2.sock \
  &
echo $! > .engine_pid

sleep 6

echo "Triggering screenshot..."
python3 scripts/debug_client.py key f11 true

echo "Waiting for screenshots..."
for i in {1..30}; do
  count=$(ls data/debug/screenshots/ 2>/dev/null | wc -l)
  if [[ $count -ge 4 ]]; then
    echo "Found $count screenshot files"
    break
  fi
  sleep 1
done

echo "Screenshots:"
ls -la data/debug/screenshots/

kill $(cat .engine_pid) 2>/dev/null
rm -f .engine_pid
