#!/bin/bash
# Measure ANE vs CPU/GPU power while embedding continuously.
# Needs sudo (powermetrics). Run:  sudo ./power_loop.sh
set -e
cd "$(dirname "$0")"
PY=.venv/bin/python
DUR=18

run_one () {
  local unit=$1
  echo "================  $unit  ================"
  # start the embedding loop in the background
  $PY -u embed_loop.py "$unit" "$DUR" & LOOP=$!
  sleep 2  # let it warm up
  # sample power for the steady-state window
  powermetrics --samplers cpu_power,gpu_power,ane_power -i 1000 -n 12 2>/dev/null \
    | grep -E "ANE Power|CPU Power|GPU Power|Combined Power|Package Power" \
    | awk '{s[$1" "$2]+=$3; c[$1" "$2]++} END{for(k in s) printf "  avg %-14s %.0f mW\n", k, s[k]/c[k]}'
  wait $LOOP
  echo
}

run_one CPU_ONLY
run_one CPU_AND_NE
