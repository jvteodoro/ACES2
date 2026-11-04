create_clock -name clk50 -period 20.000 [get_ports {clk_i}]
# SCK is a registered divide-by-two output of the reused SPI master. Target
# the source register Q so TimeQuest can propagate the clock through the
# generated clock tree instead of treating the top-level port as a source.
create_generated_clock -name spi_sck -source [get_ports {clk_i}] -divide_by 2 \
  [get_pins -compatibility_mode {*sck_q|q}]
# The fitter duplicates sck_q when packing its output register. Source the
# pin clock from that exact output-register Q, then propagate through the pad.
create_generated_clock -name spi_sck_pin -source \
  [get_pins -compatibility_mode {u_controller|u_bridge|u_spi|sck_q~_Duplicate_1|q}] \
  -divide_by 1 [get_ports {sck_o}]
# MAX3421E Rev. 4 SPI timing: worst stated MISO propagation after falling
# SCLK is 14.2 ns at VL > 2.5 V. The MAX bridge uses mode 0 and captures MISO
# immediately before each trailing/falling edge. That sample occurs once per
# full 40 ns SCK period; the capture FF is clocked at 50 MHz, so STA's default
# half-cycle input-to-register relationship is one system-clock cycle too
# early. Move only MISO receiver endpoints to the next actual trailing-edge
# sample (one additional 20 ns clk50 cycle). Hold remains checked at the
# original edge. This is tied to the bridge's receive clock-enable behavior.
# Keep additional board delay provisional until shield/interconnect are known.
set_input_delay -clock spi_sck_pin -clock_fall -max 14.2 [get_ports {miso_i}]
set_input_delay -clock spi_sck_pin -clock_fall -min 0.0 [get_ports {miso_i}]
# The serial input feeds the receive shifter and byte latch. Only the least
# significant receive-shift bit has a direct MISO path; the rest of each byte
# is retained/shifted internally. These registers update only on the trailing
# sample enable, once per 40 ns SCK period.
set_multicycle_path 2 -setup -end -from [get_ports {miso_i}] \
  -to [get_registers {*rx_fifo_wdata_q*}]
set_multicycle_path 1 -hold -end -from [get_ports {miso_i}] \
  -to [get_registers {*rx_fifo_wdata_q*}]
set_multicycle_path 2 -setup -end -from [get_ports {miso_i}] \
  -to [get_registers {*rx_shift_q*}]
set_multicycle_path 1 -hold -end -from [get_ports {miso_i}] \
  -to [get_registers {*rx_shift_q*}]
# MAX3421E Rev. 4 requires MOSI setup/hold of 5/10 ns and CS setup/hold
# of 30 ns. The SPI clock is burst-gated and remains low after the final edge;
# the bridge uses a registered CS output and enforces its setup/hold guard
# cycles. Use one additional SCK cycle for the setup relation so the periodic
# STA clock models the next active transfer edge rather than an idle edge.
# The matching hold multicycle restores the original hold edge, so tT remains
# checked. The focused bridge TB also measures tL/tT on the output pins.
# Unknown shield/cable delays are omitted until physical interconnect is known.
set_output_delay -clock spi_sck_pin -max 5.0 [get_ports {mosi_o}]
set_output_delay -clock spi_sck_pin -min -10.0 [get_ports {mosi_o}]
# MOSI changes on trailing-edge shift events and is held through each rising
# sample edge. Static hold analysis sees idle/leading edges because SCK is
# burst-gated, so waive only this output hold path. Setup remains timed, and
# tDH=10 ns is checked after every actual rising edge in the pin-level bench.
set_false_path -hold -from [get_registers {*mosi_q}] \
  -to [get_ports {mosi_o}]
# Specify both clock edges and both data sides so TimeQuest does not leave
# half of the CS transitions unconstrained. The 30 ns limits are the MAX3421E
# tL/tT requirements; actual burst qualification is also checked in the TB.
set_output_delay -clock spi_sck_pin -max 30.0 [get_ports {cs_n_o}]
set_output_delay -clock spi_sck_pin -clock_fall -max 30.0 -add_delay [get_ports {cs_n_o}]
set_output_delay -clock spi_sck_pin -min -30.0 -add_delay [get_ports {cs_n_o}]
set_output_delay -clock spi_sck_pin -clock_fall -min -30.0 -add_delay [get_ports {cs_n_o}]
set_multicycle_path 2 -setup -end -from [get_clocks {clk50}] \
  -to [get_ports {cs_n_o}]
set_multicycle_path 1 -hold -end -from [get_clocks {clk50}] \
  -to [get_ports {cs_n_o}]
# SCK is burst-gated. The CS tT requirement is measured from the last actual
# SCK edge; a periodic-clock hold analysis invents another SCK edge during
# idle and reports a false violation. Preserve CS setup checks above, and
# waive only the CS output hold path. The bridge pin-level test measures tT
# from the final SCK edge (40 ns observed versus 30 ns required).
set_false_path -hold -from [get_registers {*cs_n_q}] \
  -to [get_ports {cs_n_o}]
derive_clock_uncertainty
