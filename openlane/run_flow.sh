#!/usr/bin/env bash
# ---------------------------------------------------------------------------
# run_flow.sh - GEMM ASIC flow on OpenLane 1.0.2, bottom-up, one checked stage at a time.
#
#   openlane/run_flow.sh sim        ASIC RTL vs FPGA RTL (original testbench, cycle-exact)
#   openlane/run_flow.sh pe         one PE (its area sizes the row)
#   openlane/run_flow.sh row        32-PE row macro (+ netlist vs RTL check)
#   openlane/run_flow.sh array      FeatureSkew + 32 row macros + OutputDeskew
#   openlane/run_flow.sh core-sim   core RTL with the OpenRAM models, 3 matrix shapes
#   openlane/run_flow.sh core-pre   core lint + synthesis + floorplan (~1 h)
#   openlane/run_flow.sh core       core GemmAccelerator: 32 rows + 80 SRAM, full run (~7 h)
#   openlane/run_flow.sh core-gls   original testbench on the final core netlist, 3 shapes
#   openlane/run_flow.sh core-status   progress of the running / last core run
#   openlane/run_flow.sh core-check    judge an existing core run again (no OpenLane)
#   openlane/run_flow.sh core-route    route + signoff again from the post-CTS layout of a run
#   openlane/run_flow.sh axi-sim    AXI IP (rtl_asic/axi): skid-buffer test + original testbench, thin/reg
#   openlane/run_flow.sh axi-shell  harden the AXI shell alone (thin, reg) + overhead table vs the core
#   openlane/run_flow.sh axi-gls    original testbench on GEMM_top (reg) around the final core netlist
#   openlane/run_flow.sh status     stages passed so far (openlane/LOG.md)
#   Diagnostics: core-triage, core-probe, core-precheck, array-check (see the functions below).
#
# Each stage starts only after the one before it passed, prints STAGE <x> PASS|FAIL
# and appends a line (with peak RAM) to openlane/LOG.md.
#
# Environment [default]:
#   OL          OpenLane checkout                        [$HOME/OpenLane]
#   REPO        original GEMM_32x32_KV260 repo           [../GEMM_32x32_KV260-main]
#   TAG         core: run name [core_v11]; core-gls / core-check / core-status: run to use
#   FROM        core-route: run to continue from          [last core run]
#   MIN_DISK_GB core / core-route stop below this free disk [40]
#   DRT_SEEDS   detailed-router seeds tried in turn       [core: "42 7 23"]
#   ANT_ECO     antenna ECO rounds after routing, 0 = off [3]
#   ROW         core-gls: row model, rtl or gl (gate netlist of the row run) [gl]
#   CORE_RUN    axi-shell / axi-gls: core run to compare with / simulate [last core run that passed]
#   AUTO_COMMIT=1  git commit + tag the kit on every PASS
# ---------------------------------------------------------------------------
set -uo pipefail

KIT=$(cd "$(dirname "$0")/.." && pwd)
OL=${OL:-$HOME/OpenLane}
REPO=${REPO:-$KIT/../GEMM_32x32_KV260-main}
HERE=$KIT/openlane
LOG=$HERE/LOG.md
STATE=$HERE/state
STAMP=$(date +%Y%m%d-%H%M%S)
mkdir -p "$STATE" "$HERE/logs"
[ -f "$LOG" ] || printf "# OpenLane flow log\n\n| time | stage | result | peak RAM (MB) | note |\n|---|---|---|---|---|\n" > "$LOG"

FAILS=0; NOTE=""; PEAK="-"; MEMPEAK=""; MEMW_PID=""
CORE_GEN_DEFAULT="--layout v3 --b-wide --b-gap-y 200 --strip 1000 --a-gap-x 200"   # core floorplan v5/v6 (see gen_core_files.py)
trap '[ -n "${MEMW_PID:-}" ] && kill "$MEMW_PID" 2>/dev/null' EXIT
say()  { printf "\n\033[1m== %s\033[0m\n" "$*"; }
pass() { printf "  \033[32mPASS\033[0m %s\n" "$*"; }
fail() { printf "  \033[31mFAIL\033[0m %s\n" "$*"; FAILS=$((FAILS+1)); }

need() {   # need <stage>: refuse to run before <stage> passed
    grep -q "| $1 | PASS |" "$LOG" || { echo "Stage '$1' has not passed yet - run: openlane/run_flow.sh $1"; exit 1; }
}

finish() {   # finish <stage>
    local st=$1 result=PASS
    [ $FAILS -gt 0 ] && result=FAIL
    echo "| $STAMP | $st | $result | $PEAK | $NOTE |" >> "$LOG"
    if [ $result = PASS ] && [ "${AUTO_COMMIT:-0}" = 1 ] && git -C "$KIT" rev-parse --is-inside-work-tree >/dev/null 2>&1; then
        git -C "$KIT" add -A rtl_asic sim openlane tools 2>/dev/null
        git -C "$KIT" commit -qm "OpenLane stage $st PASS" >/dev/null 2>&1
        git -C "$KIT" tag "ol-$st-pass-$STAMP" 2>/dev/null && echo "  git tag ol-$st-pass-$STAMP"
    fi
    if [ $result = PASS ]; then printf "\n\033[32mSTAGE %s PASS\033[0m\n" "$st"
    else printf "\n\033[31mSTAGE %s FAIL\033[0m (%d problems)\n" "$st" "$FAILS"; exit 1; fi
}

disk_free_gb() { df -BG --output=avail "$OL" 2>/dev/null | tail -1 | tr -dc '0-9'; }

need_disk() {   # need_disk <GB>: stop before OpenLane starts when the disk of $OL has less free
    # (core_v7r died at 13:01 03/10 with the disk full: OpenROAD could not write a DEF)
    local want=$1 have
    have=$(disk_free_gb)
    [ -n "$have" ] || { echo "  (free disk space of $OL unknown - not checked)"; return 0; }
    if [ "$have" -lt "$want" ]; then
        echo "  disk: only $have GB free on the disk of $OL, this stage needs at least $want GB"
        echo "  (a core route + signoff writes ~25 GB). Remove old runs/<tag>/tmp and results first,"
        echo "  or set MIN_DISK_GB lower if you know it fits."
        exit 1
    fi
    echo "  disk free    : $have GB (this stage needs $want)"
}

