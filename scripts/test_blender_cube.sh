#!/usr/bin/env zsh
setopt no_nomatch

rm -f data/debug/screenshots/*

echo "Starting engine with Blender uvCube.gltf..."
nix develop --command cabal run exe:haskan2 -- \
  -t 30 \
  data/debug/models/uvCube.gltf \
  --debug-socket /tmp/haskan2.sock \
  &
echo $! > .engine_pid

sleep 8

echo "Positioning camera to look at front face..."
# Position camera to look at front face (from +Z)
python3 scripts/debug_client.py set_camera_angles 0.0 0.0
sleep 1
python3 scripts/debug_client.py set_camera_distance 3.0
sleep 1

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
