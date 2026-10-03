#!/usr/bin/env bash
# ---------------------------------------------------------------------------
# run_flow.sh - the whole GEMM ASIC flow on OpenLane v1 (Docker/Podman),
# bottom-up, one checked stage at a time.
#
#   openlane/run_flow.sh sim      RTL: original vs ASIC, cycle-exact
#   openlane/run_flow.sh pe       level 0: one PE (measures the PE area)
#   openlane/run_flow.sh row      level 1: 32-PE row hardened as a macro
#   openlane/run_flow.sh array    level 2: FeatureSkew + 32 row macros + OutputDeskew
#   openlane/run_flow.sh array-check   re-judge the last array run without rerunning
#   openlane/run_flow.sh core-sim  RTL of the final core with the real OpenRAM models
#   openlane/run_flow.sh core-pre  level 3 preflight: lint + synthesis + floorplan (~1 h)
#   openlane/run_flow.sh core      level 3: GemmAccelerator = rows + 80 SRAM macros
#                                  (run core_v7, floorplan "--layout v3 --b-wide --b-gap-y 200 --strip 1000 --a-gap-x 200";
#                                  synthesis..CTS then route_signoff.tcl: router seeds, antenna ECO, LVS gate)
#   openlane/run_flow.sh core-status   where the running/last core run is (step, log, overflow, RAM)
#   openlane/run_flow.sh core-triage   why did the last core run stop (reads its logs)
#   openlane/run_flow.sh core-probe    global route only on the post-CTS layout: congestion map
#   openlane/run_flow.sh core-route    routing + signoff continued from the post-CTS layout
#                                      of the last core run in a new run <tag>r (no 2.5 h redo)
#   openlane/run_flow.sh core-precheck antenna check + timing of an existing routed run (~15 min)
#   openlane/run_flow.sh core-check    re-judge the last core run without rerunning
#   openlane/run_flow.sh core-gls  testbench on the final gate-level netlist (after core)
#   openlane/run_flow.sh all      sim -> pe -> row -> array, stops at the first FAIL
#   openlane/run_flow.sh status   what has passed so far
#
# Each stage refuses to start until the one before it passed, prints
# "STAGE <x> PASS|FAIL", appends a line (with peak RAM) to openlane/LOG.md,
# and on PASS inside a git repo commits + tags "ol-<stage>-pass-<time>".
#
# OpenLane is started exactly the way your OpenLane checkout does it:
#   make -C $OL quick_run QUICK_RUN_DESIGN="<design> -tag <tag> -overwrite"
# i.e. same image, same PDK mount, same docker/podman user handling as
# `make mount`, just non-interactive.
#
# Environment (defaults in brackets):
#   OL     OpenLane checkout (has flow.tcl, Makefile)     [$HOME/OpenLane]
#   REPO   original GEMM repo                             [../GEMM_32x32_KV260-main]
#   PDK_ROOT / PDK   passed through to OpenLane's make    [OpenLane's defaults]
#   GEN_ARGS extra geometry options for the row/array, e.g. "--util 0.45 --gap 30"
#   CORE_GEN_ARGS options for gen_core_files.py (core floorplan only)
#                 [--layout v3 --b-wide --b-gap-y 200 --strip 1000 --a-gap-x 200]; "" = layout v1
#   TAG    run name of the core stage [core_v6]; the core-* stages after it
#          default to the last core run started (state/core_last_tag.txt)
#   FROM / TAG / ITERS / FORCE   for core-probe / core-route (see those stages)
#   GRT_ALLOW / GRT_ITERS / DRT_ITERS / DRT_SEED(S) / GLB_RSZ_DESIGN / GLB_RSZ_TIMING   routing overrides for core-route
#   DRT_SEEDS  detailed-router seeds tried in turn  [core: "42 7 23", core-route: "7 23 101"]
#   ANT_ECO    antenna ECO rounds after routing, core / core-route [2]; 0 = off
#   ANT_RPT    core-route: antenna report whose violations get diodes before the
#              first global route [newest antenna_violators.rpt of FROM / FROM_check]
#   GRT_ADJ    GRT_LAYER_ADJUSTMENTS (li1,met1,..,met5) for core / core-route / core-probe [config.tcl]
#   MET5_OVER_SRAM=1  allow signal routing on met5 over the SRAMs again (core-v6 behaviour)
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
    if [ $result = PASS ] && git -C "$KIT" rev-parse --is-inside-work-tree >/dev/null 2>&1; then
        git -C "$KIT" add -A rtl_asic sim openlane tools 2>/dev/null
        git -C "$KIT" commit -qm "OpenLane stage $st PASS" >/dev/null 2>&1
        git -C "$KIT" tag "ol-$st-pass-$STAMP" 2>/dev/null && echo "  git tag ol-$st-pass-$STAMP"
    fi
    if [ $result = PASS ]; then printf "\n\033[32mSTAGE %s PASS\033[0m\n" "$st"
    else printf "\n\033[31mSTAGE %s FAIL\033[0m (%d problems)\n" "$st" "$FAILS"; exit 1; fi
}

