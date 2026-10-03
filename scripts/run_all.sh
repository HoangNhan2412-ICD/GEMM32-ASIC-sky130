#!/usr/bin/env bash
# Run preflight, prepare, OpenLane and verification in order.
set -euo pipefail

project_root="${1:-$(pwd -P)}"
script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"

bash "$script_dir/01_preflight.sh" "$project_root"

python3 "$script_dir/03_reproduce_macrospaced_v2.py" \
    --project "$project_root" \
    --prepare

set +e
python3 "$script_dir/03_reproduce_macrospaced_v2.py" \
    --project "$project_root" \
    --run
openlane_rc=$?
set -e

python3 "$script_dir/04_verify_run.py" \
    --project "$project_root"

echo "OpenLane exit code: $openlane_rc"
exit "$openlane_rc"

