# Power of the AXI shell measurement run (GemmAxiShell) at the typical corner.
# Without ACT: OpenSTA default activity - the same method as the core's
# vectorless number (tools/power.sh without --vcd).
# With ACT (activity file from vcd2act_flat.py): per-pin activity from a
# simulation, set on the driver pin of every net, as power.tcl does for the core.
# env: SHELL_FINAL (results/final of a gemm_axi_shell run), OUT (report prefix),
#      ACT (optional)
set R $::env(SHELL_FINAL)
set lib $::env(PDK_ROOT)/sky130A/libs.ref
read_liberty $lib/sky130_fd_sc_hd/lib/sky130_fd_sc_hd__tt_025C_1v80.lib
read_verilog $R/verilog/gl/GemmAxiShell.nl.v
link_design GemmAxiShell
read_sdc $R/sdc/GemmAxiShell.sdc
read_spef $R/spef/GemmAxiShell.spef
if {[info exists ::env(ACT)]} {
    set f [open $::env(ACT)]; set ncyc 0; set np 0; set nmiss 0
    while {[gets $f line] >= 0} {
        if {[string index $line 0] eq "#"} { set ncyc [lindex $line 2]; continue }
        lassign $line kind name tog duty
        if {$kind ne "pin"} { continue }
        set pin [sta::find_pin $name]
        if {$pin eq "NULL" || $pin eq ""} { incr nmiss; continue }
        if {[sta::is_clock_src $pin]} { continue }
        sta::set_power_pin_activity $pin [expr {double($tog) / $ncyc}] $duty
        incr np
    }
    close $f
    puts "activity from [file tail $::env(ACT)]: $np driver pins over $ncyc cycles, $nmiss not found"
}
report_power
report_power -digits 6 > $::env(OUT).design.rpt
