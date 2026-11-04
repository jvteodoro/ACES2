# USB host core Quartus timing snapshot

Snapshot: Quartus Prime Standard 25.1std, MAX 10 `10M50DAF484C7G`, revision `usb_host`, final full compile completed 2026-11-02 14:41:53 after the USB profile parameter updates.

## Compile and resources

Full `quartus_sh --flow compile usb_host -c usb_host` completed successfully (0 errors, 26 warnings); final post-fit STA had 0 errors and 0 warnings. The fitter used final timing models.

- Logic cells: 18,144 / 49,760 (36%).
- Registers: 12,605.
- Memory bits: 10,240 / 1,677,312 (<1%).
- Physical pins: 6; virtual pins: 240.
- The fitter packed CS, MOSI, and SCK registers into I/O output buffers. See `../../../../quartus/usb_host/output_files/usb_host.fit.rpt` lines 173–177.

## Final SDC and STA

`quartus_sta -t timing_reports.tcl` and the full-flow STA completed successfully. The generated `spi_sck_pin` is 40 ns / 25 MHz, sourced from fitted output-register Q `u_controller|u_bridge|u_spi|sck_q~_Duplicate_1|q` and targeted at `sck_o`. `report_sdc` shows MISO input delays and MOSI/CS output delays matched, as well as the scoped MOSI and CS hold exceptions. Final post-fit STA has no ignored SDC commands. During Fitter's pre-pack timing setup, the duplicate Q did not yet exist and its source selector was empty, so that stage emitted ignored-clock/I/O-delay warnings. Post-fit STA resolves the fitted Q correctly; this stage-specific warning is reflected in the overall compile warning count and should not be mistaken for final post-fit constraint recognition.

Post-fit slow 85 C setup slack is +2.473 ns on `clk50`; slow 0 C is +3.821 ns and fast 0 C is +12.213 ns. The corresponding worst hold slack values are +0.239 ns, +0.239 ns, and +0.094 ns. MISO-to-capture worst setup slack is +16.972 ns, including the configured 14.2 ns device delay and 20 ns setup multicycle for the trailing-edge sample. MOSI setup is +14.799 ns and CS setup +29.645 ns. Setup and hold TNS are zero at all reported corners.

MOSI and CS output hold checks are narrowly waived from their launching registers to their respective output ports because static analysis treats burst-gated SCK as periodic through idle. MOSI setup remains timed against SCK; the bridge bench now checks tDH >=10 ns after every actual rising sample edge. CS setup remains timed; the bench measures tL/tT from actual burst edges. The latest recorded bridge run reports tL=40 ns and tT=60 ns (30 ns required for each). These exceptions do not cover internal register paths or setup checks.

`report_ucp -summary` reports 3 unconstrained inputs (`int_n_i`, `rst_ni`, `sample_ready_i`) and 238 unconstrained outputs, all virtual/debug/application interface pins. Physical SPI ports are constrained. The project is intentionally a core compile with virtual non-SPI I/O; this does not establish board-level timing or wiring closure.

## Reports

- [`clocks.rpt`](clocks.rpt)
- [`constraints.rpt`](constraints.rpt)
- [`unconstrained_summary.rpt`](unconstrained_summary.rpt)
- [`miso_to_capture.rpt`](miso_to_capture.rpt)
- [`cs_output.rpt`](cs_output.rpt)
- [`cs_hold.rpt`](cs_hold.rpt)
- [`setup_all.rpt`](setup_all.rpt)
- [`hold_all.rpt`](hold_all.rpt)
- Bridge pin timing evidence: [`drv03.txt`](../protocol/drv03.txt)

## Input hashes

The full list of 12 SystemVerilog sources is in `quartus/usb_host/usb_host.qsf`. Key design/constraint hashes at this STA snapshot:

| File | SHA-256 |
|---|---|
| `rtl/usb/max3421e_spi_bridge.sv` | `8084c0c3942ebc8ec3a8e0ab2f2d61f34b2f6d979f94a60c693fd4aed9aba84a` |
| `rtl/usb/max3421e_controller.sv` | `c101d3000a8137ec6710761fc24072b074aba9ccc7ddc2e304d28f2652432584` |
| `rtl/usb/usb_host_engine.sv` | `27f21742234b6f341b2b1886f674a178ac26ecd2d1b2510e90204519ea8e39c9` |
| `rtl/usb/usb_control_transfer.sv` | `a761209cb2e26caf8ec477f0153ba500bf3c74e0cdb23aeade4820ed55bf6b33` |
| `rtl/usb/usb_descriptor_parser.sv` | `8920978ca8f5dbe4d3d36667e22b46e8ecc9896c02c1716252ef52f7953ce11e` |
| `rtl/usb/usb_enumerator.sv` | `450be28ab28dc50e6e2f2be4c1c52c8e7edc1d8595d61020c4061a635d7d2a97` |
| `rtl/usb/usb_isochronous_receiver.sv` | `97eb747c1f28a7211aa6a118f31b79d20b1d933fe915f08280f155cbd7796423` |
| `rtl/usb/usb_pcm_decoder.sv` | `075ae2494c57aa21c7ea33f8eaef54182100c5b0035af271dadfd56860046075` |
| `rtl/usb/audio_sample_buffer.sv` | `95dc41b262a8e26becd5960db005b18c684015d3bbf5bb304729622d9489603a` |
| `rtl/usb/usb_audio_host_top.sv` | `349a3ac658bb279dda5c42d76cc56f55335eb39fadb55c538bc610127a94cd93` |
| `third_party/spi-fpga-core/rtl/spi_master.sv` | `83be588c0847e808ffc7dbe683f77e9f61abec9427bf761bc0a2cb2b17e0cdbc` |
| `third_party/spi-fpga-core/rtl/spi_fifo.sv` | `1c8b396df50fb83201fad9971b6aaaab3ceae4ac450052e65d22165404e0ddad` |
| `quartus/usb_host/usb_host.qsf` | `cdf110936c3dc295ed5fd613a4c6d013b9b53fef2467b01a285e73c05658a569` |
| `quartus/usb_host/usb_host.sdc` | `7f1603a547a0a02d528c774e7e93025bd7f26a9ece4ce1666ddf140be0f8becd` |

The final timing reports were generated against the post-fit netlist from the successful full compile and final SDC above. No RTL or QSF changed between fit and STA.