mem_watch_start() {   # mem_watch_start <file>: every 10 s, biggest EDA process RSS + free RAM + swap + free disk (GB)
    MEMW_FILE=$1; : > "$MEMW_FILE"
    (
        while :; do
            p=$(ps -eo rss=,comm= 2>/dev/null | awk '$2 ~ /^(openroad|magic|netgen|klayout|yosys|cvc)/ && $1 > m { m = $1; c = $2 }
                                                 END { printf "%d %s", m / 1024, (c == "" ? "-" : c) }')
            a=$(awk '/^MemAvailable:/{print int($2/1024)}' /proc/meminfo)
            s=$(awk '/^SwapTotal:/{t=$2} /^SwapFree:/{f=$2} END{print int((t-f)/1024)}' /proc/meminfo)
            echo "$(date +%H:%M:%S) $p $a $s $(disk_free_gb)" >> "$MEMW_FILE"
            sleep 10
        done
    ) &
    MEMW_PID=$!
}

mem_watch_stop() {   # stop the sampler, print the summary, MEMPEAK = peak RSS (MB)
    [ -n "${MEMW_PID:-}" ] && { kill "$MEMW_PID" 2>/dev/null; wait "$MEMW_PID" 2>/dev/null; }
    MEMW_PID=""
    [ -s "${MEMW_FILE:-}" ] || return 0
    local pk pc ma ms
    read -r pk pc ma ms <<< "$(awk '{ if ($2 > p) { p = $2; c = $3 } if (m == "" || $4 < m) m = $4; if ($5 > s) s = $5 }
                                    END { print p + 0, (c == "" ? "-" : c), m + 0, s + 0 }' "$MEMW_FILE")"
    MEMPEAK=$pk
    echo "  memory: peak $pk MB ($pc), lowest free RAM $ma MB, most swap in use $ms MB (${MEMW_FILE#"$KIT"/})"
}

ol_run() {   # ol_run <design> <tag>: one full OpenLane run, output teed to a log
    local design=$1 tag=$2
    local log=$HERE/logs/${design}_${tag}_$STAMP.log
    [ -f "$OL/flow.tcl" ] || { echo "OpenLane not found at $OL (set OL=...)"; exit 1; }
    echo "  OpenLane: $design (tag $tag) - log: ${log#"$KIT"/}"
    mem_watch_start "$HERE/logs/mem_${design}_${tag}_$STAMP.txt"
    make -C "$OL" quick_run QUICK_RUN_DESIGN="$design -tag $tag -overwrite" 2>&1 | tee "$log"
    local rc=${PIPESTATUS[0]}
    mem_watch_stop
    [ "$rc" -eq 0 ] || fail "OpenLane run $design/$tag stopped (see the log above)"
    RUNDIR=$OL/designs/$design/runs/$tag
}

ol_full() {   # ol_full <tag>: the whole gemm_core flow through core_full.tcl (interactive mode)
    local tag=$1
    local log=$HERE/logs/gemm_core_${tag}_$STAMP.log
    [ -f "$OL/flow.tcl" ] || { echo "OpenLane not found at $OL (set OL=...)"; exit 1; }
    cat > "$OL/designs/gemm_core/full_params.tcl" <<EOF
# written by run_flow.sh $STAMP for designs/gemm_core/core_full.tcl
set GEMM_NEW_TAG $tag
EOF
    echo "  OpenLane (core_full.tcl): gemm_core (tag $tag) - log: ${log#"$KIT"/}"
    mem_watch_start "$HERE/logs/mem_gemm_core_${tag}_$STAMP.txt"
    make -C "$OL" quick_run QUICK_RUN_DESIGN="gemm_core -it -file designs/gemm_core/core_full.tcl" 2>&1 | tee "$log"
    local rc=${PIPESTATUS[0]}
    mem_watch_stop
    [ "$rc" -eq 0 ] || fail "OpenLane run gemm_core/$tag stopped (see the log above)"
    RUNDIR=$OL/designs/gemm_core/runs/$tag
}

# routing overrides shared by core / core-route / core-probe, appended to $ovr
route_overrides() {
    [ -n "${GRT_ADJ:-}" ] && ovr+=$'\n'"set ::env(GRT_LAYER_ADJUSTMENTS) \"$GRT_ADJ\""
    # GRT_ITERS=N: congestion iterations of the global route, for core and core-route
    # (FastRoute here has crashed on very long detours in late iterations - try a probe first)
    [ -n "${GRT_ITERS:-}" ] && ovr+=$'\n'"set ::env(GRT_OVERFLOW_ITERS) $GRT_ITERS"
    # ANT_MARGIN=N: GRT_ANT_MARGIN (%) of repair_antennas in the global route, for core and core-route
    # (v9 post-CTS, met1 0.5: margin 50 -> same overflow 46, 66k diodes instead of 39k)
    [ -n "${ANT_MARGIN:-}" ] && ovr+=$'\n'"set ::env(GRT_ANT_MARGIN) $ANT_MARGIN"
    [ "${MET5_OVER_SRAM:-0}" = 1 ] && ovr+=$'\n'"catch { unset ::env(GRT_OBS) }"
    [ "${1:-}" = probe ] && return 0
    ovr+=$'\n'"set ::env(GEMM_ANT_ECO_ITERS) ${ANT_ECO:-3}"
    return 0
}

check_run() {   # check_run <run dir> [--waive-io-timing]: signoff metrics + peak RAM
    if python3 "$HERE/check_openlane_run.py" ${2:-} "$1" | tee "$STATE/last_check.txt"; then
        pass "signoff checks ${1#"$OL"/}"
    else fail "signoff checks ${1#"$OL"/}"; fi
    PEAK=$(awk -F'= ' '/Peak_Memory_Usage_MB/{split($2,a," "); print a[1]}' "$STATE/last_check.txt")
    # OpenLane writes -1 when it could not measure; the host-side sampler knows
    case "$PEAK" in ""|-1|-1.0) PEAK=${MEMPEAK:-"-"} ;; esac
}

# =========================================================================
st_sim() {
    say "sim: original RTL vs ASIC RTL"
    local out=$HERE/logs/sim_$STAMP; mkdir -p "$out"
    if "$KIT/sim/run_equiv.sh" "$REPO/rtl" > "$out/equiv.log" 2>&1; then
        pass "equivalence, GEMM_DP_RESET=1 and 0: $(grep -c 'EQUIVALENCE PASS' "$out/equiv.log")/2 PASS"
    else fail "equivalence (see ${out#"$KIT"/}/equiv.log)"; fi
    local n; n=$(awk '$1=="`define" && $2=="GEMM_N"{print $3}' "$KIT/rtl_asic/gemm_asic_cfg.vh")
    if [ "$n" = 32 ]; then
        "$KIT/sim/run_system.sh" orig "$REPO" > "$out/sys_orig.log" 2>&1 && pass "original RTL: OVERALL PASS" \
            || fail "original RTL failed its own testbench"
        "$KIT/sim/run_system.sh" asic "$REPO" > "$out/sys_asic.log" 2>&1 && pass "ASIC RTL: OVERALL PASS" \
            || fail "ASIC RTL failed the original testbench"
        grep -E "RESULT_VALID_FIRST|RESULT_ACCEPT" "$KIT/sim/build_system_orig/system.log" > "$out/cycles_orig.txt" 2>/dev/null
        grep -E "RESULT_VALID_FIRST|RESULT_ACCEPT" "$KIT/sim/build_system_asic/system.log" > "$out/cycles_asic.txt" 2>/dev/null
        if [ -s "$out/cycles_orig.txt" ] && diff -q "$out/cycles_orig.txt" "$out/cycles_asic.txt" >/dev/null; then
            pass "same cycle for all $(wc -l < "$out/cycles_asic.txt") result events as the FPGA RTL"
        else fail "result cycles differ from the FPGA RTL (diff cycles_*.txt in ${out#"$KIT"/})"; fi
    else
        fail "GEMM_N=$n in gemm_asic_cfg.vh; the OpenLane configs are for 32 - set it back to 32"
    fi
    NOTE="logs in ${out#"$KIT"/}"
    finish sim
}

