# Power of the AXI shell measurement run (GemmAxiShell) at the typical corner,
# OpenSTA default activity - the same method as the core's vectorless number
# (tools/power.sh without --vcd), so the two can be compared.
# env: SHELL_FINAL (results/final of a gemm_axi_shell run), OUT (report prefix)
set R $::env(SHELL_FINAL)
set lib $::env(PDK_ROOT)/sky130A/libs.ref
read_liberty $lib/sky130_fd_sc_hd/lib/sky130_fd_sc_hd__tt_025C_1v80.lib
read_verilog $R/verilog/gl/GemmAxiShell.nl.v
link_design GemmAxiShell
read_sdc $R/sdc/GemmAxiShell.sdc
read_spef $R/spef/GemmAxiShell.spef
report_power
report_power -digits 6 > $::env(OUT).design.rpt
