# DE10-Lite USB audio wrapper compile and timing

Build: Quartus Prime Standard 25.1std, MAX 10 `10M50DAF484C7G`, revision
`aces2_usb_audio`. Full flow completed on 2026-11-02 14:32:30 after the parser
profile parameters and sticky first-sample LED were added. Flow, fit, assembler,
and post-fit STA completed successfully with zero errors. The generated SOF is
present but has not been programmed onto a board. The custom per-path reports
were regenerated at 14:35 against this fit.

Historical build-time note: the SOF was subsequently programmed to the DE10-Lite
on 2026-11-02. The UM2 did not power up on the shield; see the current physical
bring-up status in `../board_bringup.md`.

## Fit and timing results

- Logic elements: 19,729 / 49,760 (40%); registers: 13,679; memory: 10,240
  bits; physical pins: 66.
- MAX `cs_n_q`, `mosi_q`, and `sck_q` are packed into IOEs on
  `arduino_io[10]`, `[11]`, and `[13]`.
- ESP32 MOSI and SCK registers are packed into GPIO2 and GPIO0 output IOEs.
  GPIO3 CS has no eligible output register; its attempted fast-output-register
  assignment was removed after the fitter rejected it.
- Post-fit clocks: board `clk_50` at 50 MHz; MAX `max3421e_sck_pin` at 25 MHz;
  ESP32 `esp32_sck` and output `esp32_sck_pin` at 8.33 MHz (120 ns). All clocks
  are recognized in the post-fit clock report.
- Setup/hold TNS is zero at every corner. The full-flow STA reports worst
  `clk_50` setup slack +2.607 ns (slow 85 C), +3.980 ns (slow 0 C), and
  +12.053 ns (fast 0 C); worst hold slack is +0.253 ns, +0.256 ns, and
  +0.098 ns, respectively.
- Detailed post-fit paths: MAX MISO→capture +17.924 ns, MAX MOSI setup
  +14.773 ns, and MAX CS setup +29.619 ns. The reports are in
  `miso_to_capture.rpt`, `mosi_output.rpt`, and `cs_output.rpt`.
- Post-fit `report_sdc` recognizes both generated output clocks, MAX MISO input
  delay, MAX MOSI/CS output delays, and the scoped MOSI/CS hold exceptions.
  The full flow has pre-pack warnings while duplicate output-register Q nodes
  are absent; the final post-fit reports contain no ignored SDC commands.
- The timing report shows zero unconstrained input ports, zero illegal or
  unconstrained clocks, and two unconstrained output ports/four paths:
  `gpio[2]` MOSI and `gpio[3]` CS. GPIO0 is constrained as the 8.33 MHz clock
  output. MOSI/CS receiver setup and board/cable delays remain intentionally
  open until documented or measured.
- Ten LEDs and MAX reset (`arduino_io[8]`) are excluded from synchronous setup
  analysis: LEDs are diagnostic only; reset pulse width is functionally checked
  in the board testbench. Their electrical routing still needs physical review.

The MOSI and CS hold exceptions apply only to their output-register paths
because TimeQuest sees periodic idle edges on burst-gated SCK. MAX MOSI setup
remains timed. The bridge testbench checks MOSI hold on each real sample edge
and measures CS timing from burst edges. These RTL checks do not replace the
missing ESP32 receiver/interconnect constraints or physical measurements.

The full flow reported 53 warnings: 33 Analysis & Synthesis, 18 Fitter, one
Assembler, and one Timing Analyzer warning. These include pre-pack clock
selectors, inferred RAM/pass-through logic, tri-state top-level ports, missing
drive-strength assignments, and MAX 10 3.3-V interface advisories; the Timing
Analyzer warning is the generic processor-count notice. Post-fit STA recognizes
the clocks and constraints. No invalid fast-output-register assignment
remains. These reports do not establish board-level electrical approval.

The current SOF SHA-256 is
`5b2e567f751a1ad8dd73b696a555ec2107f8ac19c9ee113ceb2e4b55cbb32fb4`.

## Evidence files

