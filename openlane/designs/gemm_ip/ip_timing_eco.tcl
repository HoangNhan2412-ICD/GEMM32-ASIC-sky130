# ---------------------------------------------------------------------------
# ip_timing_eco.tcl - setup (and hold) repair after a global route of gemm_ip,
# with the antenna diodes of that global route already in the design.
# Run by gemm_ip_timing_eco in ip_route_signoff.tcl (OpenROAD, run_openroad_script).
#
# Why: GRT_REPAIR_ANTENNAS puts its diodes in global_routing, after the last
# resizer step, and nothing re-times the design afterwards. ip_v2: 22 diodes
# on _10437_ (0.27 pF) behind an o21ai_1, 3.7 ns on one gate, Typical setup
# -2.00 ns on 8 endpoints (o_result_data of quantize lane 0); OpenSTA with that
# one cell as o21ai_4 gives -0.21 ns.
#
# Steps as OpenLane's resizer_routing_timing.tcl (global route, parasitics from
# it, repair_timing, detailed placement), plus:
#   - repair_design only with GEMM_IP_TIMING_ECO_DESIGN 1 (default 0: the
#     signoff of core_v11 / ip_v2 lists ~20000 max-slew pins, fixing all of
#     them is a much larger change than the paths this step is for);
#   - prints "gemm_timing_eco: changed N" (cells resized or added), which
#     ip_route_signoff.tcl uses to decide whether to route globally again.
# Settings (defaults in brackets):
#   GEMM_IP_TIMING_ECO_SETUP_MARGIN  [GLB_RESIZER_SETUP_SLACK_MARGIN]
#   GEMM_IP_TIMING_ECO_HOLD_MARGIN   [0.05]
#   GEMM_IP_TIMING_ECO_MAX_BUFFER_PERCENT [5]
#   GEMM_IP_TIMING_ECO_DESIGN        [0]
# ---------------------------------------------------------------------------
source $::env(SCRIPTS_DIR)/openroad/common/io.tcl
set read_args [list]
if { $::env(RSZ_MULTICORNER_LIB) } {
    lappend read_args -lib_fastest $::env(RSZ_LIB_FASTEST)
    lappend read_args -lib_slowest $::env(RSZ_LIB_SLOWEST)
}
lappend read_args -lib_typical $::env(RSZ_LIB)
read {*}$read_args

proc eco_env {name default} {
    return [expr {[info exists ::env($name)] ? $::env($name) : $default}]
}
set setup_margin [eco_env GEMM_IP_TIMING_ECO_SETUP_MARGIN $::env(GLB_RESIZER_SETUP_SLACK_MARGIN)]
set hold_margin  [eco_env GEMM_IP_TIMING_ECO_HOLD_MARGIN 0.05]
set max_buf      [eco_env GEMM_IP_TIMING_ECO_MAX_BUFFER_PERCENT 5]
set do_design    [eco_env GEMM_IP_TIMING_ECO_DESIGN 0]

set_propagated_clock [all_clocks]
source $::env(SCRIPTS_DIR)/openroad/common/resizer.tcl
set_dont_touch_wrapper
if { [info exists ::env(DONT_USE_CELLS)] } {
    set_dont_use $::env(DONT_USE_CELLS)
}
source $::env(SCRIPTS_DIR)/openroad/common/set_routing_layers.tcl
source $::env(SCRIPTS_DIR)/openroad/common/set_layer_adjustments.tcl

# the routes of the global route that just ran are not in the database
set arg_list [list -congestion_iterations $::env(GRT_OVERFLOW_ITERS) -verbose]
lappend arg_list -congestion_report_file $::env(GRT_CONGESTION_REPORT_FILE)
if { $::env(GRT_ALLOW_CONGESTION) == 1 } {
    lappend arg_list -allow_congestion
}
global_route {*}$arg_list
source $::env(SCRIPTS_DIR)/openroad/common/set_rc.tcl
estimate_parasitics -global_routing

proc eco_masters {} {
    set m [dict create]
    foreach inst [[ord::get_db_block] getInsts] {
        dict set m [$inst getName] [[$inst getMaster] getName]
    }
    return $m
}
proc eco_report {tag} {
    puts "gemm_timing_eco: $tag: setup wns [format %.3f [sta::worst_slack_cmd max]]\
          tns [format %.3f [sta::total_negative_slack_cmd max]], hold wns [format %.3f [sta::worst_slack_cmd min]]"
}

set before [eco_masters]
eco_report "before"
if { $do_design } {
    repair_design
    eco_report "after repair_design"
}
repair_timing -setup -skip_pin_swap -setup_margin $setup_margin -max_buffer_percent $max_buf
eco_report "after repair_timing -setup"
repair_timing -hold -setup_margin $setup_margin -hold_margin $hold_margin -max_buffer_percent $max_buf
eco_report "after repair_timing -hold"

set after [eco_masters]
set resized 0
set added 0
dict for {name master} $after {
    if { ![dict exists $before $name] } {
        incr added
    } elseif { [dict get $before $name] ne $master } {
        incr resized
    }
}
set removed [expr {[dict size $before] + $added - [dict size $after]}]
puts "gemm_timing_eco: changed [expr {$resized + $added + $removed}] ($resized resized, $added added, $removed removed)"

source $::env(SCRIPTS_DIR)/openroad/common/dpl_cell_pad.tcl
detailed_placement
if { $::env(GLB_OPTIMIZE_MIRRORING) } {
    optimize_mirroring
}
if { [catch {check_placement -verbose} errmsg] } {
    puts stderr $errmsg
    exit 1
}
unset_dont_touch_wrapper
write
