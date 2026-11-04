# Post-fit TimeQuest reports for the USB host core. Run from this directory:
# quartus_sta -t timing_reports.tcl

set project_name usb_host
set revision_name usb_host
set report_dir ../../docs/usb_host/results/core_timing
file mkdir $report_dir

project_open -revision $revision_name $project_name
create_timing_netlist
read_sdc
update_timing_netlist

report_clocks -file [file join $report_dir clocks.rpt]
report_sdc -file [file join $report_dir constraints.rpt]
report_ucp -summary -file [file join $report_dir unconstrained_summary.rpt]
report_timing -setup -npaths 20 -detail full_path \
  -file [file join $report_dir setup_all.rpt]
report_timing -hold -npaths 20 -detail full_path \
  -file [file join $report_dir hold_all.rpt]
report_timing -setup -from [get_ports {miso_i}] \
  -to [get_registers {*rx_shift_q*}] \
  -npaths 10 -detail full_path \
  -file [file join $report_dir miso_to_capture.rpt]
report_timing -setup -from_clock clk50 -to [get_ports {cs_n_o}] \
  -npaths 10 -detail full_path \
  -file [file join $report_dir cs_output.rpt]
report_timing -hold -from_clock clk50 -to [get_ports {cs_n_o}] \
  -npaths 10 -detail full_path \
  -file [file join $report_dir cs_hold.rpt]

delete_timing_netlist
project_close