st_pe() {
    need sim
    say "pe: one ProcessingElement"
    ol_patches || { fail "patch OpenLane scripts"; finish pe; }
    "$HERE/install_into_openlane.sh" "$OL" >/dev/null || { fail "install into $OL"; finish pe; }
    ol_run gemm_pe pe_v1
    check_run "$RUNDIR"
    local area
    area=$(grep -h "Chip area" "$RUNDIR"/reports/synthesis/*.stat.rpt 2>/dev/null | tail -1 | awk '{print $NF}')
    if [ -n "$area" ]; then
        echo "$area" > "$STATE/pe_area.txt"
        pass "PE cell area $area um^2 (saved; row and array are sized from it)"
        NOTE="PE area $area um^2"
    else fail "could not read 'Chip area' from $RUNDIR/reports/synthesis/*.stat.rpt"; fi
    finish pe
}

st_row() {
    need pe
    say "row: 32-PE macro"
    local area; area=$(cat "$STATE/pe_area.txt")
    ol_patches || { fail "patch OpenLane scripts"; finish row; }
    # shellcheck disable=SC2086
    "$HERE/install_into_openlane.sh" "$OL" --pe-area "$area" ${GEN_ARGS:-} | tee "$STATE/geometry.txt" \
        || { fail "install/geometry"; finish row; }
    ol_run gemm_row row_v1
    check_run "$RUNDIR"
    local lef=$RUNDIR/results/final/lef/ProcessingElementRow.lef
    if [ -s "$lef" ]; then
        python3 "$KIT/tools/check_row_lef.py" "$lef" 32 8 5 && pass "row LEF: power pins + 928 top/bottom pins aligned" \
            || fail "row LEF checks"
    else fail "no $lef"; fi
    # LVS only compares layout with the netlist; this compares the netlist with the RTL
    if "$KIT/sim/row_equiv.sh" "$RUNDIR/results/final/verilog/gl/ProcessingElementRow.nl.v" > "$HERE/logs/row_equiv_$STAMP.log" 2>&1; then
        pass "row netlist = RTL (random stimulus, $(grep -o 'cycles=[0-9]*' "$HERE/logs/row_equiv_$STAMP.log"))"
    else fail "row netlist differs from the RTL:"; tail -n 6 "$HERE/logs/row_equiv_$STAMP.log" | sed 's/^/    /'; fi
    NOTE="$(head -1 "$STATE/geometry.txt")"
    finish row
}

st_array() {
    need row
    say "array: FeatureSkew + 32 row macros + OutputDeskew"
    # I/O delays for array.sdc from the clock latency the previous run measured
    local prev=$OL/designs/gemm_array/runs/array_v1
    if [ -d "$prev/reports/signoff" ]; then
        python3 "$KIT/tools/clock_latency.py" "$prev" "$HERE/designs/gemm_array/clk_latency.tcl" \
            || echo "  (no clock latency from the previous run - array.sdc falls back to base.sdc values)"
    fi
    ol_patches || { fail "patch OpenLane scripts"; finish array; }
    # re-copy RTL + configs (same geometry: same PE area and GEN_ARGS as the row)
    # shellcheck disable=SC2086
    "$HERE/install_into_openlane.sh" "$OL" --pe-area "$(cat "$STATE/pe_area.txt")" ${GEN_ARGS:-} >/dev/null \
        || { fail "install into $OL"; finish array; }
    ol_run gemm_array array_v1
    array_verdict
}

array_verdict() {   # judge $RUNDIR as the array stage
    # OpenLane itself exits non-zero at its final timing gate on the I/O paths,
    # so the verdict starts from zero and judges the run on its own
    FAILS=0
    local placed
    placed=$(grep -rhoE "Successfully placed [0-9]+ instances" "$RUNDIR/logs" 2>/dev/null | tail -1 | awk '{print $3}')
    if [ "$placed" = 32 ]; then pass "32 row macros placed from macro.cfg"
    else
        fail "macro placement placed '${placed:-0}' rows, expected 32"
        echo "  hint: if the floorplan log says 'Macros not found', regenerate with the other name style:"
        echo "        python3 openlane/gen_openlane_files.py --pe-area $(cat "$STATE/pe_area.txt") --name-style plain --out $OL/designs"
    fi
    # internal timing only (see check_openlane_run.py --waive-io-timing)
    check_run "$RUNDIR" --waive-io-timing
    NOTE="GDS: ${RUNDIR#"$OL"/}/results/final/gds/ProcessingElementArray.gds (I/O timing waived)"
    finish array
}

# =========================================================================
# level 3: the hardened GEMM core (GemmAccelerator)
st_core_sim() {
    need sim
    say "core-sim: GemmAccelerator RTL (W1024/F512/O512) - behavioural vs OpenRAM macro models vs FPGA RTL"
    local out=$HERE/logs/core_sim_$STAMP; mkdir -p "$out"
    # shape "" = the testbench's 64x64x64 (2 K blocks, 2 N blocks); the other
    # two are shapes the FPGA software would send and that reach the SECOND
    # bank of the 1024-word memories, which 64x64x64 never touches:
    #   8,32,544  : 17 N blocks -> feeder weight tile addr up to 543, input weight 544 words
    #   16,992,32 : 31 K blocks -> input weight 992 words, longest accumulation
    local shape v tag
    for shape in "" "8,32,544" "16,992,32"; do
        tag=${shape:+_M$(echo "$shape" | awk -F, '{print $1"K"$2"N"$3}')}
        local vars="orig asic-sram"; [ -z "$shape" ] && vars="orig asic asic-sram"
        for v in $vars; do
            if TB_SHAPE="$shape" "$KIT/sim/run_system.sh" "$v" "$REPO" > "$out/sys_$v$tag.log" 2>&1; then
                pass "$v${shape:+ ($shape)}: OVERALL PASS"
            else fail "$v${shape:+ ($shape)} failed the testbench (see ${out#"$KIT"/}/sys_$v$tag.log)"; fi
            grep -E "RESULT_VALID_FIRST|RESULT_ACCEPT" "$KIT/sim/build_system_$v$tag/system.log" > "$out/cycles_$v$tag.txt" 2>/dev/null
        done
        [ -z "$shape" ] && grep -E "SRAM model|same-address|^ +[0-9]+ +u_" "$out/sys_asic-sram.log" | sed "s/^/  /"
        for v in $vars; do
            [ "$v" = orig ] && continue
            if [ -s "$out/cycles_orig$tag.txt" ] && diff -q "$out/cycles_orig$tag.txt" "$out/cycles_$v$tag.txt" >/dev/null; then
                pass "$v${shape:+ ($shape)}: same cycle for all $(wc -l < "$out/cycles_$v$tag.txt") result events as the FPGA RTL"
            else fail "$v${shape:+ ($shape)}: result cycles differ from the FPGA RTL (diff ${out#"$KIT"/}/cycles_*$tag.txt)"; fi
        done
    done
    NOTE="logs in ${out#"$KIT"/}"
    finish core-sim
}

gpl_hook() {   # let a design pass extra global_placement options (GPL_EXTRA_ARGS)
    local f=$OL/scripts/openroad/gpl.tcl
    [ -f "$f" ] || { echo "  note: $f not found - GPL_EXTRA_ARGS will be ignored"; return 0; }
    grep -q "GPL_EXTRA_ARGS" "$f" && return 0
    [ -f "$f.orig_gemm" ] || cp "$f" "$f.orig_gemm"
    python3 - "$f" <<'PY' || { echo "  could not add the GPL_EXTRA_ARGS hook to $f"; return 1; }
import sys
p = sys.argv[1]; s = open(p).read()
key = "global_placement {*}$arg_list"
if key not in s:
    sys.exit(1)
hook = ("# gemm_asic_kit: extra options for designs that set GPL_EXTRA_ARGS\n"
        "if { [info exists ::env(GPL_EXTRA_ARGS)] } { lappend arg_list {*}$::env(GPL_EXTRA_ARGS) }\n")
open(p, "w").write(s.replace(key, hook + key, 1))
PY
    echo "  added GPL_EXTRA_ARGS hook to $f (original kept as gpl.tcl.orig_gemm)"
}

antenna_fix() {   # OpenLane 1.0.2 bug in the GRT antenna-repair loop (routing.tcl)
    # When an extra antenna iteration REDUCES the violations, routing.tcl does
    #   set minimum_antennae [groute_antenna_extract -from_log [groute_antenna_extract -from_log $log]]
    # i.e. it opens a file named after the violation count and the step dies
    # ("couldn't read file "3""). The intended value is simply $antennae.
    local f=$OL/scripts/tcl_commands/routing.tcl
    [ -f "$f" ] || return 0
    grep -q 'groute_antenna_extract -from_log \[groute_antenna_extract' "$f" || return 0
    [ -f "$f.orig_gemm" ] || cp "$f" "$f.orig_gemm"
    python3 - "$f" <<'PY' || { echo "  could not patch the antenna loop in $f"; return 1; }
import sys
p = sys.argv[1]; s = open(p).read()
bad = "set minimum_antennae [groute_antenna_extract -from_log [groute_antenna_extract -from_log $log]]"
if bad not in s:
    sys.exit(1)
open(p, "w").write(s.replace(bad, "set minimum_antennae $antennae  ;# gemm_asic_kit fix", 1))
PY
    echo "  fixed OpenLane antenna-iteration bug in $f (original kept as routing.tcl.orig_gemm)"
}

dpl_hook() {   # let a design run a Tcl script right before every detailed_placement (DPL_PRE_HOOK)
    # common/dpl_cell_pad.tcl is sourced by resizer.tcl, dpl.tcl, cts.tcl and
    # resizer_timing.tcl immediately before they call detailed_placement.
    local f=$OL/scripts/openroad/common/dpl_cell_pad.tcl
    [ -f "$f" ] || { echo "  note: $f not found - DPL_PRE_HOOK will be ignored"; return 0; }
    grep -q "DPL_PRE_HOOK" "$f" && return 0
    [ -f "$f.orig_gemm" ] || cp "$f" "$f.orig_gemm"
    printf '\n# gemm_asic_kit: per-design hook right before detailed_placement\nif { [info exists ::env(DPL_PRE_HOOK)] && [file exists $::env(DPL_PRE_HOOK)] } { source $::env(DPL_PRE_HOOK) }\n' >> "$f" \
        || { echo "  could not add the DPL_PRE_HOOK hook to $f"; return 1; }
    echo "  added DPL_PRE_HOOK hook to $f (original kept as dpl_cell_pad.tcl.orig_gemm)"
}

drt_seed_hook() {   # detailed router seed from DRT_OR_SEED (OpenLane 1.0.2 hard-codes -or_seed 42)
    # Same input + same seed = same result. When detailed routing ends with a
    # violation it cannot clear (core_v6: one met5 short), another seed gives
    # the router another net order and usually clears it.
    local f=$OL/scripts/openroad/droute.tcl
    [ -f "$f" ] || return 0
    grep -q "DRT_OR_SEED" "$f" && return 0
    grep -q -- "-or_seed 42" "$f" || { echo "  note: no '-or_seed 42' in $f - DRT_OR_SEED will be ignored"; return 0; }
    [ -f "$f.orig_gemm" ] || cp "$f" "$f.orig_gemm"
    python3 - "$f" <<'PYX' || { echo "  could not add DRT_OR_SEED to $f"; return 1; }
import sys
p = sys.argv[1]; s = open(p).read()
s = s.replace("-or_seed 42", "-or_seed [expr {[info exists ::env(DRT_OR_SEED)] ? $::env(DRT_OR_SEED) : 42}]", 1)
open(p, "w").write(s)
PYX
    echo "  detailed router seed now settable (DRT_OR_SEED) in $f (original kept as droute.tcl.orig_gemm)"
}

pinswap_fix() {   # repair_timing without pin swapping (resizer_timing.tcl, resizer_routing_timing.tcl)
    # OpenROAD 41a51eaf swapped A_N and B of an and2b_1 in row_v1 (step 17,
    # "RSZ-0043 Swapped pins on 1 instances"): and2b is not commutative, the
    # netlist changed function and LVS cannot see it (layout = wrong netlist).
    local f
    for f in "$OL/scripts/openroad/resizer_timing.tcl" "$OL/scripts/openroad/resizer_routing_timing.tcl"; do
        [ -f "$f" ] || continue
        grep -q -- "-skip_pin_swap" "$f" && continue
        [ -f "$f.orig_gemm" ] || cp "$f" "$f.orig_gemm"
        python3 - "$f" <<'PY' || { echo "  could not add -skip_pin_swap to $f"; return 1; }
import sys
p = sys.argv[1]; s = open(p).read()
key = "repair_timing -setup \\\n"
if key not in s:
    sys.exit(1)
open(p, "w").write(s.replace(key, "repair_timing -setup -skip_pin_swap \\\n"))
PY
        echo "  repair_timing -skip_pin_swap in $f (original kept as ${f##*/}.orig_gemm)"
    done
}