mem_watch_start() {   # mem_watch_start <file>: every 10 s, biggest EDA process RSS + free RAM + swap
    MEMW_FILE=$1; : > "$MEMW_FILE"
    (
        while :; do
            p=$(ps -eo rss=,comm= 2>/dev/null | awk '$2 ~ /^(openroad|magic|netgen|klayout|yosys|cvc)/ && $1 > m { m = $1; c = $2 }
                                                 END { printf "%d %s", m / 1024, (c == "" ? "-" : c) }')
            a=$(awk '/^MemAvailable:/{print int($2/1024)}' /proc/meminfo)
            s=$(awk '/^SwapTotal:/{t=$2} /^SwapFree:/{f=$2} END{print int((t-f)/1024)}' /proc/meminfo)
            echo "$(date +%H:%M:%S) $p $a $s" >> "$MEMW_FILE"
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
    [ "${MET5_OVER_SRAM:-0}" = 1 ] && ovr+=$'\n'"catch { unset ::env(GRT_OBS) }"
    [ "${1:-}" = probe ] && return 0
    ovr+=$'\n'"set ::env(GEMM_ANT_ECO_ITERS) ${ANT_ECO:-2}"
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

ol_patches() { gpl_hook && antenna_fix && dpl_hook && drt_seed_hook; }

core_install() {
    ol_patches || return 1
    # shellcheck disable=SC2086
    CORE_GEN_ARGS=${CORE_GEN_ARGS:-} "$HERE/install_into_openlane.sh" "$OL" --pe-area "$(cat "$STATE/pe_area.txt")" ${GEN_ARGS:-} >/dev/null \
        || { fail "install into $OL (floorplan checks?)"; return 1; }
    sed 's/^/  /' "$HERE/designs/gemm_core/floorplan.txt"
    local root sram=""
    for root in "${PDK_ROOT:-}" "$HOME/.volare" "$HOME/.ciel" "$OL/pdks"; do
        [ -n "$root" ] && [ -f "$root/${PDK:-sky130A}/libs.ref/sky130_sram_macros/lef/sky130_sram_2kbyte_1rw1r_32x512_8.lef" ] \
            && { sram=$root/${PDK:-sky130A}/libs.ref/sky130_sram_macros; break; }
    done
    if [ -n "$sram" ]; then pass "OpenRAM macro views found in $sram"
    else
        echo "  note: OpenRAM macro LEF not found under \$PDK_ROOT, ~/.volare, ~/.ciel, \$OL/pdks;"
        echo "        config.tcl stops with a clear error inside OpenLane if they are really missing"
    fi
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
    local prev; prev=$(core_best_run)
    if [ -d "$prev/reports/signoff" ]; then
        python3 "$KIT/tools/clock_latency.py" "$prev" "$HERE/designs/gemm_core/clk_latency.tcl" \
            || echo "  (no clock latency from the previous core run - using the seed from the array)"
    fi
    local tag=${TAG:-core_v7}
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
    # GRT_ITERS=N: congestion iterations (FastRoute here crashes on very long
    # detours, which only show up in the late iterations of a congested design)
    [ -n "${GRT_ALLOW:-}" ] && ovr+=$'\n'"set ::env(GRT_ALLOW_CONGESTION) $GRT_ALLOW"
    [ -n "${GRT_ITERS:-}" ] && ovr+=$'\n'"set ::env(GRT_OVERFLOW_ITERS) $GRT_ITERS"
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
    if [ "${ANT_ECO:-2}" != 0 ]; then
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

st_core_gls() {
    need core
    say "core-gls: original testbench on the final gate-level netlist of the core"
    local out=$HERE/logs/core_gls_$STAMP; mkdir -p "$out"
    "$KIT/sim/run_system.sh" orig "$REPO" > "$out/sys_orig.log" 2>&1 || true
    grep -E "RESULT_VALID_FIRST|RESULT_ACCEPT" "$KIT/sim/build_system_orig/system.log" > "$out/cycles_orig.txt" 2>/dev/null
    local run; run=$(core_best_run)
    echo "  netlist from ${run#"$OL"/}"
    if OL=$OL "$KIT/sim/run_gls.sh" "$run" "$REPO" > "$out/gls.log" 2>&1; then
        pass "gate-level: OVERALL PASS"
    else fail "gate-level sim failed (see ${out#"$KIT"/}/gls.log)"; tail -n 8 "$out/gls.log" | sed 's/^/    /'; fi
    if [ -s "$out/cycles_orig.txt" ] && diff -q "$out/cycles_orig.txt" "$KIT/sim/build_gls/cycles_gls.txt" >/dev/null 2>&1; then
        pass "gate-level: same cycle for all $(wc -l < "$out/cycles_orig.txt") result events as the FPGA RTL"
    else fail "gate-level result cycles differ from the FPGA RTL"; fi
    NOTE="logs in ${out#"$KIT"/}"
    finish core-gls
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
    all)   "$0" sim && "$0" pe && "$0" row && "$0" array && "$0" core-sim && "$0" core-pre && "$0" core ;;
    status) cat "$LOG" ;;
    *) sed -n '2,53p' "$0"; exit 2 ;;
esac
