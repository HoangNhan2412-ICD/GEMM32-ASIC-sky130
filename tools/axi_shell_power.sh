#!/usr/bin/env bash
# ---------------------------------------------------------------------------
# Vectorless power of a gemm_axi_shell run (OpenSTA in the OpenLane image),
# tt/25C/1.80V, 100 MHz - same method as tools/power.sh without --vcd.
#   tools/axi_shell_power.sh <shell run dir>
# Output: <run>/reports/power/vectorless.design.rpt (+ .log)
# ---------------------------------------------------------------------------
set -euo pipefail
KIT=$(cd "$(dirname "$0")/.." && pwd)
OL=${OL:-$HOME/OpenLane}
IMG=${OL_IMAGE:-ghcr.io/the-openroad-project/openlane:ff5509f65b17bfa4068d5336495ab1718987ff69-amd64}
PDK_ROOT=${PDK_ROOT:-$HOME/.ciel}
RUN=$(cd "${1:?give a gemm_axi_shell run dir}" && pwd)
[ -f "$RUN/results/final/verilog/gl/GemmAxiShell.nl.v" ] || { echo "no final netlist in $RUN"; exit 1; }
OUT=$RUN/reports/power; mkdir -p "$OUT"
docker run --rm -u "$(id -u):$(id -g)" -v "$HOME:$HOME" -v "$PDK_ROOT:$PDK_ROOT" -v "$KIT:$KIT" -v "$OL:$OL" \
    -e SHELL_FINAL="$RUN/results/final" -e OUT="$OUT/vectorless" -e PDK_ROOT="$PDK_ROOT" \
    "$IMG" sta -no_splash -exit "$KIT/tools/power/shell_power.tcl" 2>&1 | tee "$OUT/vectorless.log"
grep -E "^Total" "$OUT/vectorless.design.rpt" || { echo "no Total line in $OUT/vectorless.design.rpt"; exit 1; }
