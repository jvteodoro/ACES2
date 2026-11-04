# Custom reports sourced by the default post-fit TimeQuest run.
# Run from quartus/de10_lite with:
# quartus_sta aces2_usb_audio -c aces2_usb_audio --report_script=timing_reports.tcl
# The default report flow has already opened the project, loaded the fitted
# netlist and SDC, and updated timing before this script is sourced.

set report_dir ../../docs/usb_host/results/board_timing
file mkdir $report_dir

report_clocks -file [file join $report_dir clocks.rpt]
report_sdc -file [file join $report_dir constraints.rpt]
report_ucp -summary -file [file join $report_dir unconstrained_summary.rpt]
report_timing -setup -npaths 20 -detail full_path \
  -file [file join $report_dir setup_all.rpt]
report_timing -hold -npaths 20 -detail full_path \
  -file [file join $report_dir hold_all.rpt]
report_timing -setup -from [get_ports {arduino_io[12]}] \
  -to [get_registers {*rx_shift_q*}] \
  -npaths 10 -detail full_path \
  -file [file join $report_dir miso_to_capture.rpt]
report_timing -setup -from_clock clk_50 -to [get_ports {arduino_io[10]}] \
  -npaths 10 -detail full_path \
  -file [file join $report_dir cs_output.rpt]
report_timing -setup -from_clock clk_50 -to [get_ports {arduino_io[11]}] \
  -npaths 10 -detail full_path \
  -file [file join $report_dir mosi_output.rpt]
report_timing -hold -from_clock clk_50 -to [get_ports {arduino_io[11]}] \
  -npaths 10 -detail full_path \
  -file [file join $report_dir mosi_hold.rpt]
report_timing -hold -from_clock clk_50 -to [get_ports {arduino_io[10]}] \
  -npaths 10 -detail full_path \
  -file [file join $report_dir cs_hold.rpt]
