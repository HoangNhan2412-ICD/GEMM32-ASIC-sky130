# Power of the AXI shell measurement run (GemmAxiShell) at the typical corner.
# Without ACT: OpenSTA default activity - the same method as the core's
# vectorless number (tools/power.sh without --vcd).
# With ACT (activity file from vcd2act_flat.py): per-pin activity from a
# simulation, set on the driver pin of every net (as power.tcl does for the
# core) and on the input ports too (the shell is mostly port-facing logic;
# measured 2026-10-10, this changed the totals by less than 0.1 %).
#
# NOCLK=1 (only with ACT): the clock of the SDC is deleted before the
# activities are set, so OpenSTA takes every pin's activity from the VCD,
# clock pins included, in transitions per second. Why: with the clock
# defined, the OpenSTA of the OpenLane image charged the flops behind a clock
# gate and their GCLK nets at the full clock rate in a window where the gate
# stayed closed (cycles 2300..3200: 0 GCLK toggles, gated flop = flop on
# S_AXI_ACLK, also with a tiny non-zero activity set), while in 0..end
# (GCLK toggling) it used the real rate. Without a clock nothing can fall
# back to the clock activity. Check: a variant without clock gating must give
# nearly the same total with and without NOCLK.
# env: SHELL_FINAL (results/final of a gemm_axi_shell run), OUT (report prefix),
#      ACT (optional), NOCLK (optional, 1)
set R $::env(SHELL_FINAL)
set lib $::env(PDK_ROOT)/sky130A/libs.ref
read_liberty $lib/sky130_fd_sc_hd/lib/sky130_fd_sc_hd__tt_025C_1v80.lib
read_verilog $R/verilog/gl/GemmAxiShell.nl.v
link_design GemmAxiShell
read_sdc $R/sdc/GemmAxiShell.sdc
read_spef $R/spef/GemmAxiShell.spef
set noclk [expr {[info exists ::env(NOCLK)] && $::env(NOCLK) eq "1" && [info exists ::env(ACT)]}]
if {$noclk} {
    set clks [all_clocks]
    if {[llength $clks] > 0} { delete_clock $clks }
    puts "NOCLK: clocks deleted, [llength [all_clocks]] left"
}
if {[info exists ::env(ACT)]} {
    set f [open $::env(ACT)]; set ncyc 0; set win_s 0; set np 0; set nport 0; set nmiss 0
    while {[gets $f line] >= 0} {
        if {[string index $line 0] eq "#"} {
            # "# cycles N period_ps P window_ps T"
            set ncyc [lindex $line 2]; set win_s [expr {[lindex $line 6] * 1e-12}]; continue
        }
        lassign $line kind name tog duty
        # with a clock: transitions per clock cycle (OpenSTA divides by the period);
        # without: transitions per second
        if {$noclk} { set act [expr {double($tog) / $win_s}] } else { set act [expr {double($tog) / $ncyc}] }
        if {$kind eq "pin"} {
            set pin [sta::find_pin $name]
        } elseif {$kind eq "port"} {
            set port [get_ports -quiet $name]
            if {$port eq ""} { set pin "" } else { set pin [sta::get_port_pin $port] }
        } else { continue }
        if {$pin eq "NULL" || $pin eq ""} { incr nmiss; continue }
        if {!$noclk && [sta::is_clock_src $pin]} { continue }
        sta::set_power_pin_activity $pin $act $duty
        if {$kind eq "pin"} { incr np } else { incr nport }
    }
    close $f
    puts "activity from [file tail $::env(ACT)]: $np driver pins, $nport input ports over $ncyc cycles, $nmiss not found[expr {$noclk ? ", no clock (per second)" : ""}]"
}
report_power
report_power -digits 6 > $::env(OUT).design.rpt
