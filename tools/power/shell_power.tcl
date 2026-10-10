# Power of the AXI shell measurement run (GemmAxiShell) at the typical corner.
# Without ACT: OpenSTA default activity - the same method as the core's
# vectorless number (tools/power.sh without --vcd).
# With ACT (activity file from vcd2act_flat.py): per-pin activity from a
# simulation, set on the driver pin of every net (as power.tcl does for the
# core) and, unlike the core, on the input ports too: the shell is mostly
# port-facing logic (~1780 ports), so leaving its ports at the default 0.1
# toggles per cycle would charge idle windows with traffic that is not there.
#
# Zero toggles are set as 1e-3 toggles per window instead of 0. The OpenSTA of
# the OpenLane image replaces an activity of 0 on a clock-network pin by the
# full clock activity (seen 2026-10-10: GCLK of every clock gate at 0 toggles
# in cycles 2300..3200, yet the gated flops and the GCLK nets were charged
# exactly like flops on S_AXI_ACLK; with a non-zero count, as in 0..end, the
# real activity is used). 1e-3 per window is far below one toggle.
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
    set f [open $::env(ACT)]; set ncyc 0; set np 0; set nport 0; set nzero 0; set nmiss 0
    while {[gets $f line] >= 0} {
        if {[string index $line 0] eq "#"} { set ncyc [lindex $line 2]; continue }
        lassign $line kind name tog duty
        if {$tog == 0} { incr nzero }
        set act [expr {max(double($tog), 1e-3) / $ncyc}]
        if {$kind eq "pin"} {
            set pin [sta::find_pin $name]
            if {$pin eq "NULL" || $pin eq ""} { incr nmiss; continue }
            if {[sta::is_clock_src $pin]} { continue }
            sta::set_power_pin_activity $pin $act $duty
            incr np
        } elseif {$kind eq "port"} {
            set port [get_ports -quiet $name]
            if {$port eq ""} { incr nmiss; continue }
            if {[sta::is_clock_src [sta::get_port_pin $port]]} { continue }
            set_power_activity -input_ports $port -activity $act -duty $duty
            incr nport
        }
    }
    close $f
    puts "activity from [file tail $::env(ACT)]: $np driver pins, $nport input ports over $ncyc cycles ($nzero with 0 toggles, set to 1e-3), $nmiss not found"
}
report_power
report_power -digits 6 > $::env(OUT).design.rpt
