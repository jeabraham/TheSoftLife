#!/usr/bin/env bash
set -euo pipefail
. .venv/bin/activate

for dir in data/Group4* data/Group5* data/Group6*; do
  [ -d "$dir" ] || continue
  echo "Processing: $dir"

  # Run both generators in parallel for this directory
  python generate_subliminals.py --source-dir "$dir" &
  pid_sub=$!

  python generate_foregrounds.py --source-dir "$dir" &
  pid_fore=$!

  # Wait for both to finish before moving to the next directory
  wait "$pid_sub"
  wait "$pid_fore"
done

echo "All done."