ol_patches() { gpl_hook && antenna_fix && dpl_hook && drt_seed_hook && pinswap_fix; }

core_install() {
    ol_patches || return 1
    local root sram="" lib=""
    for root in "${PDK_ROOT:-}" "$HOME/.volare" "$HOME/.ciel" "$OL/pdks"; do
        [ -n "$root" ] && [ -f "$root/${PDK:-sky130A}/libs.ref/sky130_sram_macros/lef/sky130_sram_2kbyte_1rw1r_32x512_8.lef" ] \
            && { sram=$root/${PDK:-sky130A}/libs.ref/sky130_sram_macros; lib=$root/${PDK:-sky130A}/libs.ref/sky130_fd_sc_hd/lef/sky130_fd_sc_hd.lef; break; }
    done
    if [ -n "$sram" ]; then
        pass "OpenRAM macro views found in $sram"
        # the OpenRAM LEF has no antenna data: config.tcl lists this annotated copy in EXTRA_LEFS
        python3 "$HERE/designs/gemm_core/macro_antenna_lef.py" --in "$sram/lef/sky130_sram_2kbyte_1rw1r_32x512_8.lef" \
            --lib-lef "$lib" --out "$HERE/designs/gemm_core/sram_antenna.lef" \
            || { fail "macro_antenna_lef.py (SRAM LEF with antenna data)"; return 1; }
    else
        echo "  note: OpenRAM macro LEF not found under \$PDK_ROOT, ~/.volare, ~/.ciel, \$OL/pdks;"
        echo "        config.tcl stops with a clear error inside OpenLane if they are really missing"
    fi
    # shellcheck disable=SC2086
    CORE_GEN_ARGS=${CORE_GEN_ARGS:-} "$HERE/install_into_openlane.sh" "$OL" --pe-area "$(cat "$STATE/pe_area.txt")" ${GEN_ARGS:-} >/dev/null \
        || { fail "install into $OL (floorplan checks?)"; return 1; }
    sed 's/^/  /' "$HERE/designs/gemm_core/floorplan.txt"
}

st_core_pre() {
    need array; need core-sim
    say "core-pre: GemmAccelerator lint + synthesis + floorplan"
    core_install || finish core-pre
    local log=$HERE/logs/gemm_core_pre_$STAMP.log
    echo "  OpenLane (interactive preflight) - log: ${log#"$KIT"/}"
    make -C "$OL" quick_run QUICK_RUN_DESIGN="gemm_core -it -file designs/gemm_core/preflight.tcl" 2>&1 | tee "$log"
    local rc=${PIPESTATUS[0]}
    RUNDIR=$OL/designs/gemm_core/runs/core_pre
    if [ "$rc" -eq 0 ] && grep -q "GEMM_CORE_PREFLIGHT_DONE" "$log"; then pass "lint, synthesis, floorplan (incl. PDN check) completed"
    else fail "preflight stopped - first error:"; grep -m3 -E "\[ERROR|Error:" "$log" | sed 's/^/    /'; fi
    local net; net=$(ls "$RUNDIR"/results/synthesis/*.v 2>/dev/null | head -1)
    if [ -n "$net" ]; then
        local ns nr nm
        ns=$(grep -cE "^\s*sky130_sram_2kbyte_1rw1r_32x512_8\s" "$net")
        nr=$(grep -cE "^\s*ProcessingElementRow\s" "$net")
        [ "$ns" = 80 ] && pass "netlist: 80 OpenRAM macros" || fail "netlist has $ns OpenRAM macros, expected 80"
        [ "$nr" = 32 ] && pass "netlist: 32 row macros" || fail "netlist has $nr row macros, expected 32"
        nm=$(grep -hoE "Number of cells:\s+[0-9]+" "$RUNDIR"/reports/synthesis/*.stat.rpt 2>/dev/null | tail -1)
        echo "  synthesis: $nm"
    else fail "no synthesis netlist in $RUNDIR/results/synthesis"; fi
    local placed want
    placed=$(grep -rhoE "Successfully placed [0-9]+ instances" "$RUNDIR/logs" 2>/dev/null | tail -1 | awk '{print $3}')
    want=$(awk '/GEMM_CORE_MACROS/{print $3}' "$HERE/designs/gemm_core/sizes.tcl")
    if [ "${placed:-0}" = "$want" ]; then pass "$want hard macros placed from macro.cfg"
    else
        fail "macro placement placed '${placed:-0}', expected $want"
        echo "  hint: 'Macros not found' -> GEN_ARGS='--name-style plain' openlane/run_flow.sh core-pre"
    fi
    NOTE="preflight run ${RUNDIR#"$OL"/}"
    finish core-pre
}

st_core() {
    need core-pre
    say "core: GemmAccelerator full run (rows + 80 OpenRAM macros) - expect several hours"
    need_disk "${MIN_DISK_GB:-40}"
    local prev; prev=$(core_best_run)
    if [ -d "$prev/reports/signoff" ]; then
        python3 "$KIT/tools/clock_latency.py" "$prev" "$HERE/designs/gemm_core/clk_latency.tcl" \
            || echo "  (no clock latency from the previous core run - using the seed from the array)"
    fi
    local tag=${TAG:-core_v11}
    # floorplan of v5/v6 unless CORE_GEN_ARGS is given (set but empty = layout v1)
    CORE_GEN_ARGS=${CORE_GEN_ARGS-$CORE_GEN_DEFAULT}
    echo "$tag" > "$STATE/core_last_tag.txt"
    rm -f "$HERE/designs/gemm_core/overrides.tcl" "$OL/designs/gemm_core/overrides.tcl"
    # routing guards of route_signoff.tcl (core_full.tcl): router seeds, antenna ECO rounds
    local ovr="# written by run_flow.sh core $STAMP"
    ovr+=$'\n'"set ::env(GEMM_DRT_SEEDS) \"${DRT_SEEDS:-42 7 23}\""
    route_overrides
    printf '%s\n' "$ovr" > "$HERE/designs/gemm_core/overrides.tcl"
    sed 's/^/  overrides: /' "$HERE/designs/gemm_core/overrides.tcl"
    core_install || finish core
    # floorplan options of this run, so core-probe / core-route rebuild the same files
    echo "${CORE_GEN_ARGS:-}" > "$STATE/core_gen_args_$tag.txt"
    [ -n "${CORE_GEN_ARGS:-}" ] && echo "  core floorplan options: $CORE_GEN_ARGS"
    ol_full "$tag"
    # global placement can still diverge (GPL-0307) on this floorplan: retry
    # once without timing-driven placement (the resizer fixes timing later)
    if grep -qs "GPL-0307" "$RUNDIR"/logs/placement/*global*.log; then
        echo "  global placement diverged (GPL-0307) - retrying once with PL_TIME_DRIVEN 0"
        printf '%s\n# after GPL-0307 in the previous attempt\nset ::env(PL_TIME_DRIVEN) 0\n' "$ovr" \
            > "$HERE/designs/gemm_core/overrides.tcl"
        FAILS=0
        core_install || finish core
        ol_full "$tag"
    fi
    rm -f "$HERE/designs/gemm_core/overrides.tcl" "$OL/designs/gemm_core/overrides.tcl"
    # every seed of DRT_SEEDS left violations: route again from the post-CTS
    # layout with three more seeds
    local drc=$RUNDIR/reports/routing/drt.drc
    if [ -s "$drc" ] && grep -q "violation type" "$drc"; then
        echo "  $tag: detailed routing left $(grep -c 'violation type' "$drc") violation(s) with every seed -"
        echo "  routing again from its post-CTS layout with other router seeds (run ${tag}r)"
        FAILS=0
        FROM=$tag TAG=${tag}r FORCE=1 DRT_SEEDS="${DRT_SEEDS_RETRY:-101 211 307}" st_core_route   # ends with core_verdict
        return
    fi
    core_verdict
}

core_last_tag() {   # name of the last core run started by core / core-route
    local t=""
    [ -f "$STATE/core_last_tag.txt" ] && t=$(cat "$STATE/core_last_tag.txt")
    echo "${t:-core_v1}"
}

core_best_run() {   # the core run later stages use: the last one that PASSED, else the last one started
    local r=""
    [ -f "$STATE/core_run.txt" ] && r=$(cat "$STATE/core_run.txt")
    [ -n "$r" ] && [ -d "$r" ] && { echo "$r"; return; }
    echo "$OL/designs/gemm_core/runs/$(core_last_tag)"
}

core_state_var() {   # core_state_var <run dir> <VAR>: value in the run's saved state, as a host path
    local v
    v=$(grep -E "^set ::env\($2\) " "$1/config.tcl" 2>/dev/null | tail -1 | sed -E "s/^set ::env\($2\) //; s/^\"//; s/\"$//")
    echo "${v/#\/openlane\//$OL/}"
}

same_floorplan() {   # same_floorplan <source run>: regenerated floorplan files = the layout that run built?
    local a b
    a=$(core_state_var "$1" DIE_AREA)
    b=$(sed -n 's/^set ::env(DIE_AREA) "\(.*\)"/\1/p' "$HERE/designs/gemm_core/sizes.tcl")
    [ -n "$a" ] || return 0
    if python3 -c 'import sys; a=list(map(float,sys.argv[1].split())); b=list(map(float,sys.argv[2].split())); sys.exit(0 if len(a)==len(b) and all(abs(x-y)<0.01 for x,y in zip(a,b)) else 1)' "$a" "$b"; then
        return 0
    fi
    echo "  the die of ${1##*/} is '$a' but the regenerated floorplan files say '$b':"
    echo "  CORE_GEN_ARGS differ from the run being continued (see openlane/state/core_gen_args_*.txt)"
    return 1
}

