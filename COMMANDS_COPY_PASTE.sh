#!/usr/bin/env bash
# Khối lệnh rút gọn để tái lập macrospaced_v2 trên một clone mới.
# Chạy từng khối và đọc output; script không xóa hay ghi đè run cũ.
set -euo pipefail

project_root="${1:-$(pwd -P)}"
bundle="$project_root/OPENLANE_REPRODUCE_MACROSPACED_V2"

cd "$project_root"

bash "$bundle/scripts/01_preflight.sh" "$project_root"

python3 "$bundle/scripts/03_reproduce_macrospaced_v2.py" \
  --project "$project_root" \
  --prepare

set +e
python3 "$bundle/scripts/03_reproduce_macrospaced_v2.py" \
  --project "$project_root" \
  --run
openlane_rc=$?
set -e

python3 "$bundle/scripts/04_verify_run.py" \
  --project "$project_root"

echo "OpenLane exit code: $openlane_rc"
echo "Run directory: $project_root/designs/GemmAccelerator/runs/area7000x5500_density40_macrospaced_v2"
exit "$openlane_rc"

