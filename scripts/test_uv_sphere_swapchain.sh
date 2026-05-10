#!/usr/bin/env zsh
setopt no_nomatch

rm -f data/debug/screenshots/*

echo "Starting engine with UV check sphere..."
nix develop --command cabal run exe:haskan2 -- \
  -t 25 \
  --uv-check-sphere \
  --debug-socket /tmp/haskan2.sock \
  &
echo $! > .engine_pid

sleep 6

echo "Triggering all stages screenshot..."
python3 scripts/debug_client.py key f11 true

echo "Waiting for first screenshots..."
for i in {1..30}; do
  count=$(ls data/debug/screenshots/ 2>/dev/null | wc -l)
  if [[ $count -ge 4 ]]; then
    echo "Found $count screenshot files"
    break
  fi
  sleep 1
done

echo "Triggering swapchain screenshot..."
python3 scripts/debug_client.py key "shift+f11" true

sleep 3

echo "All screenshots:"
ls -la data/debug/screenshots/

kill $(cat .engine_pid) 2>/dev/null
rm -f .engine_pid