write_resume_params() {   # write_resume_params <from tag> <new tag> <route|probe> [iterations]
    cat > "$OL/designs/gemm_core/resume_params.tcl" <<EOF
# written by run_flow.sh $STAMP for designs/gemm_core/resume.tcl
set GEMM_FROM_TAG    $1
set GEMM_NEW_TAG     $2
set GEMM_MODE        $3
set GEMM_PROBE_ITERS ${4:-0}
EOF
}

ol_resume() {   # ol_resume <log>: OpenLane interactive run of resume.tcl (params already written)
    echo "  OpenLane (resume.tcl) - log: ${1#"$KIT"/}"
    mem_watch_start "${1%.log}_mem.txt"
    make -C "$OL" quick_run QUICK_RUN_DESIGN="gemm_core -it -file designs/gemm_core/resume.tcl" 2>&1 | tee "$1"
    local rc=${PIPESTATUS[0]}
    mem_watch_stop
    return "$rc"
}

triage_field() {   # triage_field <triage output file> <stage|signal>
    sed -n "s/^TRIAGE .*$2=\([^ ]*\).*/\1/p" "$1"
}

st_core_status() {   # where the running (or last) core run is - reads files only, safe any time
    local tag=${TAG:-$(core_last_tag)}
    local run=$OL/designs/gemm_core/runs/$tag
    say "core-status: $tag"
    [ -d "$run" ] || { echo "  no run directory ${run#"$OL"/} yet"; return 0; }
    local now first started step
    now=$(date +%s)
    first=$(ls -tr "$run"/logs/synthesis/*.log 2>/dev/null | head -1)
    if [ -n "$first" ]; then
        started=$(stat -c %Y "$first")
        printf "  running for  : %dh%02dm (since the first synthesis log)\n" $(( (now - started) / 3600 )) $(( (now - started) % 3600 / 60 ))
    fi
    step=$(grep -ho "\[STEP [0-9]*\]" "$run"/openlane.log 2>/dev/null | tail -1)
    [ -n "$step" ] && echo "  last step    : $step  $(grep -hE '\[INFO\]: (Running|Starting|Skipping)' "$run"/openlane.log 2>/dev/null | tail -1 | sed 's/.*\[INFO\]: //')"
    grep -qs "flow failed\|\[ERROR\]" "$run"/openlane.log && echo "  !! openlane.log has an error: $(grep -h -m1 '\[ERROR\]' "$run"/openlane.log | cut -c1-150)"
    [ -f "$run/reports/metrics.csv" ] && echo "  flow finished: reports/metrics.csv written - run: openlane/run_flow.sh core-check"
    local last
    last=$(ls -t "$run"/logs/*/*.log 2>/dev/null | head -1)
    if [ -n "$last" ]; then
        printf "  newest log   : %s (%s, updated %ds ago)\n" "${last#"$run"/}" "$(du -h "$last" | cut -f1)" $(( now - $(stat -c %Y "$last") ))
        tail -n 3 "$last" | cut -c1-150 | sed 's/^/      | /'
    fi
    local f
    for f in $(ls -tr "$run"/logs/routing/*.log 2>/dev/null); do
        grep -q "GRT-0096" "$f" || continue
        echo "  global route : ${f##*/}: $(grep -A11 'GRT-0096' "$f" | grep '^Total' | tail -1 | awk '{print "total overflow " $NF ", usage " $4}')"
    done
    f=$(ls -t "$run"/logs/routing/*detailed*.log 2>/dev/null | head -1)
    if [ -n "$f" ]; then
        echo "  detailed rt  : $(grep -hE 'Start .*(optimization iteration|routing)\.' "$f" | tail -1 | sed 's/.*\] //')  $(grep -h 'Number of violations' "$f" | tail -1 | sed 's/.*\] *//')"
    fi
    f=$(ls -t "$HERE"/logs/mem_gemm_core_"$tag"_*.txt "$HERE"/logs/gemm_core_route_"$tag"_*_mem.txt 2>/dev/null | head -1)
    [ -n "$f" ] && [ -s "$f" ] && echo "  memory now   : $(tail -n 1 "$f" | awk '{printf "%s: %s %s MB, free RAM %s MB, swap used %s MB", $1, $3, $2, $4, $5}')"
    local p
    p=$(ps -eo etime=,rss=,comm= 2>/dev/null | awk '$3 ~ /^(openroad|yosys|magic|netgen|klayout)/ {printf "%s (%d MB, %s)  ", $3, $2/1024, $1}')
    echo "  EDA process  : ${p:-none running}"
    echo "  disk free: $(disk_free_gb) GB"
}

st_core_triage() {
    local tag=${TAG:-$(core_last_tag)}
    local run=$OL/designs/gemm_core/runs/$tag
    say "core-triage: where and how $tag stopped"
    local out=$HERE/logs/core_triage_${tag}_$STAMP.txt
    {
        python3 "$KIT/tools/core_triage.py" "$run"
        echo; echo "--- this machine"
        free -m | sed 's/^/  /'
        df -h "$OL" | sed 's/^/  /'
        local k
        k=$(journalctl -k -b --no-pager 2>/dev/null | grep -i -E "out of memory|oom-kill|killed process" | tail -n 3)
        echo "  kernel OOM messages this boot: ${k:-none (or no permission to read the kernel log)}"
        coredumpctl list --no-pager 2>/dev/null | grep -i openroad | tail -n 3 | sed 's/^/  core dump: /'
        # a run that ended with GRT-0119 left its congestion report behind: map it
        local rpt def
        rpt=$(ls -t "$run"/tmp/routing/*congestion*.rpt 2>/dev/null | head -1)
        def=$(core_state_var "$run" CURRENT_DEF)
        [ -f "$def" ] || def=$(ls -t "$run"/tmp/cts/*.def "$run"/results/cts/*.def 2>/dev/null | head -1)
        if [ -s "$rpt" ] && [ -f "$def" ] && [ -f "$run/tmp/merged.nom.lef" ]; then
            echo; echo "--- congestion left by the router (${rpt#"$run"/})"
            python3 "$KIT/tools/core_congestion.py" "$rpt" "$def" "$run/tmp/merged.nom.lef" --nets
        fi
        if [ -f "$def" ] && [ -f "$run/tmp/merged.nom.lef" ]; then
            echo; echo "--- where the standard cells sit (${def#"$OL"/})"
            python3 "$KIT/tools/core_placement.py" "$def" "$run/tmp/merged.nom.lef"
            echo; echo "--- cells in the channels between the row macros"
            python3 "$KIT/tools/core_channels.py" "$def" "$run/tmp/merged.nom.lef"
        fi
        grep -h "keep_rows_clear" "$run"/logs/*/*.log 2>/dev/null | sed 's/^/  /' | tail -n 6
    } 2>&1 | tee "$out"
    echo "  (saved to ${out#"$KIT"/}) - triage finished"
}

st_core_probe() {
    need core-pre
    local from=${FROM:-$(core_last_tag)} iters=${ITERS:-0} tag=core_probe
    local src=$OL/designs/gemm_core/runs/$from run=$OL/designs/gemm_core/runs/core_probe
    say "core-probe: global route only on the post-CTS layout of $from ($iters congestion iterations)"
    need_disk 10
    [ -f "$src/config.tcl" ] || { echo "  no $src/config.tcl - run the core stage first"; exit 1; }
    rm -f "$HERE/designs/gemm_core/overrides.tcl" "$OL/designs/gemm_core/overrides.tcl"
    local ovr="# written by run_flow.sh core-probe $STAMP"
    route_overrides probe
    if [ "$(printf '%s\n' "$ovr" | wc -l)" -gt 1 ]; then
        printf '%s\n' "$ovr" > "$HERE/designs/gemm_core/overrides.tcl"
        sed 's/^/  overrides: /' "$HERE/designs/gemm_core/overrides.tcl"
    fi
    CORE_GEN_ARGS=$(cat "$STATE/core_gen_args_$from.txt" 2>/dev/null) core_install || exit 1
    same_floorplan "$src" || exit 1
    write_resume_params "$from" "$tag" probe "$iters"
    local log=$HERE/logs/gemm_core_probe_$STAMP.log
    ol_resume "$log"
    rm -f "$HERE/designs/gemm_core/overrides.tcl" "$OL/designs/gemm_core/overrides.tcl"
    python3 "$KIT/tools/core_triage.py" "$run" > "$STATE/triage_probe.txt"
    sed -n '/^--- routing resources/,/^--- last/p' "$STATE/triage_probe.txt" | sed '$d'
    if grep -q "GEMM_PROBE_DONE" "$log"; then
        pass "global route finished in the probe (congestion allowed)"
        local def lef rpt
        def=$(core_state_var "$src" CURRENT_DEF)
        [ -f "$def" ] || def=$(ls -t "$src"/tmp/cts/*.def "$src"/results/cts/*.def 2>/dev/null | head -1)
        lef=$run/tmp/merged.nom.lef
        rpt=$run/reports/routing/grt_probe_congestion.rpt
        if [ -f "$rpt" ] && [ -f "$def" ] && [ -f "$lef" ]; then
            python3 "$KIT/tools/core_congestion.py" "$rpt" "$def" "$lef" --nets | tee "$HERE/logs/core_congestion_$STAMP.txt"
        else
            echo "  missing for the map: ${rpt##*/} ${def:-<def>} ${lef##*/}"
        fi
        local guide=$run/tmp/routing/grt_probe.guide
        if [ -f "$guide" ] && [ -f "$def" ] && [ -f "$lef" ]; then
            echo "--- nets the global route left through a macro (macro_cross.py)"
            python3 "$HERE/designs/gemm_core/macro_cross.py" --guide "$guide" --def "$def" --lef "$lef" \
                --grt-obs "$(core_state_var "$run" GRT_OBS)" --report "$run/reports/routing/macro_cross.rpt" \
                | sed -n '1,/^  nets with a guide/p'
        else
            echo "  no probe guide - macro_cross.py skipped"
        fi
        local odb=$run/tmp/routing/grt_probe.odb
        [ -f "$odb" ] && echo "  layout + congestion map: ${odb#"$OL"/} ($(du -h "$odb" | cut -f1); delete when done)"
        NOTE="probe of $from: $(grep -c 'violation type' "$rpt" 2>/dev/null || echo 0) overflowing gcell edges"
    else
        fail "global route crashed even in the probe (see ${log#"$KIT"/})"
        sed -n '/^--- last/,$p' "$STATE/triage_probe.txt"
        NOTE="probe of $from crashed"
    fi
    echo "| $STAMP | core-probe | INFO | ${MEMPEAK:--} | $NOTE |" >> "$LOG"
}

st_core_precheck() {   # early look at later steps on an existing run, no routing
    # antenna check (OpenROAD ARC, as signoff runs it) on the routed layout of
    # FROM, plus the setup/hold of its signoff STA. ~15 min.
    need core-pre
    local from=${FROM:-$(core_last_tag)}
    local tag=${from}_check src=$OL/designs/gemm_core/runs/$from
    say "core-precheck: antenna check + timing of the routed layout of $from (run $tag, no routing)"
    need_disk 10
    [ -f "$src/config.tcl" ] || { echo "  no $src/config.tcl - nothing to check"; exit 1; }
    rm -f "$HERE/designs/gemm_core/overrides.tcl" "$OL/designs/gemm_core/overrides.tcl"
    CORE_GEN_ARGS=$(cat "$STATE/core_gen_args_$from.txt" 2>/dev/null) core_install >/dev/null || exit 1
    write_resume_params "$from" "$tag" check
    local log=$HERE/logs/gemm_core_check_${from}_$STAMP.log
    ol_resume "$log" > /dev/null || true
    local run=$OL/designs/gemm_core/runs/$tag
    echo "--- antenna on the routed layout of $from"
    if grep -q GEMM_CHECK_DONE "$log"; then
        grep -h -E "ANT-000[0-9]|Found [0-9]+ (pin|net)" "$run"/logs/signoff/*arc.log 2>/dev/null | tail -n 4 | sed 's/^/  /'
        local rpt; rpt=$(ls -t "$run"/reports/signoff/*antenna_violators.rpt 2>/dev/null | head -1)
        [ -s "$rpt" ] && { echo "  first violators (${rpt##*/}):"; head -n 12 "$rpt" | sed 's/^/    /'; }
    else
        echo "  the check did not finish - last lines of ${log#"$KIT"/}:"; tail -n 8 "$log" | sed 's/^/    /'
    fi
    echo "--- what signoff of $from already measured (I/O timing waived; -1 / MISSING = step did not run)"
    python3 "$HERE/check_openlane_run.py" --waive-io-timing "$src" 2>&1 \
        | grep -E "tritonRoute|Magic|lvs|antenna|spef|setup|hold|RESULT" | sed 's/^/  /'
    echo "| $STAMP | core-precheck | INFO | ${MEMPEAK:--} | antenna + timing of $from |" >> "$LOG"
}

st_core_route() {
    need core-pre
    local from=${FROM:-$(core_last_tag)}
    local tag=${TAG:-${from}r}
    local src=$OL/designs/gemm_core/runs/$from
    say "core-route: routing + signoff from the post-CTS layout of $from (new run $tag)"
    need_disk "${MIN_DISK_GB:-40}"
    [ -f "$src/config.tcl" ] || { echo "  no $src/config.tcl - nothing to continue from"; exit 1; }
    [ "$from" != "$tag" ] || { echo "  TAG must differ from FROM"; exit 1; }
    python3 "$KIT/tools/core_triage.py" "$src" > "$STATE/triage_$from.txt"
    local stage; stage=$(triage_field "$STATE/triage_$from.txt" stage)
    local ovr="# written by run_flow.sh core-route $STAMP (continuing $from)"
    case "$stage" in
        rsz|dpl|after-dpl)
            echo "  $from died after global routing had finished ($stage): this run skips the"
            echo "  GRT-based repair_design (config.tcl already skips the GRT-based timing repair)"
            ovr+=$'\n''set ::env(GLB_RESIZER_DESIGN_OPTIMIZATIONS) 0' ;;
        grt-overflow|grt-initial|grt-congestion)
            if [ "${GRT_ALLOW:-0}" = 1 ]; then
                echo "  $from died inside global routing ($stage); continuing with GRT_ALLOW=1:"
                echo "  global route may finish with overflow and detailed routing has to clean it up"
            elif [ "${FORCE:-0}" != 1 ]; then
                echo "  $from stopped INSIDE global routing ($stage); the same layout and settings"
                echo "  would stop there again. Look at the congestion first (core-triage / core-probe)."
                echo "  If the overflow left is small: GRT_ALLOW=1 GRT_ITERS=18 openlane/run_flow.sh core-route"
                echo "  lets global route finish with it and detailed routing clean it up."
                exit 1
            fi ;;
        finished)
            if [ -z "${DRT_SEED:-}${DRT_SEEDS:-}${GRT_ADJ:-}${ANT_RPT:-}${ANT_ECO:-}" ] && [ "${FORCE:-0}" != 1 ]; then
                echo "  $from ran to the end. To route it again from its post-CTS layout give what"
                echo "  should change (DRT_SEEDS / GRT_ADJ / ANT_ECO / ANT_RPT) or FORCE=1."
                exit 1
            fi
            echo "  $from ran to the end - routing it again from its post-CTS layout" ;;
        *)
            if [ "${FORCE:-0}" != 1 ]; then
                echo "  cannot tell where $from stopped (triage stage '$stage'); see"
                echo "  openlane/run_flow.sh core-triage. FORCE=1 continues anyway."
                exit 1
            fi ;;
    esac
    # GRT_ALLOW=1: global route may end with overflow (detailed routing fixes it);
    # GRT_ITERS is in route_overrides (FastRoute here crashes on very long
    # detours, which only show up in the late iterations of a congested design)
    [ -n "${GRT_ALLOW:-}" ] && ovr+=$'\n'"set ::env(GRT_ALLOW_CONGESTION) $GRT_ALLOW"
    # DRT_ITERS=N: cap on detailed-routing optimisation iterations (default 64)
    [ -n "${DRT_ITERS:-}" ] && ovr+=$'\n'"set ::env(DRT_OPT_ITERS) $DRT_ITERS"
    [ -n "${GLB_RSZ_DESIGN:-}" ] && ovr+=$'\n'"set ::env(GLB_RESIZER_DESIGN_OPTIMIZATIONS) $GLB_RSZ_DESIGN"
    [ -n "${GLB_RSZ_TIMING:-}" ] && ovr+=$'\n'"set ::env(GLB_RESIZER_TIMING_OPTIMIZATIONS) $GLB_RSZ_TIMING"
    # detailed-router seeds, tried in turn until one routes clean (resume.tcl);
    # DRT_SEEDS="7 23 101" or DRT_SEED=7 (then 23 and 101 follow). Not 42: that
    # is the seed the normal flow already used.
    local seeds=${DRT_SEEDS:-"${DRT_SEED:-7} 23 101"}
    ovr+=$'\n'"set ::env(GEMM_DRT_SEEDS) \"$seeds\""
    ovr+=$'\n'"set ::env(DRT_OR_SEED) ${seeds%% *}"
    route_overrides
    # antenna ECO round 0: diodes for the violations an earlier route of this
    # same post-CTS netlist had, before the first global route
    if [ "${ANT_ECO:-3}" != 0 ]; then
        local arpt=${ANT_RPT:-}
        [ -n "$arpt" ] || arpt=$(ls -t "$src"/reports/signoff/*antenna_violators.rpt \
            "$OL/designs/gemm_core/runs/${from}_check"/reports/signoff/*antenna_violators.rpt 2>/dev/null | head -1)
        if [ -n "$arpt" ] && [ -f "$arpt" ]; then
            echo "  antenna ECO round 0 from ${arpt#"$OL"/} ($(grep -c 'Partial/Required' "$arpt") violations)"
            ovr+=$'\n'"set ::env(GEMM_ANT_ECO_RPT) \"${arpt/#$OL\//\/openlane\/}\""
        fi
    fi
    printf '%s\n' "$ovr" > "$HERE/designs/gemm_core/overrides.tcl"
    sed 's/^/  overrides: /' "$HERE/designs/gemm_core/overrides.tcl"
    local fp_args; fp_args=$(cat "$STATE/core_gen_args_$from.txt" 2>/dev/null)
    CORE_GEN_ARGS=$fp_args core_install || exit 1
    same_floorplan "$src" || exit 1
    echo "$fp_args" > "$STATE/core_gen_args_$tag.txt"
    echo "$tag" > "$STATE/core_last_tag.txt"
    write_resume_params "$from" "$tag" route
    local log=$HERE/logs/gemm_core_route_${tag}_$STAMP.log
    ol_resume "$log" || true
    RUNDIR=$OL/designs/gemm_core/runs/$tag
    # the GRT timing repair runs the same global route, then repair_timing: if
    # that step dies the same way, retry once without it
    python3 "$KIT/tools/core_triage.py" "$RUNDIR" > "$STATE/triage_$tag.txt"
    local last; last=$(sed -n 's/^last log *: \([^ ]*\).*/\1/p' "$STATE/triage_$tag.txt")
    local s2; s2=$(triage_field "$STATE/triage_$tag.txt" stage)
    if [[ "$last" == *resizer_timing* || "$last" == *resizer_design* ]] && [[ "$s2" =~ ^(rsz|dpl|after-dpl)$ ]] \
       && ! grep -q "GLB_RESIZER_TIMING_OPTIMIZATIONS) 0" "$HERE/designs/gemm_core/overrides.tcl"; then
        echo "  $tag died in ${last##*/} after global routing - retrying once without both GRT resizer steps"
        printf '%s\nset ::env(GLB_RESIZER_DESIGN_OPTIMIZATIONS) 0\nset ::env(GLB_RESIZER_TIMING_OPTIMIZATIONS) 0\n' \
            "$ovr" > "$HERE/designs/gemm_core/overrides.tcl"
        CORE_GEN_ARGS=$fp_args core_install || exit 1
        write_resume_params "$from" "$tag" route
        ol_resume "${log%.log}_retry.log" || true
    fi
    rm -f "$HERE/designs/gemm_core/overrides.tcl" "$OL/designs/gemm_core/overrides.tcl"
    core_verdict
}

