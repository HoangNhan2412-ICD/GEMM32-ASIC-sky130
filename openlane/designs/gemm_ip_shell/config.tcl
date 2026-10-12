# ---------------------------------------------------------------------------
# The AXI macro of the complete IP (gemm_ip): GemmAxiShell, lean + clock
# gating, hardened as a block (met1-met4, power pins vccd1/vssd1 on met4 like
# the row macro) and placed by gemm_ip as instance u_axi_shell.
#   openlane/run_flow.sh ip-shell     tags ip_shell_cal (clock latency), ip_shell
# Same RTL, variant and port budget as the axi-shell measurement run, so this
# file starts from gemm_axi_shell/config.tcl and changes only what the
# integration needs:
#   - a tall, narrow die along the IP's West edge (sizes.tcl, pin_order.cfg from
#     gen_ip_files.py): core-side pins at the y of core_v11's West pins;
#   - antenna 0: diodes on the inputs + heuristic diodes, more repair rounds in
#     the global route, and the antenna ECO rounds after detailed routing
#     (shell_full.tcl runs gemm_core/route_signoff.tcl, as the core does).
# ---------------------------------------------------------------------------
source $::env(DESIGN_DIR)/../gemm_axi_shell/config.tcl

# files of gemm_axi_shell that config.tcl looks for in DESIGN_DIR
set ::env(BASE_SDC_FILE) $::env(DESIGN_DIR)/../gemm_axi_shell/shell.sdc
if { $::env(GEMM_AXIS_CG) } {
    set ::env(VERILOG_FILES_BLACKBOX) [list $::env(DESIGN_DIR)/../gemm_axi_shell/dlclkp_bb.v]
}

# The die is 160 um wide and 5.9 mm tall: ~3 % of the core area is cells, and
# most nets are short horizontal bit slices. The long nets are the control
# fan-outs of the slices (load enable, clock-gate GCLK, reset) along the whole
# height; those are the antenna risk (shell_lean_cg: 12 met1 islands with no
# diode in them, Required 400).
# ip_shell (second try): at 0.30 the result path (256-bit i_result_data in,
# result_axis_tdata out, pins in the bottom 370 um) plus its ~1800 hold buffers
# filled the bottom 400 um to 60-67 % while the macro as a whole is 11.6 %
# used; the antenna diodes found no site near their gates there (38-87 um
# away) and every violation left was a hold-buffer input in that corner.
# 0.15 lets global placement spread that logic upwards.
set ::env(PL_TARGET_DENSITY) 0.15

# antenna (row_v1 reached 0 with these; ECO rounds from route_signoff.tcl on top)
set ::env(DIODE_ON_PORTS)                "in"
set ::env(RUN_HEURISTIC_DIODE_INSERTION) 1
set ::env(HEURISTIC_ANTENNA_THRESHOLD)   50
set ::env(GRT_REPAIR_ANTENNAS)           1
set ::env(GRT_ANT_ITERS)                 30
set ::env(GRT_ANT_MARGIN)                30
set ::env(GRT_MAX_DIODE_INS_ITERS)       3
# less long met1 (gemm_core: fewer antenna islands with met1 at 50 %)
set ::env(GRT_LAYER_ADJUSTMENTS)         "0.99,0.5,0,0,0,0"
set ::env(GEMM_ANT_ECO_ITERS)            3
# diodes before the first global route (shell_full.tcl, ant_seed.py): one next
# to every gate on an input-port net or more than this far from its driver
set ::env(GEMM_ANT_SEED_DIST)            40
# no extra site left of each diode: with ~2300 seeded diodes the 2-site padding
# made the global router's diode legalization fail (DPL-0036, ip_shell experiment)
set ::env(DIODE_PADDING)                 0

# a dirty route ends the run in route_signoff.tcl only after every seed was tried
set ::env(QUIT_ON_TR_DRC) 1

if { [file exists $::env(DESIGN_DIR)/overrides.tcl] } {
    puts "\[INFO\]: gemm_ip_shell: applying overrides.tcl"
    source $::env(DESIGN_DIR)/overrides.tcl
}