- Full flow: `quartus/de10_lite/output_files_usb_audio/aces2_usb_audio.flow.rpt`
- Fit and IOE packing: `quartus/de10_lite/output_files_usb_audio/aces2_usb_audio.fit.rpt`
- Multicorner timing: `quartus/de10_lite/output_files_usb_audio/aces2_usb_audio.sta.summary`
- Full timing report: `quartus/de10_lite/output_files_usb_audio/aces2_usb_audio.sta.rpt`
- Clock definitions: [`clocks.rpt`](clocks.rpt)
- Constraint recognition: [`constraints.rpt`](constraints.rpt)
- Unconstrained ports: [`unconstrained_summary.rpt`](unconstrained_summary.rpt)
- Direct MISO path: [`miso_to_capture.rpt`](miso_to_capture.rpt)
- MAX setup and hold path sets: [`setup_all.rpt`](setup_all.rpt), [`hold_all.rpt`](hold_all.rpt)
- MAX bridge edge measurements: [`../protocol/drv03.txt`](../protocol/drv03.txt)

## Source hashes

| File | SHA-256 |
|---|---|
| `quartus/de10_lite/aces2_usb_audio.qsf` | `ab5711127d2f91f1ea9892a753736fee748cb8b329efe098ca573dfbb5f25251` |
| `quartus/de10_lite/aces2_usb_audio.sdc` | `89deaa46153f0a7030a0b1629f9768e8b4d7bf72c6c0b658a0bf7dc328da2cfa` |
| `quartus/de10_lite/timing_reports.tcl` | `b428e5590ab6f4dede6f0480d516a7c1c4ec6d057de252f1595b85a587ac81e2` |
| `rtl/top/aces2_usb_audio_top.sv` | `0f6e39450f7875f01b644e30c4f4a618b2029fa1a0d967de427c259d9da315e4` |
| `rtl/usb/usb_audio_host_top.sv` | `349a3ac658bb279dda5c42d76cc56f55335eb39fadb55c538bc610127a94cd93` |
| `rtl/usb/usb_isochronous_receiver.sv` | `97eb747c1f28a7211aa6a118f31b79d20b1d933fe915f08280f155cbd7796423` |
| `rtl/usb/usb_control_transfer.sv` | `a761209cb2e26caf8ec477f0153ba500bf3c74e0cdb23aeade4820ed55bf6b33` |
| `rtl/usb/usb_enumerator.sv` | `450be28ab28dc50e6e2f2be4c1c52c8e7edc1d8595d61020c4061a635d7d2a97` |
| `rtl/usb/usb_descriptor_parser.sv` | `8920978ca8f5dbe4d3d36667e22b46e8ecc9896c02c1716252ef52f7953ce11e` |
| `rtl/usb/usb_host_engine.sv` | `27f21742234b6f341b2b1886f674a178ac26ecd2d1b2510e90204519ea8e39c9` |
| `rtl/usb/max3421e_controller.sv` | `c101d3000a8137ec6710761fc24072b074aba9ccc7ddc2e304d28f2652432584` |
| `rtl/usb/max3421e_spi_bridge.sv` | `8084c0c3942ebc8ec3a8e0ab2f2d61f34b2f6d979f94a60c693fd4aed9aba84a` |
| `rtl/usb/usb_pcm_decoder.sv` | `075ae2494c57aa21c7ea33f8eaef54182100c5b0035af271dadfd56860046075` |
| `rtl/usb/audio_sample_buffer.sv` | `95dc41b262a8e26becd5960db005b18c684015d3bbf5bb304729622d9489603a` |
| `rtl/spi/spi_frame_encoder.sv` | `54649703100540ec69c591d8607ff61d74426bc6d856404fdacc939f9643b410` |
| `rtl/spi/spi.sv` | `ffbd6a3608277cae10e6e81b7275c41a1470f83733008900e35ac9ecaeba556d` |
| `rtl/spi/spi_uc.sv` | `271e1a3705e099d052b02c9e389727b038bbe707d8bd13523aeab516d4df6238` |
| `third_party/spi-fpga-core/rtl/spi_master.sv` | `83be588c0847e808ffc7dbe683f77e9f61abec9427bf761bc0a2cb2b17e0cdbc` |
| `third_party/spi-fpga-core/rtl/spi_fifo.sv` | `1c8b396df50fb83201fad9971b6aaaab3ceae4ac450052e65d22165404e0ddad` |