core_verdict() {
    FAILS=0      # see array_verdict
    local placed want
    placed=$(grep -rhoE "Successfully placed [0-9]+ instances" "$RUNDIR/logs" 2>/dev/null | tail -1 | awk '{print $3}')
    want=$(awk '/GEMM_CORE_MACROS/{print $3}' "$HERE/designs/gemm_core/sizes.tcl")
    [ "${placed:-0}" = "$want" ] && pass "$want hard macros placed" || fail "placed '${placed:-0}' hard macros, expected $want"
    check_run "$RUNDIR" --waive-io-timing
    NOTE="GDS: ${RUNDIR#"$OL"/}/results/final/gds/GemmAccelerator.gds (I/O timing waived)"
    [ $FAILS -eq 0 ] && echo "$RUNDIR" > "$STATE/core_run.txt"    # core-gls / core-check use it
    finish core
}

st_core_gls() {   # original testbench on the final netlist, 3 matrix shapes, cycles vs the FPGA RTL
    need sim
    local run
    if [ -n "${TAG:-}" ]; then run=$OL/designs/gemm_core/runs/$TAG
    else run=$(ls -td "$OL"/designs/gemm_core/runs/*/results/final/verilog/gl 2>/dev/null | head -1); run=${run%/results/final/verilog/gl}; fi
    [ -f "$run/results/final/verilog/gl/GemmAccelerator.nl.v" ] \
        || { echo "no core run with results/final/verilog/gl/GemmAccelerator.nl.v (TAG=<run> to pick one)"; exit 1; }
    # rows as their gate netlist by default: with rtl rows a bad row netlist goes unseen
    export ROW=${ROW:-gl}
    say "core-gls: original testbench on the netlist of ${run#"$OL"/} (rows: $ROW)"
    local out=$HERE/logs/core_gls_$STAMP; mkdir -p "$out"
    local shape tag t0
    # "" = the testbench's own 64x64x64; the other two reach the second bank of the 1024-word memories
    for shape in "" "8,32,544" "16,992,32"; do
        tag=${shape:+_M$(echo "$shape" | awk -F, '{print $1"K"$2"N"$3}')}
        TB_SHAPE="$shape" "$KIT/sim/run_system.sh" orig "$REPO" > "$out/sys$tag.log" 2>&1 || true
        grep -E "RESULT_VALID_FIRST|RESULT_ACCEPT" "$KIT/sim/build_system_orig$tag/system.log" > "$out/cycles_orig$tag.txt" 2>/dev/null
        t0=$(date +%s)
        if TB_SHAPE="$shape" BUILD="$KIT/sim/build_gls$tag" OL=$OL "$KIT/sim/run_gls.sh" "$run" "$REPO" > "$out/gls$tag.log" 2>&1; then
            pass "${shape:-64,64,64}: OVERALL PASS ($(( $(date +%s) - t0 )) s)"
        else fail "${shape:-64,64,64}: gate-level sim failed (see ${out#"$KIT"/}/gls$tag.log)"; tail -n 4 "$out/gls$tag.log" | sed 's/^/    /'; fi
        cp "$KIT/sim/build_gls$tag/cycles_gls.txt" "$out/cycles_gls$tag.txt" 2>/dev/null
        if [ -s "$out/cycles_orig$tag.txt" ] && diff -q "$out/cycles_orig$tag.txt" "$out/cycles_gls$tag.txt" >/dev/null 2>&1; then
            pass "${shape:-64,64,64}: same cycle for all $(wc -l < "$out/cycles_orig$tag.txt") result events as the FPGA RTL"
        else fail "${shape:-64,64,64}: result cycles differ from the FPGA RTL"; fi
    done
    NOTE="${run##*/}, logs in ${out#"$KIT"/}"
    finish core-gls
}

# =========================================================================
# AXI accelerator IP: GEMM_top (rtl_asic/axi) = GemmAxiShell + GemmAccelerator
st_axi_sim() {
    need sim
    say "axi-sim: AXI IP RTL - skid buffer unit test, original testbench (thin, reg, reg + OpenRAM, 3 shapes)"
    local out=$HERE/logs/axi_sim_$STAMP; mkdir -p "$out"
    if "$KIT/sim/run_axi.sh" "$REPO" 2>&1 | tee "$out/run_axi.log"; [ "${PIPESTATUS[0]}" -eq 0 ]; then
        pass "sim/run_axi.sh: ALL PASS"
    else fail "sim/run_axi.sh (see ${out#"$KIT"/}/run_axi.log)"; fi
    cp "$KIT"/sim/build_axi/cycles_*.txt "$out/" 2>/dev/null || true
    NOTE="logs in ${out#"$KIT"/}"
    finish axi-sim
}

st_axi_shell() {
    need axi-sim
    say "axi-shell: GemmAxiShell alone, thin and reg - what the AXI interface costs"
    ol_patches || { fail "patch OpenLane scripts"; finish axi-shell; }
    local d=$OL/designs/gemm_axi_shell v r
    python3 "$HERE/gen_axi_files.py" --out "$HERE/designs" || { fail "gen_axi_files.py"; finish axi-shell; }
    # only this design is copied (install_into_openlane.sh would also regenerate the core floorplan)
    mkdir -p "$d/src"
    cp "$HERE/designs/gemm_common.tcl" "$OL/designs/"
    cp "$HERE"/designs/gemm_axi_shell/* "$d/"
    cp "$KIT"/rtl_asic/*.v "$KIT"/rtl_asic/*.vh "$KIT"/rtl_asic/axi/*.v "$d/src/"
    for v in thin reg; do
        r=0; [ "$v" = reg ] && r=1
        echo "set ::env(GEMM_AXIS_REG) $r   ;# written by run_flow.sh axi-shell" > "$d/variant.tcl"
        # 1) calibration run with ideal outside clocks, only to measure the shell's clock latency
        rm -f "$d/clk_latency.tcl"
        ol_run gemm_axi_shell "shell_${v}_cal"
        if python3 "$KIT/tools/clock_latency.py" "$RUNDIR" "$d/clk_latency.tcl" > "$HERE/logs/axi_shell_lat_${v}_$STAMP.log" 2>&1; then
            pass "shell_$v clock latency: $(grep -o 'MIN) [0-9.]*\|MAX) [0-9.]*' "$d/clk_latency.tcl" | tr '\n' ' ')"
        else fail "shell_$v: could not measure the clock latency (see openlane/logs/axi_shell_lat_${v}_$STAMP.log)"; rm -f "$d/clk_latency.tcl"; fi
        # 2) the measured run: port delays from that latency (shell.sdc)
        ol_run gemm_axi_shell "shell_$v"
        check_run "$RUNDIR" --waive-io-timing
        if "$KIT/tools/axi_shell_power.sh" "$RUNDIR" > "$HERE/logs/axi_shell_power_${v}_$STAMP.log" 2>&1; then
            pass "shell_$v power: $(grep -E '^Total' "$RUNDIR/reports/power/vectorless.design.rpt" | awk '{print $5" W"}')"
        else fail "shell_$v power (see openlane/logs/axi_shell_power_${v}_$STAMP.log)"; fi
    done
    rm -f "$d/variant.tcl" "$d/clk_latency.tcl"
    local core=${CORE_RUN:-$(core_best_run)} md=$HERE/logs/axi_overhead_$STAMP.md
    [ -f "$core/reports/power/vectorless.design.rpt" ] \
        || echo "  (no vectorless power report in ${core#"$OL"/} yet - run: tools/power.sh $core)"
    if python3 "$KIT/tools/axi_overhead.py" "$core" "$d/runs/shell_thin" "$d/runs/shell_reg" --md "$md"; then
        pass "overhead table: ${md#"$KIT"/}"
    else fail "tools/axi_overhead.py"; fi
    NOTE="overhead table ${md#"$KIT"/}"
    finish axi-shell
}

st_axi_gls() {
    need axi-sim
    local core=${CORE_RUN:-$(core_best_run)} shape tag out=$HERE/logs/axi_gls_$STAMP
    mkdir -p "$out"
    say "axi-gls: GEMM_top (reg) RTL around the final netlist of ${core##*/}, rows gate-level"
    # AXI_GLS_SHAPES="8,32,544 16,992,32" adds the other two shapes (~10 and ~22 min more)
    for shape in "" ${AXI_GLS_SHAPES:-}; do
        tag=${shape:+_M$(echo "$shape" | awk -F, '{print $1"K"$2"N"$3}')}
        if WRAP=reg ROW=${ROW:-gl} TB_SHAPE="$shape" BUILD="$KIT/sim/build_gls_axireg$tag" OL=$OL \
               "$KIT/sim/run_gls.sh" "$core" "$REPO" > "$out/gls$tag.log" 2>&1; then
            pass "GEMM_top reg + ${core##*/}${shape:+ ($shape)}: OVERALL PASS, $(wc -l < "$KIT/sim/build_gls_axireg$tag/cycles_gls.txt") result events"
        else fail "GEMM_top reg + ${core##*/}${shape:+ ($shape)} (see ${out#"$KIT"/}/gls$tag.log)"; fi
    done
    NOTE="${core##*/}, logs in ${out#"$KIT"/}"
    finish axi-gls
}

