#!/usr/bin/env bash
# ---------------------------------------------------------------------------
# AXI accelerator IP (rtl_asic/axi): every RTL check in one go.
#
#   1. AxisSkidBuffer unit test (sim/tb_axis_skid.v): random valid/ready,
#      full throughput, heavy backpressure, bursts; order, loss, repeats and
#      the AXI-Stream stability rules
#   2. lint of the AXI modules (only if verilator is installed)
#   3. the ORIGINAL KV260 testbench on GEMM_top (ASIC) + ASIC core:
#        orig            reference: the KV260 RTL, its result cycles
#        asic  WRAP=thin must give the SAME cycle for every result event
#        asic  WRAP=reg  same results, 1-2 cycles later (latency reported)
#        asic-sram WRAP=reg, 3 matrix shapes: the netlist OpenLane builds
#          (OpenRAM models, GEMM_DP_RESET=0) behind the registered wrapper
#
# usage:  sim/run_axi.sh [path/to/GEMM_32x32_KV260-main]
# output: sim/build_axi/  (logs, cycles_*.txt), PASS/FAIL per line, exit 1 on any FAIL
# ---------------------------------------------------------------------------
set -uo pipefail
KIT=$(cd "$(dirname "$0")/.." && pwd)
REPO=${1:-${REPO:-$KIT/../GEMM_32x32_KV260-main}}
OUT=$KIT/sim/build_axi
mkdir -p "$OUT"
FAILS=0
pass() { printf "  \033[32mPASS\033[0m %s\n" "$*"; }
fail() { printf "  \033[31mFAIL\033[0m %s\n" "$*"; FAILS=$((FAILS+1)); }
A=$KIT/rtl_asic/axi

# ---- 1. skid buffer
echo "== AxisSkidBuffer unit test"
if iverilog -g2012 -o "$OUT/skid.vvp" "$KIT/sim/tb_axis_skid.v" "$A/AxisSkidBuffer.v" > "$OUT/skid_build.log" 2>&1 \
   && ( cd "$OUT" && vvp -n skid.vvp > skid.log 2>&1 ) && grep -q "SKID PASS" "$OUT/skid.log"; then
    pass "$(grep -E '^phase 2:' "$OUT/skid.log"); $(grep -E '^sent' "$OUT/skid.log")"
else
    fail "skid buffer (see sim/build_axi/skid.log, skid_build.log)"
    grep -E "ERROR|timeout" "$OUT/skid.log" 2>/dev/null | head -5 | sed 's/^/       /'
fi

# ---- 2. lint
if command -v verilator >/dev/null; then
    echo "== verilator lint (AXI modules)"
    # SYNCASYNCNET: the synchronised reset is async in the slices/flags and sync in the
    # AXI4-Lite template, on purpose (same as the KV260 IP)
    Q="-Wno-DECLFILENAME -Wno-UNUSEDSIGNAL -Wno-UNUSEDPARAM -Wno-PINCONNECTEMPTY -Wno-WIDTHEXPAND -Wno-SYNCASYNCNET"
    for r in 0 1; do
        if verilator --lint-only -Wall $Q -I"$KIT/rtl_asic" -DGEMM_AXIS_REG=$r --top-module GemmAxiShell \
               "$A/GemmAxiShell.v" "$A/AxiLiteControlRegs.v" "$A/AxisSkidBuffer.v" "$KIT/rtl_asic/ResetSync.v" \
               > "$OUT/lint_shell_$r.log" 2>&1; then
            pass "GemmAxiShell GEMM_AXIS_REG=$r: lint clean"
        else fail "GemmAxiShell GEMM_AXIS_REG=$r: lint (see sim/build_axi/lint_shell_$r.log)"; fi
    done
else
    echo "== verilator not installed: lint skipped"
fi

# ---- 3. original testbench
echo "== original KV260 testbench"
events() { grep -E "RESULT_VALID_FIRST|RESULT_ACCEPT" "$1" 2>/dev/null; }
run() {   # run <label> <variant> <wrap> <shape or "">
    local label=$1 v=$2 w=$3 shape=$4
    if WRAP=$w TB_SHAPE="$shape" "$KIT/sim/run_system.sh" "$v" "$REPO" > "$OUT/sys_$label.log" 2>&1; then
        pass "$label: OVERALL PASS"
    else
        fail "$label failed the testbench (see sim/build_axi/sys_$label.log)"
    fi
}
build_of() {   # build directory run_system.sh used: build_of <variant> <wrap> <shape>
    local v=$1 w=$2 shape=$3 tag=""
    [ -n "$shape" ] && tag=_M$(echo "$shape" | awk -F, '{print $1"K"$2"N"$3}')
    local wt=""; [ "$w" != fpga ] && wt=_axi$w
    echo "$KIT/sim/build_system_$v$wt$tag"
}
# compare the result events of two runs: same job/beat/tlast sequence; report cycle shift
compare() {   # compare <label> <ref events> <dut events> <must be identical: 1|0>
    local label=$1 ref=$2 dut=$3 same=$4
    if [ ! -s "$ref" ] || [ ! -s "$dut" ]; then fail "$label: no result events to compare"; return; fi
    if [ "$same" = 1 ]; then
        if diff -q "$ref" "$dut" >/dev/null; then
            pass "$label: same cycle for all $(wc -l < "$dut") result events as the KV260 RTL"
        else fail "$label: result cycles differ from the KV260 RTL (diff $(basename "$ref") $(basename "$dut"))"; fi
        return
    fi
    if diff -q <(sed 's/ cycle=[0-9]*//' "$ref") <(sed 's/ cycle=[0-9]*//' "$dut") >/dev/null; then
        local d
        d=$(paste -d' ' <(sed 's/.*cycle=//' "$ref") <(sed 's/.*cycle=//' "$dut") \
            | awk '{x=$2-$1; if(NR==1||x<lo)lo=x; if(NR==1||x>hi)hi=x} END{print lo".."hi}')
        pass "$label: same $(wc -l < "$dut") result events in the same order, $d cycles later than the KV260 RTL"
    else
        fail "$label: result event sequence differs from the KV260 RTL"
    fi
}

for shape in "" "8,32,544" "16,992,32"; do
    tag=${shape:+_M$(echo "$shape" | awk -F, '{print $1"K"$2"N"$3}')}
    run "orig$tag" orig fpga "$shape"
    events "$(build_of orig fpga "$shape")/system.log" > "$OUT/cycles_orig$tag.txt"
    if [ -z "$shape" ]; then
        run "thin" asic thin ""
        events "$(build_of asic thin "")/system.log" > "$OUT/cycles_thin.txt"
        compare "thin" "$OUT/cycles_orig.txt" "$OUT/cycles_thin.txt" 1
        run "reg" asic reg ""
        events "$(build_of asic reg "")/system.log" > "$OUT/cycles_reg.txt"
        compare "reg" "$OUT/cycles_orig.txt" "$OUT/cycles_reg.txt" 0
    fi
    run "reg-sram$tag" asic-sram reg "$shape"
    events "$(build_of asic-sram reg "$shape")/system.log" > "$OUT/cycles_reg-sram$tag.txt"
    compare "reg-sram${shape:+ ($shape)}" "$OUT/cycles_orig$tag.txt" "$OUT/cycles_reg-sram$tag.txt" 0
done

echo
if [ "$FAILS" = 0 ]; then echo "AXI IP RTL: ALL PASS"; else echo "AXI IP RTL: $FAILS FAIL"; fi
[ "$FAILS" = 0 ]
