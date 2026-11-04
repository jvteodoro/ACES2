# Board clock: DE10-Lite CLK1_50.
create_clock -name clk_50 -period 20.000 [get_ports {clk_50}]

# MAX3421E host SPI is mode 0 at 25 MHz (divide-by-two from the 50 MHz core).
# Anchor the generated clock at the actual SCK register, then propagate it to
# the board pin. This lets TimeQuest model clock latency through the output
# path instead of treating the pin as an unrelated clock source.
create_generated_clock -name max3421e_sck -source [get_ports {clk_50}] \
  -divide_by 2 [get_pins -compatibility_mode {*u_usb_audio_host|max3421e_controller:u_controller|max3421e_spi_bridge:u_bridge|spi_master:u_spi|sck_q|q}]
# Constrain the physical output port directly. Internal register names vary
# with Quartus packing, so avoid fragile post-fit duplicate-register selectors.
create_generated_clock -name max3421e_sck_pin -source [get_ports {clk_50}] \
  -divide_by 2 [get_ports {arduino_io[13]}]

# The ESP32 receiver uses mode 1 and GPIO18/19/23/5 on SPI3 IO_MUX. The
# integrated link uses DIV=4: 50 MHz / (2*(4+1)) = 5 MHz.
# The internal register clock and GPIO output clock are constrained separately;
# receiver setup and interconnect delays remain open until measured.
create_generated_clock -name esp32_sck -source [get_ports {clk_50}] \
  -divide_by 10 [get_pins -compatibility_mode {*spi:u_esp32_spi|spi_master:u_spi_master|sck_q|q}]
# Constrain the physical SCK port directly; receiver setup and interconnect
# delays remain open until they are measured/documented.
create_generated_clock -name esp32_sck_pin -source [get_ports {clk_50}] \
  -divide_by 10 [get_ports {gpio[0]}]

# MAX3421E Rev. 4 timing: tDO=14.2 ns from SCLK falling to MISO valid,
# MOSI tDS=5 ns/tDH=10 ns, SS tL/tT=30 ns. No cable/shield board delay is
# included because the physical jumper route has not been characterized.
set_input_delay -clock max3421e_sck_pin -clock_fall -max 14.2 [get_ports {arduino_io[12]}]
set_input_delay -clock max3421e_sck_pin -clock_fall -min 0.0 [get_ports {arduino_io[12]}]
# The bridge captures MISO on the trailing edge, one full 40 ns SCK period
# after the leading edge relation used by TimeQuest. Move only the receiver
# setup endpoints to that next sample; the matching hold multicycle preserves
# checks at the original edge. This is the same enable timing as the core SDC.
set_multicycle_path 2 -setup -end -from [get_ports {arduino_io[12]}] \
  -to [get_registers {*rx_fifo_wdata_q*}]
set_multicycle_path 1 -hold -end -from [get_ports {arduino_io[12]}] \
  -to [get_registers {*rx_fifo_wdata_q*}]
set_multicycle_path 2 -setup -end -from [get_ports {arduino_io[12]}] \
  -to [get_registers {*rx_shift_q*}]
set_multicycle_path 1 -hold -end -from [get_ports {arduino_io[12]}] \
  -to [get_registers {*rx_shift_q*}]
set_output_delay -clock max3421e_sck_pin -max 5.0 [get_ports {arduino_io[11]}]
set_output_delay -clock max3421e_sck_pin -min -10.0 [get_ports {arduino_io[11]}]
# MOSI only changes on bit-shift events at trailing edges; it is held through
# each rising sample edge. Static hold analysis also sees idle/leading clock
# edges because SCK is burst-gated. Keep setup checks and verify tDH=10 ns at
# each actual rising edge in the bridge pin-level testbench.
set_false_path -hold -from [get_registers {*mosi_q}] \
  -to [get_ports {arduino_io[11]}]
set_output_delay -clock max3421e_sck_pin -max 30.0 [get_ports {arduino_io[10]}]
set_output_delay -clock max3421e_sck_pin -min -30.0 [get_ports {arduino_io[10]}]
set_output_delay -clock max3421e_sck_pin -clock_fall -max 30.0 -add_delay [get_ports {arduino_io[10]}]
set_output_delay -clock max3421e_sck_pin -clock_fall -min -30.0 -add_delay [get_ports {arduino_io[10]}]

# CS is a registered, burst-gated output. The bridge holds it stable for the
# required guard cycles around each transaction; model the active edge one
# SCK period later and restore the original hold edge.
set_multicycle_path 2 -setup -end -from [get_clocks {clk_50}] \
  -to [get_ports {arduino_io[10]}]
set_multicycle_path 1 -hold -end -from [get_clocks {clk_50}] \
  -to [get_ports {arduino_io[10]}]
# CS tT is an event-to-event requirement after the last real SCK edge. SCK is
# burst-gated, so periodic-clock hold analysis invents an idle SCK edge. Keep
# max/setup constraints active, waive only the CS output hold path, and check
# tT on the actual burst in the SPI pin-level regression (40 ns measured;
# 30 ns required). This does not cover unknown shield/cable delay.
set_false_path -hold -from [get_registers {*cs_n_q}] \
  -to [get_ports {arduino_io[10]}]

# KEY0 is only the asynchronous assertion input to the 12-stage reset-release
# conditioner. Keep all non-reset paths timed normally.
set_false_path -from [get_ports {key_n[0]}] \
  -to [get_registers {*reset_release_q[*]}]

# MAX3421E INT is asynchronous; exempt only the first synchronizer stage.
set_false_path -from [get_ports {arduino_io[9]}] \
  -to [get_registers {*int_meta_q}]

# These are asynchronous indicator/reset outputs rather than source-synchronous
# data. LED response is diagnostic only; the MAX3421E reset pulse width is
# checked functionally in the board testbench and its external routing remains
# a bring-up check.
set_false_path -to [get_ports {ledr[*]}]
set_false_path -to [get_ports {arduino_io[8]}]

derive_clock_uncertainty