# =========================================================================
case "${1:-}" in
    sim)   st_sim ;;
    pe)    st_pe ;;
    row)   st_row ;;
    array) st_array ;;
    array-check) need row; say "array-check: judge the existing array_v1 run (no OpenLane)"
                 RUNDIR=$OL/designs/gemm_array/runs/array_v1; array_verdict ;;
    core-sim)   st_core_sim ;;
    core-pre)   st_core_pre ;;
    core)       st_core ;;
    core-gls)   st_core_gls ;;
    core-triage) st_core_triage ;;
    core-status) st_core_status ;;
    core-probe) st_core_probe ;;
    core-route) st_core_route ;;
    core-precheck) st_core_precheck ;;
    core-check) need core-pre
                if [ -n "${TAG:-}" ]; then RUNDIR=$OL/designs/gemm_core/runs/$TAG; else RUNDIR=$(core_best_run); fi
                say "core-check: judge the existing run ${RUNDIR#"$OL"/} (no OpenLane)"; core_verdict ;;
    axi-sim)    st_axi_sim ;;
    axi-shell)  st_axi_shell ;;
    axi-gls)    st_axi_gls ;;
    all)   "$0" sim && "$0" pe && "$0" row && "$0" array && "$0" core-sim && "$0" core-pre && "$0" core ;;
    status) cat "$LOG" ;;
    *) sed -n '2,/^# ----/p' "$0" | sed '$d'; exit 2 ;;
esac
